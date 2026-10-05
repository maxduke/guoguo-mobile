package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestMobileMetadataIncludesVIPAndUsesCategoryBeforeChannel(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(r, 200, `{"data":{"id":"fixture","name":"新剧名","category":"动作","pay_type":"vip","episode_count":60,"issue_date":"2026-09-22","hot_rate":"3万","tags":["冒险"]}}`), nil
	})
	c := &MobileClient{downloader: d}
	raw, err := c.Call(`{"method":"detail","id":"huangdou:fixture"}`)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Item map[string]any `json:"item"`
	}
	if err = json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatal(err)
	}
	if result.Item["id"] != "huangdou:fixture" || result.Item["vip"] != true || result.Item["category"] != "动作" || result.Item["episodes"] != float64(60) {
		t.Fatalf("metadata contract mismatch: %s", raw)
	}
	if _, err = c.Call(`{"method":"detail","id":"huangdou:another"}`); err == nil {
		t.Fatal("accepted another drama's metadata")
	}
}

func TestMobileRecommendationContractAndValidation(t *testing.T) {
	calls := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		return rankingHTTPResponse(r, 200, recommendationFixture([]string{"123", "456"}, 18, true)), nil
	})
	c := &MobileClient{downloader: d}
	raw, err := c.Call(`{"method":"recommendations","recommendation":{"genre":"comic_series"}}`)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Items []map[string]any `json:"items"`
		Next  int              `json:"nextOffset"`
		More  bool             `json:"hasMore"`
	}
	if err = json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 2 || result.Items[0]["id"] != "hongguo:123" || result.Next != 18 || !result.More {
		t.Fatal(raw)
	}
	if _, err = c.Call(`{"method":"recommendations","recommendation":{"genre":"invalid"}}`); err == nil || calls != 1 {
		t.Fatal("invalid genre reached upstream")
	}
}

func TestMobileDownloadUsesRedirectedPlaylistBase(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		response := rankingHTTPResponse(r, 200, "#EXTM3U\n#EXTINF:2,\npart.ts\n#EXT-X-ENDLIST\n")
		final, _ := url.Parse("https://media.example.org/new/path/list.m3u8")
		request := r.Clone(r.Context())
		request.URL = final
		response.Request = request
		return response, nil
	})
	c := &MobileClient{downloader: d}
	plan, err := c.planMobileMedia(context.Background(), providerMedia{URL: "https://media.example.org/old/master.m3u8"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Assets) != 1 || plan.Assets[0].URL != "https://media.example.org/new/path/part.ts" {
		t.Fatalf("wrong redirected asset: %+v", plan.Assets)
	}
}

func TestMobileSearchReturnsPartialWarning(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if strings.HasPrefix(r.URL.Path, "/search/") {
			return rankingHTTPResponse(r, 503, "unavailable"), nil
		}
		return rankingHTTPResponse(r, 200, `{"data":[{"name":"样例","video_data":{"series_id":"1234567890123456789","series_title":"样例"}}]}`), nil
	})
	// Parser behavior for partial results is covered in provider search tests;
	// exercise its cached result through the native JSON boundary here.
	client := d.hongguoClient()
	client.searches["样例"] = hongguoSearchEntry{Dramas: []Drama{{ID: "hongguo:123", Title: "样例"}}, Total: 5, Limited: true, Warning: "部分结果暂不可用", ExpiresAt: time.Now().Add(time.Minute)}
	c := &MobileClient{downloader: d}
	raw, err := c.Call(`{"method":"search","source":"hongguo","query":"样例"}`)
	if err != nil || !strings.Contains(raw, `"limited":true`) || !strings.Contains(raw, "部分结果暂不可用") {
		t.Fatal(raw, err)
	}
}

func TestMobileCoverRetainsSourceAcrossSharedCacheAndUpdatesURL(t *testing.T) {
	calls := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Header.Get("Referer") != "https://alternate.example.org/home" {
			t.Errorf("lost source referer: %s", r.Header.Get("Referer"))
		}
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(bytes.NewReader([]byte{255, 216, 255, 0})), Request: r}, nil
	})
	d.providerHosts[sourceHuangdou] = "https://alternate.example.org"
	c := &MobileClient{downloader: d}
	for _, address := range []string{"first", "first", "updated"} {
		request, _ := json.Marshal(map[string]string{"method": "cover", "id": "huangdou:fixture", "url": "https://covers.example.org/" + address})
		if _, err := c.Call(string(request)); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 2 {
		t.Fatal("stale artwork reused after URL change", calls)
	}
}
