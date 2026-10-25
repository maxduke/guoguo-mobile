package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func catalogConcurrencyClient(t *testing.T, before func(*http.Request)) *MobileClient {
	t.Helper()
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if before != nil {
			before(r)
		}
		switch {
		case r.URL.Path == "/reading/distribution/category/landpage/v/":
			var payload struct {
				Select struct {
					Genre []string `json:"genre"`
				} `json:"select_items"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				return nil, err
			}
			genre := payload.Select.Genre[0]
			id := 7000001
			if genre == "comic_series" {
				id++
			}
			if genre == "ai_series" {
				id += 2
			}
			return rankingHTTPResponse(r, 200, fmt.Sprintf(`{"data":{"next_offset":18,"has_more":true,"video_data":[{"series_id":"%d","series_title":"fixture"}]}}`, id)), nil
		case r.URL.Path == "/api/app/playlet-tab/all":
			return legacyFixtureResponse(r, []Tab{{ID: "fixture", Name: "分类"}}), nil
		case r.URL.Path == "/api/app/playlet/home/tab/fixture":
			return legacyFixtureResponse(r, listResponse{List: []Drama{{ID: "legacy", Title: "旧黄果"}}}), nil
		case strings.HasPrefix(r.URL.Path, "/api/videos/category/ai-"):
			return rankingHTTPResponse(r, 200, `{"data":{"items":[{"id":"1","title":"AI剧"}],"pagination":{"page":1,"pages":2}}}`), nil
		case r.URL.Path == "/videos":
			return rankingHTTPResponse(r, 200, `<article class="video-card"><a href="/series/1" title="视频剧">视频剧</a></article><a href="/videos?page=2">下一页</a>`), nil
		case r.URL.Path == "/api/drama/list":
			return rankingHTTPResponse(r, 200, `{"data":{"list":[{"id":"1","name":"黄豆"}]}}`), nil
		default:
			return rankingHTTPResponse(r, 404, ""), nil
		}
	})
	d.cfg.MaxPagesPerSort, d.cfg.PageSize = 1, 1
	d.cfg.APIBase, d.cfg.Token = "https://legacy.example.test", "fixture"
	d.cfg.InterfaceKey = fixtureLegacyProtocol.InterfaceKey
	d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	d.cfg.HuangguoAIURL, d.cfg.HuangguoVideoURL = "https://ai.example.org", "https://video.example.org"
	c := &MobileClient{downloader: d}
	t.Cleanup(c.Close)
	return c
}

func TestMobileCatalogQueuedDeadlineAndCancellation(t *testing.T) {
	c := catalogConcurrencyClient(t, func(r *http.Request) { t.Error("queued request reached the network") })
	unlock, err := c.lockCatalog(context.Background(), sourceHongguo)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	started := time.Now()
	_, err = c.Call(`{"method":"catalog","source":"hongguo","timeoutMs":100}`)
	if err == nil || time.Since(started) > time.Second {
		t.Fatal("deadline did not interrupt catalog queue", time.Since(started), err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan error, 1)
	go func() { _, err := c.aggregateCatalog(ctx, mobileRequest{Source: sourceHongguo}); finished <- err }()
	cancel()
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("canceled queue returned success")
		}
	case <-time.After(time.Second):
		t.Fatal("canceled request stayed queued")
	}
}

func TestMobileCatalogSourcesFetchConcurrentlyAndCommitBothSnapshots(t *testing.T) {
	for _, slow := range []string{sourceHongguo, "huangguo"} {
		t.Run(slow, func(t *testing.T) {
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			var hongguoRequests atomic.Int32
			c := catalogConcurrencyClient(t, func(r *http.Request) {
				// Leave one feed advanced internally while the page is in flight.
				block := r.URL.Path == "/reading/distribution/category/landpage/v/" && hongguoRequests.Add(1) == 2
				if slow == "huangguo" {
					block = r.URL.Path == "/api/app/playlet-tab/all"
				}
				if block {
					once.Do(func() { close(entered); <-release })
				}
			})
			defer func() {
				select {
				case <-release:
				default:
					close(release)
				}
			}()
			done := make(chan error, 1)
			go func() { _, err := c.Call(fmt.Sprintf(`{"method":"catalog","source":%q}`, slow)); done <- err }()
			select {
			case <-entered:
			case <-time.After(3 * time.Second):
				t.Fatal("slow source did not start")
			}
			other := "huangguo"
			if slow == "huangguo" {
				other = sourceHongguo
			}
			fast := make(chan error, 1)
			go func() { _, err := c.Call(fmt.Sprintf(`{"method":"catalog","source":%q}`, other)); fast <- err }()
			select {
			case err := <-fast:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("different source waited behind remote IO")
			}
			if slow == sourceHongguo {
				cache, err := readLibraryCache(c.downloader.cfg.dataDirectory())
				if err != nil || cache.HongguoApp != nil || len(cache.Dramas) != 0 {
					t.Fatal("other source persisted an uncommitted Hongguo page", err)
				}
			}
			close(release)
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			cache, err := readLibraryCache(c.downloader.cfg.dataDirectory())
			if err != nil || len(cache.Dramas) != 3 || len(cache.Huangguo) != 3 || !hongguoCatalogInitialized(cache.HongguoApp) {
				t.Fatal("last writer lost the other source snapshot", cache, err)
			}
		})
	}
}

func TestMobileHuangdouCatalogDoesNotWaitForHongguo(t *testing.T) {
	c := catalogConcurrencyClient(t, nil)
	unlock, err := c.lockCatalog(context.Background(), sourceHongguo)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	raw, err := c.Call(`{"method":"catalog","source":"huangdou","page":2,"timeoutMs":1000}`)
	var result struct{ Items []any }
	if err != nil || json.Unmarshal([]byte(raw), &result) != nil || len(result.Items) != 1 {
		t.Fatal("Huangdou queued behind another source", raw, err)
	}
}

func TestMobileCatalogWriteFailureKeepsFetchedRows(t *testing.T) {
	c := catalogConcurrencyClient(t, nil)
	if err := os.Mkdir(libraryCachePath(c.downloader.cfg.dataDirectory()), 0700); err != nil {
		t.Fatal(err)
	}
	raw, err := c.Call(`{"method":"catalog","source":"hongguo"}`)
	var result struct {
		Items   []any
		Warning string
	}
	if err != nil || json.Unmarshal([]byte(raw), &result) != nil || len(result.Items) != 3 || result.Warning == "" || len(c.known) != 3 {
		t.Fatal("cache write failure discarded fetched rows", raw, err)
	}
}

func TestMobileCatalogCanceledPageRestoresCursor(t *testing.T) {
	c := catalogConcurrencyClient(t, nil)
	before := c.downloader.hongguoCatalogSnapshot()
	transport := c.downloader.client.Transport
	count := 0
	c.downloader.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
		count++
		if count == 2 {
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		return transport.RoundTrip(r)
	})
	_, err := c.Call(`{"method":"catalog","source":"hongguo","timeoutMs":100}`)
	if err == nil || !reflect.DeepEqual(before, c.downloader.hongguoCatalogSnapshot()) || len(c.known) != 0 {
		t.Fatal("canceled partial page advanced the cursor without retaining its rows", err)
	}
}
