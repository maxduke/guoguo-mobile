package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestMobileHuangguoCatalogPassesPagesAndKeepsIdentities(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	d := c.downloader
	d.cfg.APIBase = "https://legacy.example.test"
	d.cfg.Token = "fixture"
	d.cfg.InterfaceKey = fixtureLegacyProtocol.InterfaceKey
	d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	d.cfg.HuangguoAIURL = "https://ai.example.org"
	d.cfg.HuangguoVideoURL = "https://video.example.org"
	d.cfg.PageSize = 1
	var page, aiCalls, legacyCalls, videoCalls atomic.Int32
	d.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
		current := int(page.Load())
		switch {
		case r.URL.Path == "/api/app/playlet-tab/all":
			return legacyFixtureResponse(r, []Tab{{ID: "fixture", Name: "分类"}}), nil
		case r.URL.Path == "/api/app/playlet/home/tab/fixture":
			legacyCalls.Add(1)
			want, _ := encryptParam(map[string]string{"pageNumber": strconv.Itoa(current), "pageSize": "1", "tabSortType": "1"}, []byte(d.cfg.ParamKey), []byte(d.cfg.ParamIV))
			if r.URL.Query().Get("data") != want {
				t.Error("legacy page/sort not forwarded")
			}
			return legacyFixtureResponse(r, listResponse{List: []Drama{{ID: fmt.Sprint(current), Title: "旧黄果"}}}), nil
		case strings.HasPrefix(r.URL.Path, "/api/videos/category/ai-"):
			aiCalls.Add(1)
			if r.URL.Query().Get("page") != strconv.Itoa(current) {
				t.Error("AI page not forwarded")
			}
			return rankingHTTPResponse(r, 200, fmt.Sprintf(`{"data":{"items":[{"id":"%d","title":"AI剧"}],"pagination":{"page":%d,"pages":2}}}`, current, current)), nil
		case r.URL.Path == "/videos":
			videoCalls.Add(1)
			if r.URL.Query().Get("page") != strconv.Itoa(current) {
				t.Error("video page not forwarded")
			}
			return rankingHTTPResponse(r, 200, fmt.Sprintf(`<article class="video-card"><a href="/series/%d" title="视频剧">视频剧</a></article><a href="/videos?page=2">下一页</a>`, current)), nil
		default:
			t.Errorf("unexpected whole-catalog request: %s", r.URL)
			return rankingHTTPResponse(r, 404, ""), nil
		}
	})
	for _, current := range []int{1, 2, 1} {
		page.Store(int32(current))
		raw, err := c.Call(fmt.Sprintf(`{"method":"catalog","source":"huangguo","page":%d}`, current))
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Items   []struct{ ID, Source string }
			HasMore bool
			Page    int
		}
		if err := json.Unmarshal([]byte(raw), &result); err != nil {
			t.Fatal(err)
		}
		if len(result.Items) != 3 || result.Page != current || !result.HasMore {
			t.Fatalf("bad catalog response: %s", raw)
		}
		want := map[string]bool{fmt.Sprint(current): true, fmt.Sprintf("huangguoai:%d", current): true, fmt.Sprintf("huangguo-video:series/%d", current): true}
		for _, item := range result.Items {
			if !want[item.ID] || item.Source != "huangguo" {
				t.Fatalf("changed identity: %+v", item)
			}
			delete(want, item.ID)
		}
	}
	if aiCalls.Load() != 12 || legacyCalls.Load() != 3 || videoCalls.Load() != 3 {
		t.Fatalf("refresh reused stale HTML or fetched extra pages: AI=%d legacy=%d video=%d", aiCalls.Load(), legacyCalls.Load(), videoCalls.Load())
	}
}

func TestMobileAIPageValidation(t *testing.T) {
	for _, test := range []struct {
		body       string
		page       int
		more, fail bool
	}{
		{`{"data":{"items":[{"id":"1","title":"剧集"}],"pagination":{"page":1,"pages":3}}}`, 1, true, false},
		{`{"data":{"items":[{"id":"1","title":"剧集"}],"pagination":{"page":3,"pages":3}}}`, 3, false, false},
		{`{"data":{"items":[],"pagination":{"page":4,"pages":3}}}`, 4, false, false},
		{`{"data":{"items":[],"pagination":{"page":1,"pages":3}}}`, 1, false, true},
		{`{"data":{"items":[{"id":"1","title":"剧集"}],"pagination":{"page":1,"pages":3}}}`, 2, false, true},
		{`<html>verification</html>`, 1, false, true},
		{`{"status":403,"msg":"blocked"}`, 1, false, true},
	} {
		_, more, err := parseMobileAIPage(test.body, "https://ai.example.org/", "ai-duanju", test.page)
		if (err != nil) != test.fail || more != test.more {
			t.Errorf("%s: more=%t err=%v", test.body, more, err)
		}
	}
}

func TestMobileHuangguoPartialFailureKeepsSuccessfulRows(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if strings.HasPrefix(r.URL.Path, "/api/videos/category/") {
			return rankingHTTPResponse(r, 200, `{"data":{"items":[{"id":"1","title":"成功剧集"}],"pagination":{"pages":2}}}`), nil
		}
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	d.cfg.HuangguoAIURL = "https://ai.example.org"
	d.cfg.HuangguoVideoURL = "https://video.example.org"
	d.cfg.APIBase = "https://legacy.example.test"
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	rows, more, err := d.mobileHuangguoCatalog(ctx, 1, nil)
	if len(rows) != 1 || !more || err == nil || !strings.Contains(err.Error(), "huangguo-video") {
		t.Fatalf("partial data discarded: rows=%d more=%t err=%v", len(rows), more, err)
	}
}
