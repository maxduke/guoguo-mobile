package app

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestHuangguoMediaCertificateFallbackIsScoped(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "#EXTM3U\n#EXT-X-ENDLIST\n") }))
	defer server.Close()
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	client := &http.Client{Transport: base}
	media := providerMedia{URL: server.URL, certificateFallback: true}
	fallback := mediaHTTPClient(client, media)
	response, err := fallback.Get(server.URL)
	if err != nil {
		t.Fatal("certificate fallback did not succeed", err)
	}
	response.Body.Close()
	if base.TLSClientConfig != nil && base.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("shared transport was modified")
	}
	if response, err := client.Get(server.URL); err == nil {
		response.Body.Close()
		t.Fatal("ordinary requests bypassed certificate validation")
	}
	other := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "other") }))
	defer other.Close()
	if response, err := fallback.Get(other.URL); err == nil {
		response.Body.Close()
		t.Fatal("fallback escaped original media origin")
	}
	request, _ := http.NewRequest(http.MethodGet, server.URL, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := fallback.Do(request.WithContext(ctx)); err == nil {
		t.Fatal("cancellation was ignored")
	}
	fallback.CloseIdleConnections()
}

func TestExtensionlessPlaylistUsesRedirectBaseAndBoundedProbe(t *testing.T) {
	var probes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/play" {
			http.Redirect(w, r, "/hls/stream", 302)
			return
		}
		if r.Header.Get("Range") == "bytes=0-511" {
			probes.Add(1)
		}
		io.WriteString(w, "#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n")
	}))
	defer server.Close()
	d := rankingTestDownloader(t, nil)
	d.client = server.Client()
	media, err := d.prepareMobileMedia(context.Background(), providerMedia{URL: server.URL + "/play"})
	if err != nil || probes.Load() != 1 || media.URL != server.URL+"/hls/stream" || !strings.HasPrefix(media.Playlist, "#EXTM3U") {
		t.Fatal("extensionless HLS resolution", media, err)
	}
	plan, err := (&MobileClient{downloader: d}).planMobileMedia(context.Background(), media, nil)
	if err != nil || plan.Input != "index.m3u8" || len(plan.Assets) != 1 || plan.Assets[0].URL != server.URL+"/hls/segment.ts" {
		t.Fatal("extensionless offline resource graph", plan, err)
	}
	proxy, err := d.newHLSProxy(context.Background(), media, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	response, err := http.Get(proxy.root)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if !strings.Contains(string(body), proxy.base) {
		t.Fatal("relative resources were not rewritten")
	}
}

func TestMobileInitialPlaylistFallbackKeepsQuality(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/bad.m3u8" {
			return rankingHTTPResponse(r, 403, "expired"), nil
		}
		return rankingHTTPResponse(r, 200, "#EXTM3U\n#EXT-X-ENDLIST\n"), nil
	})
	c := &MobileClient{downloader: d}
	choice := mobilePlaybackChoice{media: []providerMedia{{URL: "https://fixture.example/bad.m3u8", Quality: 1080}, {URL: "https://fixture.example/backup.m3u8", Quality: 1080}, {URL: "https://fixture.example/low.m3u8", Quality: 720}}}
	prepared, err := c.prepareMobileChoice(context.Background(), choice)
	if err != nil || prepared.index != 1 || prepared.media[1].Quality != 1080 {
		t.Fatal("initial fallback", prepared.index, err)
	}
	choice.media = []providerMedia{choice.media[0], choice.media[2]}
	if _, err := c.prepareMobileChoice(context.Background(), choice); err == nil {
		t.Fatal("silently lowered quality")
	}
}

func TestMobileSearchProgressAndCancelAreRequestScoped(t *testing.T) {
	c := &MobileClient{}
	request := mobileRequest{RequestID: "first", Source: "hongguo", Query: "test"}
	ctx, read, err := c.beginSearch(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	defer read.cancel()
	c.updateSearch(request.RequestID, read, map[string]any{"items": []string{"partial"}}, false)
	if c.searchProgress(request, false)["done"] != false {
		t.Fatal("missing partial state")
	}
	wrong := request
	wrong.Query = "another"
	c.searchProgress(wrong, true)
	if ctx.Err() != nil {
		t.Fatal("another query canceled this read")
	}
	c.searchProgress(request, true)
	if ctx.Err() != context.Canceled {
		t.Fatal("read not canceled")
	}
	c.updateSearch(request.RequestID, read, map[string]any{"items": []string{"late"}}, false)
	if c.searchProgress(request, false)["done"] != true {
		t.Fatal("late progress resurrected canceled request")
	}
	early := mobileRequest{RequestID: "early", Source: "hongguo", Query: "waiting"}
	c.searchProgress(early, true)
	if _, _, err := c.beginSearch(context.Background(), early); err != context.Canceled {
		t.Fatal("cancel-before-dispatch lost", err)
	}
}

func TestHuangguoRouteIdentityAndRelativeCover(t *testing.T) {
	routes := parseHuangguoAIRoutes(`<a data-url="https://new-route.example.org">线路</a><a data-url="http://127.0.0.1">bad</a><a data-url="https://tp1.cdn.example">media</a><a href="https://t.me/foo">social</a>`)
	if len(routes) != 1 || routes[0] != "https://new-route.example.org" {
		t.Fatal("route filtering", routes)
	}
	body := `<script>const cdnDomain="https://art.example.org/"</script><script id="videoInitialData">{"id":"501","title":"测试作品","ep":2,"total":3,"coverSrc":"/poster.jpg","epPlaySrcs":{"ep-2":"https://media.example/stream"}}</script><a href="/video/999/ep-4/">unrelated</a>`
	page := "https://new-route.example.org/video/501/ep-2/"
	if err := validateHuangguoAIPlaybackPage(body, page, "501", "2"); err != nil {
		t.Fatal(err)
	}
	if err := validateHuangguoAIPlaybackPage(body, page, "501", "3"); err == nil {
		t.Fatal("wrong episode accepted")
	}
	if err := validateHuangguoAIDetailPage(body, page, "999"); err == nil {
		t.Fatal("wrong drama accepted")
	}
	eps := parseHuangguoAIEpisodes(body, page, "501")
	if len(eps) != 3 || eps[1].HLS != "https://media.example/stream" {
		t.Fatal("episodes not scoped", eps)
	}
	drama, err := parseHuangguoSortDetail(body, page, Drama{Source: sourceHuangguoAI, SourceID: "501"})
	if err != nil || bestDramaCover(drama) != "https://art.example.org/poster.jpg" {
		t.Fatal("relative cover metadata", bestDramaCover(drama), err)
	}
}

func TestHuangguoSearchRediscoversStaleContentRoute(t *testing.T) {
	forced := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Host {
		case "huangguoai.ai":
			if r.Header.Get("Cache-Control") == "no-cache" {
				forced++
				return rankingHTTPResponse(r, 200, `<a data-url="https://new-content.example.org">线路</a>`), nil
			}
			return rankingHTTPResponse(r, 200, `<a data-url="https://stale-content.example.org">线路</a>`), nil
		case "stale-content.example.org":
			return rankingHTTPResponse(r, 404, "stale"), nil
		case "new-content.example.org":
			if r.URL.Path != "/search/video/测试/2/" {
				t.Error("search paging lost", r.URL.Path)
			}
			return rankingHTTPResponse(r, 200, `<div class="hg-search-results"><a href="/video/55/">测试剧</a><a rel="next" href="/search/video/测试/3/">下一页</a></div>`), nil
		default:
			t.Error("unexpected source request", r.URL)
			return rankingHTTPResponse(r, 404, ""), nil
		}
	})
	rows, more, err := d.searchHuangguoAI(context.Background(), "测试", 2)
	if err != nil || forced != 1 || len(rows) != 1 || rows[0].ID != "huangguoai:55" || !more {
		t.Fatal("route refresh", rows, more, forced, err)
	}
}
func TestMobileHongguoSeasonExtensionStopsAfterTwoMisses(t *testing.T) {
	var queries []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		query := r.URL.Query().Get("query")
		queries = append(queries, query)
		if query == "修仙第二季" {
			return rankingHTTPResponse(r, 200, `{"suggest_list":[{"word_type":"short_play_name","name":"修仙第二季","video_data":{"series_id":"7300000000000000002","episode_cnt":10}}]}`), nil
		}
		return rankingHTTPResponse(r, 200, `{"suggest_list":[]}`), nil
	})
	entry := hongguoSearchEntry{Dramas: []Drama{{ID: "hongguo:7300000000000000001", Title: "修仙第一季"}}}
	ctx := context.WithValue(context.Background(), hongguoSearchSeasonExtensionKey{}, true)
	if d.completeHongguoSearchSeasons(ctx, "修仙", &entry) || len(entry.Dramas) != 2 || len(queries) != 3 || queries[2] != "修仙第四季" {
		t.Fatal("extension bound", entry.Dramas, queries)
	}
}
func TestMobileCoreInfoUsesCurrentBridgeProtocol(t *testing.T) {
	c := &MobileClient{}
	body, err := c.Call(`{"method":"coreInfo"}`)
	if err != nil || !strings.Contains(body, `"protocol":3`) || !strings.Contains(body, `"sourceDigest":`) {
		t.Fatal(body, err)
	}
}
