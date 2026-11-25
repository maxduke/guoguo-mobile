package app

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHuangguoPlaybackUsesDirectAPIOnEdge503(t *testing.T) {
	const base = "https://first.example.org"
	const path = "/api/videos/501/episodes/3/playback"
	var calls []string
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		calls = append(calls, request.URL.Host+request.URL.Path)
		if request.URL.Host != "first.example.org" || request.Context().Value(huangguoAPIRequestKey{}) != true ||
			request.Context().Value(hppPublicRequestKey{}) == true || request.Header.Get("Cookie") != "" || request.Header.Get("Authorization") != "" {
			t.Fatal("playback request escaped the native anonymous route", request.URL)
		}
		if request.URL.Path == huangguoEdgePath {
			if huangguoEnvelopePath(t, request) != path {
				t.Fatal("edge identity changed")
			}
			return rankingHTTPResponse(request, 503, "temporary"), nil
		}
		body, err := io.ReadAll(request.Body)
		if err != nil || request.Method != http.MethodPost || request.URL.Path != path || string(body) != "{}" ||
			request.Header.Get("Origin") != base || request.Header.Get("Referer") != base+"/" {
			t.Fatal("wrong direct request", request.URL, request.Method, string(body), err)
		}
		return huangguoAPIResponse(request, `{"id":501,"ep":3,"manifest_method":"GET","streams":{"main":"/main.m3u8","preview":"/preview.m3u8"}}`), nil
	})
	media, origin, err := d.huangguoAPIPlayback(context.Background(), "501", "3")
	if err != nil || media.URL != base+"/main.m3u8" || origin != base || media.Referer != base+"/" || len(calls) != 2 {
		t.Fatalf("direct native playback did not preserve identity: %+v, %s, %v, %v", media, origin, err, calls)
	}
}

func TestHuangguoPlaybackStopsOnEdgeOrDirectRefusal(t *testing.T) {
	for _, deniedOnEdge := range []bool{true, false} {
		var calls int
		d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
			calls++
			if request.URL.Host != "first.example.org" {
				t.Fatal("playback tried another route after refusal")
			}
			if !deniedOnEdge && request.URL.Path == huangguoEdgePath {
				return rankingHTTPResponse(request, 503, "temporary"), nil
			}
			return rankingHTTPResponse(request, http.StatusForbidden, "refused"), nil
		})
		_, _, err := d.huangguoAPIPlayback(context.Background(), "501", "3")
		want := 2
		if deniedOnEdge {
			want = 1
		}
		if !errors.Is(err, errHuangguoAPIRejected) || calls != want {
			t.Fatalf("refusal was retried: edge=%v, calls=%d err=%v", deniedOnEdge, calls, err)
		}
	}
}

func TestHuangguoNewPlaybackCarriesCDNGrantIntoInitialPlaylist(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "media.example.org" {
			if r.Header.Get("X-Cdn-Auth") != "synthetic-grant" || r.Header.Get("X-Cdn-App") != "150" || r.Header.Get("Referer") != "https://line.example.org/" {
				t.Error("initial playlist lost its scoped CDN grant")
			}
			return rankingHTTPResponse(r, 200, "#EXTM3U\n#EXTINF:2,\none.ts\n#EXT-X-ENDLIST\n"), nil
		}
		if path := huangguoEnvelopePath(t, r); path != "/api/videos/501/episodes/3/playback" {
			t.Fatal("still using the old blank-URL endpoint", path)
		}
		return huangguoAPIResponse(r, `{"id":501,"ep":3,"manifest_method":"GET","streams":{"main":"https://media.example.org/index.m3u8"},"cdn":{"m3u8Enabled":true,"otherEnabled":false,"authKey":"x-cdn-auth","authValue":"synthetic-grant","app":"150"}}`), nil
	})
	d.huangguoLine = "https://line.example.org"
	media, err := d.resolveProviderMedia(context.Background(), Task{DramaID: "huangguoai:501", Chapter: Chapter{ID: "huangguoai:501:ep-3", CurrentEpisode: rawEpisode(3)}})
	if err != nil || media.credentials == nil || media.Playlist == "" {
		t.Fatal("new playback failed", err)
	}
}

func TestHuangguoCDNHeadersStayOnGrantedResourcesAcrossRedirects(t *testing.T) {
	foreignCalls := 0
	foreign := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		foreignCalls++
		if r.Header.Get("X-Cdn-Auth") != "" || r.Header.Get("X-Cdn-App") != "" {
			t.Error("CDN grant leaked to a foreign origin")
		}
		io.WriteString(w, "foreign")
	}))
	defer foreign.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".m3u8") {
			if r.Header.Get("X-Cdn-Auth") != "synthetic-grant" {
				t.Error("same-origin manifest lost grant")
			}
		} else if r.Header.Get("X-Cdn-Auth") != "" {
			t.Error("manifest-only grant leaked to a segment")
		}
		if r.URL.Path == "/redirect.m3u8" {
			http.Redirect(w, r, foreign.URL+"/remote.m3u8", 302)
			return
		}
		io.WriteString(w, "fixture")
	}))
	defer origin.Close()
	credentials := &providerMediaCredentials{origin: origin.URL, headers: http.Header{"X-Cdn-Auth": {"synthetic-grant"}, "X-Cdn-App": {"150"}}, headerExtensions: []string{".m3u8"}}
	client := credentials.client(origin.Client())
	for _, path := range []string{"/index.m3u8", "/one.ts", "/redirect.m3u8"} {
		r, _ := http.NewRequest(http.MethodGet, origin.URL+path, nil)
		if err := credentials.apply(r); err != nil {
			t.Fatal(err)
		}
		response, err := client.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, response.Body)
		response.Body.Close()
	}
	if foreignCalls != 1 {
		t.Fatal("redirect coverage did not execute")
	}
}

func TestHuangguoPlaybackRejectsArbitraryCDNHeaders(t *testing.T) {
	for _, name := range []string{"Authorization", "Cookie", "Host", "X-Unknown", "x-cdn-auth\r\nInjected"} {
		_, err := huangguoPlaybackCredentials(providerMedia{URL: "https://media.example.org/a.m3u8"}, map[string]any{"m3u8Enabled": true, "authKey": name, "authValue": "synthetic", "app": "150"})
		if err == nil {
			t.Fatal("accepted an arbitrary credential header", name)
		}
	}
}

func TestHuangguoCDNGrantSurvivesNestedHLSProxy(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/child.m3u8" {
			if r.Header.Get("X-Cdn-Auth") != "synthetic-grant" {
				t.Error("nested playlist lost the CDN grant")
			}
			io.WriteString(w, "#EXTM3U\n#EXTINF:2,\none.ts\n#EXT-X-ENDLIST\n")
			return
		}
		if r.URL.Path != "/one.ts" || r.Header.Get("X-Cdn-Auth") != "" {
			t.Error("manifest grant reached an unprotected segment")
		}
		io.WriteString(w, "synthetic-segment")
	}))
	defer origin.Close()
	d := &Downloader{client: origin.Client()}
	credentials := &providerMediaCredentials{origin: origin.URL, headers: http.Header{"X-Cdn-Auth": {"synthetic-grant"}, "X-Cdn-App": {"150"}}, headerExtensions: []string{".m3u8"}}
	proxy, err := d.newHLSProxy(context.Background(), providerMedia{URL: origin.URL + "/master.m3u8", Playlist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n", credentials: credentials}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	next := proxy.root
	for range 2 {
		status, raw := prefetchRead(t, origin.Client(), next, "GET", "")
		if status.StatusCode != 200 || strings.Contains(string(raw), "synthetic-grant") {
			t.Fatal("proxy failed or exposed its CDN grant")
		}
		next = ""
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(line, "http") {
				next = line
				break
			}
		}
		if next == "" {
			t.Fatal("proxy did not rewrite the nested resource")
		}
	}
	status, raw := prefetchRead(t, origin.Client(), next, "GET", "")
	if status.StatusCode != 200 || string(raw) != "synthetic-segment" {
		t.Fatal("nested segment could not be read through playback proxy")
	}
}

func TestHuangguoDownloadDoesNotExportResourceScopedGrant(t *testing.T) {
	for _, protectedSegments := range []bool{false, true} {
		d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
			if r.URL.Host == "media.example.org" {
				if r.Header.Get("X-Cdn-Auth") != "synthetic-grant" {
					t.Error("download manifest lost its grant")
				}
				return rankingHTTPResponse(r, 200, "#EXTM3U\n#EXTINF:2,\none.ts\n#EXT-X-ENDLIST\n"), nil
			}
			return huangguoAPIResponse(r, hongguoJSON(map[string]any{"id": 501, "ep": 3, "manifest_method": "GET", "streams": map[string]string{"main": "https://media.example.org/a.m3u8"}, "cdn": map[string]any{"m3u8Enabled": true, "otherEnabled": protectedSegments, "authKey": "x-cdn-auth", "authValue": "synthetic-grant", "app": "150"}})), nil
		})
		d.huangguoLine = "https://line.example.org"
		c := &MobileClient{downloader: d}
		plan, err := c.downloadPlan(context.Background(), mobileRequest{ID: "huangguoai:501", Chapter: Chapter{ID: "huangguoai:501:ep-3", CurrentEpisode: rawEpisode(3)}})
		if protectedSegments {
			if err == nil {
				t.Fatal("background task exported a resource-scoped credential")
			}
			continue
		}
		if err != nil || !plan.RefreshOnResume || len(plan.Assets) != 1 {
			t.Fatal("manifest-only grant broke durable downloads", err)
		}
		if strings.Contains(hongguoJSON(plan), "synthetic-grant") || strings.Contains(plan.Assets[0].URL, "127.0.0.1") {
			t.Fatal("download exported an ephemeral grant or loopback session")
		}
	}
}
