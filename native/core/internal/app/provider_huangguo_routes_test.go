package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestHuangguoPublisherRoutesUseOnlyValidatedArrayData(t *testing.T) {
	script := `var subdomains=['thu', // comment
	'pku']; var urls=['publisher-fixture.example.org/'];
	var otherUrls=['https://untrusted.example.org'];`
	want := []string{"https://thu.publisher-fixture.example.org", "https://pku.publisher-fixture.example.org"}
	if got := parseHuangguoPublishRoutes(script); !reflect.DeepEqual(got, want) {
		t.Fatal("publisher routes lost their declared domain/subdomain identity", got)
	}
	for _, host := range []string{"thu.publisher-fixture.example.org", "pku.publisher-fixture.example.org"} {
		t.Cleanup(func() { huangguoAIDiscoveredHosts.Delete(host) })
	}
	for _, script := range []string{
		`var urls=['127.0.0.1','192.168.1.1','localhost','https://bad.example.org','bad.example.org/path','huangguoai.pages.dev','huangguoai.com','hgai15.com'];`,
		`var urls=['one.example.org']; var urls=['two.example.org'];`,
		`var subdomains=['a/b','user@evil','a.b']; var urls=['domain.example.org'];`,
	} {
		if got := parseHuangguoPublishRoutes(script); len(got) != 0 {
			t.Fatal("accepted invalid publisher data", got)
		}
	}
}

func TestHuangguoDiscoveryFallsBackToOfficialPublisher(t *testing.T) {
	var paths []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		paths = append(paths, r.URL.Host+r.URL.RequestURI())
		if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" {
			t.Error("publisher inherited account credentials")
		}
		if deadline, ok := r.Context().Deadline(); !ok || time.Until(deadline) > 8*time.Second {
			t.Error("discovery is unbounded")
		}
		if r.URL.Host == "huangguoai.ai" || r.URL.Host == "hgai15.com" {
			return nil, errors.New("main landing unavailable")
		}
		if r.URL.Host != "huangguoai.pages.dev" {
			t.Fatal("publisher escaped its fixed origin")
		}
		if r.URL.Path == "/" {
			return rankingHTTPResponse(r, 200, `<script src="https://untrusted.example.org/publish.js"></script><script src="/publish.js?v=2"></script>`), nil
		}
		if r.URL.RequestURI() != "/publish.js?v=2" {
			t.Fatal("wrong publisher script")
		}
		return rankingHTTPResponse(r, 200, `var subdomains=['a'];var urls=['publisher-fallback.example.org'];`), nil
	})
	t.Cleanup(func() { huangguoAIDiscoveredHosts.Delete("a.publisher-fallback.example.org") })
	got := d.discoverHuangguoAIRoutes(context.Background(), false)
	if !reflect.DeepEqual(got, []string{"https://a.publisher-fallback.example.org"}) || len(paths) != 4 {
		t.Fatal("main failure did not use one bounded publisher read", paths, got)
	}
	if again := d.discoverHuangguoAIRoutes(context.Background(), false); !reflect.DeepEqual(again, got) || len(paths) != 4 {
		t.Fatal("discovery cache caused more requests")
	}
}

func TestHuangguoCancelledDiscoveryDoesNotReadPublisher(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		cancel()
		return nil, ctx.Err()
	})
	if got := d.discoverHuangguoAIRoutes(ctx, true); len(got) != 0 || calls != 1 {
		t.Fatal("cancelled discovery continued", got, calls)
	}
}

func TestHuangguoPublisherCannotRedirect(t *testing.T) {
	calls := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		response := rankingHTTPResponse(r, 302, "")
		response.Header.Set("Location", "https://untrusted.example.org/publish.js")
		return response, nil
	})
	if got := d.discoverHuangguoPublisher(context.Background()); len(got) != 0 || calls != 2 {
		t.Fatal("publisher redirect was followed", got, calls)
	}
	if got := parseHuangguoPublishRoutes("var urls=['" + strings.Repeat("a", 16400) + "'];"); len(got) != 0 {
		t.Fatal("unbounded route declaration accepted")
	}
}

func TestHuangguoFailedDiscoveryRefreshRetainsRoutesAndWarning(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		return nil, errors.New("publisher and landing unavailable")
	})
	d.huangguoAIRoutes = []string{"https://cached-line.example.org"}
	d.providerHosts[sourceHuangguoAI] = d.huangguoAIRoutes[0]
	result := d.huangguoLines(context.Background(), true)
	if result["warning"] == "" || !reflect.DeepEqual(d.huangguoAIRoutes, []string{"https://cached-line.example.org"}) || d.providerHosts[sourceHuangguoAI] != d.huangguoAIRoutes[0] {
		t.Fatal("failed refresh lost routes or hid its failure", result)
	}
}

func TestHuangguoColdMobilePlaybackUsesAlternatePublishedEntry(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	d := c.downloader
	d.limiter = newRequestLimiter(8, time.Nanosecond)
	const line = "https://cold-entry.example.org"
	t.Cleanup(func() { huangguoAIDiscoveredHosts.Delete("cold-entry.example.org") })
	mainCalls, entryCalls, playbackCalls, playlistCalls := 0, 0, 0, 0
	d.client = &http.Client{Transport: rankingTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Host {
		case "huangguoai.ai":
			mainCalls++
			return nil, errors.New("main TLS connection failed")
		case "hgai15.com":
			entryCalls++
			if r.URL.Path != "/" || r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" {
				t.Fatal("entry request lost its anonymous fixed-page scope")
			}
			if deadline, ok := r.Context().Deadline(); !ok || time.Until(deadline) > 8*time.Second {
				t.Fatal("entry discovery lost its total deadline")
			}
			return rankingHTTPResponse(r, 200, `<a data-url="`+line+`">官方线路</a>`), nil
		case "cold-entry.example.org":
			path := huangguoEnvelopePath(t, r)
			switch {
			case strings.HasPrefix(path, "/api/search?"):
				return huangguoAPIResponse(r, huangguoAPIPageFixture), nil
			case path == "/api/videos/501":
				return huangguoAPIResponse(r, `{"id":501,"title":"冷启动测试","episode_count":1,"episodes":[{"ep_num":1}]}`), nil
			case path == "/api/videos/501/episodes/1/playback":
				playbackCalls++
				return huangguoAPIResponse(r, `{"id":501,"ep":1,"manifest_method":"GET","streams":{"main":"https://media.example.org/index.m3u8"},"cdn":{"m3u8Enabled":true,"authKey":"x-cdn-auth","authValue":"synthetic-grant","app":"150"}}`), nil
			}
		case "media.example.org":
			playlistCalls++
			if r.Header.Get("Referer") != line+"/" || r.Header.Get("X-Cdn-Auth") != "synthetic-grant" {
				t.Fatal("discovered playback lost its route or CDN grant")
			}
			return rankingHTTPResponse(r, 200, "#EXTM3U\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n"), nil
		}
		t.Fatal("default playback escaped the declared discovery/API/media flow", r.URL.Host, r.URL.Path)
		return nil, errors.New("unexpected request")
	})}
	if len(d.huangguoAIRoutes) != 0 || d.huangguoLine != "" {
		t.Fatal("test must start without saved or injected routes")
	}
	if _, err := c.Call(`{"method":"search","source":"huangguo","query":"测试"}`); err != nil {
		t.Fatal("cold search did not discover the alternate entry", err)
	}
	raw, err := c.Call(`{"method":"chapters","id":"huangguoai:501"}`)
	if err != nil {
		t.Fatal(err)
	}
	var detail struct {
		Chapters []json.RawMessage `json:"chapters"`
	}
	if err := json.Unmarshal([]byte(raw), &detail); err != nil || len(detail.Chapters) != 1 {
		t.Fatal("cold detail lost its episode", err)
	}
	request, _ := json.Marshal(map[string]any{"method": "resolve", "id": "huangguoai:501", "chapter": detail.Chapters[0]})
	if _, err := c.Call(string(request)); err != nil {
		t.Fatal("cold playback still requires a manually injected line", err)
	}
	if mainCalls != 1 || entryCalls != 1 || playbackCalls != 1 || playlistCalls != 1 || d.huangguoLine != "" {
		t.Fatal("cold playback expanded discovery or changed manual selection", mainCalls, entryCalls, playbackCalls, playlistCalls)
	}
}

func TestHuangguoCancelledAlternateEntryCannotPublishLateRoutes(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host == "huangguoai.ai" {
			return nil, errors.New("main unavailable")
		}
		if r.URL.Host != "hgai15.com" {
			t.Fatal("cancelled entry continued to another publisher")
		}
		cancel()
		return rankingHTTPResponse(r, 200, `<a data-url="https://cancelled-entry.example.org">线路</a>`), nil
	})
	if routes := d.discoverHuangguoAIRoutes(ctx, false); len(routes) != 0 || len(d.huangguoAIRoutes) != 0 || calls != 2 {
		t.Fatal("cancelled entry installed routes or made more requests", routes, calls)
	}
	if huangguoAIIsContentHost("cancelled-entry.example.org") {
		t.Fatal("cancelled publisher expanded the known-host set")
	}
}
