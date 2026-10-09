package app

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

const huangguoRankingRefreshFixture = `<script type="application/ld+json">{"@graph":[{"@type":"ItemList","@id":"https://ranking.example.org/ranks/hot/#itemlist","itemListElement":[{"position":1,"name":"测试作品","url":"https://ranking.example.org/video/117/"}]}]}</script>`

func TestHuangguoRankingAllowsSlowConnectionBeforeTryingOtherRoutes(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		select {
		case <-time.After(3200 * time.Millisecond):
			return rankingHTTPResponse(r, 200, huangguoRankingRefreshFixture), nil
		case <-r.Context().Done():
			return nil, r.Context().Err()
		}
	})
	d.cfg.HuangguoAIURL = "https://ranking.example.org"
	board, _ := findRankingBoard("huangguo-hot")
	result, err := d.loadRankingPage(context.Background(), board, 1, true)
	if err != nil || len(result.Items) != 1 || result.Stale {
		t.Fatalf("usable slow route was abandoned before DNS fallback could finish: %+v err=%v", result, err)
	}
}

func TestMobileRankingRefreshBypassesCacheAndKeepsStaleTimestamp(t *testing.T) {
	calls, fail := 0, false
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		if calls > 1 && r.Header.Get("Cache-Control") != "no-cache" {
			t.Error("manual refresh reused the upstream cache")
		}
		if fail {
			return rankingHTTPResponse(r, 503, "unavailable"), nil
		}
		return rankingHTTPResponse(r, 200, huangguoRankingRefreshFixture), nil
	})
	d.cfg.HuangguoAIURL = "https://ranking.example.org"
	c := &MobileClient{downloader: d}
	read := func(refresh bool) map[string]any {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"method": "ranking", "board": "huangguo-hot", "refresh": refresh})
		response, err := c.Call(string(raw))
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		if err := json.Unmarshal([]byte(response), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	first := read(false)
	again := read(false)
	if calls != 1 || first["fetchedAt"] != again["fetchedAt"] || first["boardId"] != "huangguo-hot" || first["page"] != float64(1) {
		t.Fatal("ordinary reads did not reuse the board's cache")
	}
	fresh := read(true)
	if calls != 2 || fresh["stale"] != false {
		t.Fatal("manual refresh did not fetch a fresh page")
	}
	fail = true
	stale := read(true)
	if calls != 3 || stale["stale"] != true || stale["fetchedAt"] != fresh["fetchedAt"] || stale["warning"] == "" {
		t.Fatal("fallback lost the original cache age or warning", stale)
	}
}

func TestHuangguoRankingRediscoversRoutesAfterInvalidCachedPage(t *testing.T) {
	oldRoute, newRoute := "https://old-ranking.example.org", "https://new-ranking.example.org"
	parseHuangguoAIRoutes(`<a data-url="` + oldRoute + `"></a>`)
	oldCalls, entryCalls, newCalls := 0, 0, 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasPrefix(r.URL.String(), oldRoute):
			oldCalls++
			return rankingHTTPResponse(r, 200, `<html>route expired</html>`), nil
		case r.URL.String() == huangguoAIBaseURL+"/":
			entryCalls++
			if r.Header.Get("Cache-Control") != "no-cache" {
				t.Error("forced route discovery did not revalidate the entry page")
			}
			return rankingHTTPResponse(r, 200, `<a data-url="`+newRoute+`"></a>`), nil
		case strings.HasPrefix(r.URL.String(), newRoute):
			newCalls++
			return rankingHTTPResponse(r, 200, huangguoRankingRefreshFixture), nil
		default:
			t.Errorf("unexpected route %s", r.URL.Host)
			return rankingHTTPResponse(r, 404, ""), nil
		}
	})
	d.huangguoAIRoutes = []string{oldRoute}
	d.providerHosts[sourceHuangguoAI] = oldRoute
	board, _ := findRankingBoard("huangguo-hot")
	result, err := d.loadRankingPage(context.Background(), board, 1, true)
	if err != nil || len(result.Items) != 1 || oldCalls != 1 || entryCalls != 1 || newCalls != 1 {
		t.Fatalf("route recovery failed: old=%d entry=%d new=%d err=%v", oldCalls, entryCalls, newCalls, err)
	}
	if d.providerHosts[sourceHuangguoAI] != newRoute {
		t.Fatal("the valid new route was not retained")
	}
}
