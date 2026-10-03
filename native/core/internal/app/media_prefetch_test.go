package app

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func prefetchRead(t *testing.T, client *http.Client, address, method, span string) (*http.Response, []byte) {
	t.Helper()
	request, _ := http.NewRequest(method, address, nil)
	request.Header.Set("Range", span)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	return response, data
}

func TestMediaPrefetchReusesMP4RangesAndHead(t *testing.T) {
	payload := []byte("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
	for _, budget := range []int64{16, 100} {
		t.Run(strconv.FormatInt(budget, 10), func(t *testing.T) {
			var calls atomic.Int32
			proxy, client := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Header.Get("Referer") != "https://example.invalid/" || r.Header.Get("Accept-Encoding") != "identity" {
					t.Error("lost media headers")
				}
				w.Header().Set("ETag", `"one"`)
				w.Header().Set("Content-Type", "video/mp4")
				http.ServeContent(w, r, "fixture", time.Time{}, bytes.NewReader(payload))
			})
			stats := proxy.prefetch(context.Background(), 0, budget)
			want := min(budget, int64(len(payload)))
			if stats.cached != want || stats.requests != 1 || stats.read > budget {
				t.Fatalf("unexpected budget: %+v", stats)
			}
			response, data := prefetchRead(t, client, proxy.root, http.MethodHead, "bytes=2-40")
			if response.StatusCode != 206 || len(data) != 0 || response.ContentLength != 39 || calls.Load() != 1 {
				t.Fatal("HEAD fetched the tail or lost range metadata")
			}
			response, data = prefetchRead(t, client, proxy.root, http.MethodGet, "bytes=2-10")
			if response.StatusCode != 206 || !bytes.Equal(data, payload[2:11]) || calls.Load() != 1 {
				t.Fatal("cached range was fetched twice")
			}
			response, data = prefetchRead(t, client, proxy.root, http.MethodGet, "")
			expectedCalls := int32(2)
			if budget >= int64(len(payload)) {
				expectedCalls = 1
			}
			if response.StatusCode != 200 || !bytes.Equal(data, payload) || calls.Load() != expectedCalls {
				t.Fatal("whole playback did not reuse the prefix")
			}
			if proxy.reusedBytes.Load() != 9+want || proxy.Err() != nil {
				t.Fatal("reuse accounting or playback failed")
			}
			// Suffix and multi-ranges remain available through the normal proxy path.
			_, data = prefetchRead(t, client, proxy.root, http.MethodGet, "bytes=-4")
			if !bytes.Equal(data, payload[len(payload)-4:]) {
				t.Fatal("suffix seek regressed")
			}
		})
	}
}

func TestMediaPrefetchRejectsChangedContinuation(t *testing.T) {
	for _, failure := range []string{"ignored range", "etag", "total", "encoding", "last modified"} {
		t.Run(failure, func(t *testing.T) {
			var calls atomic.Int32
			old := bytes.Repeat([]byte("a"), 80)
			fresh := bytes.Repeat([]byte("b"), 80)
			proxy, client := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) {
				attempt := calls.Add(1)
				w.Header().Set("Content-Type", "video/mp4")
				w.Header().Set("ETag", `"one"`)
				w.Header().Set("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")
				if attempt == 1 {
					http.ServeContent(w, r, "media", time.Time{}, bytes.NewReader(old))
					return
				}
				if attempt == 2 {
					if r.Header.Get("Range") != "bytes=16-45" || r.Header.Get("If-Range") != `"one"` {
						t.Error("tail lacks identity or range")
					}
					w.Header().Set("Content-Range", "bytes 16-45/80")
					switch failure {
					case "ignored range":
						w.Write(fresh)
						return
					case "etag":
						w.Header().Set("ETag", `"two"`)
					case "total":
						w.Header().Set("Content-Range", "bytes 16-45/81")
					case "encoding":
						w.Header().Set("Content-Encoding", "gzip")
					case "last modified":
						w.Header().Set("Last-Modified", "Thu, 02 Jan 2025 00:00:00 GMT")
					}
					w.WriteHeader(206)
					w.Write(fresh[16:46])
					return
				}
				if r.Header.Get("Range") != "bytes=5-45" {
					t.Error("fallback changed the original request")
				}
				http.ServeContent(w, r, "media", time.Time{}, bytes.NewReader(fresh))
			})
			proxy.prefetch(context.Background(), 0, 16)
			_, data := prefetchRead(t, client, proxy.root, http.MethodGet, "bytes=5-45")
			if !bytes.Equal(data, fresh[5:46]) || calls.Load() != 3 || proxy.reusedBytes.Load() != 0 || proxy.Err() != nil {
				t.Fatal("changed object was spliced or warming poisoned playback")
			}
			proxy.mu.Lock()
			retained := len(proxy.prefetched)
			proxy.mu.Unlock()
			if retained != 0 {
				t.Fatal("invalid prefix retained")
			}
		})
	}
}

func TestMediaPrefetchTailRetainsBodyResumption(t *testing.T) {
	var calls atomic.Int32
	payload := bytes.Repeat([]byte("0123456789"), 10)
	proxy, client := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) {
		attempt := calls.Add(1)
		w.Header().Set("ETag", `"one"`)
		w.Header().Set("Content-Type", "video/mp4")
		if attempt != 2 {
			http.ServeContent(w, r, "media", time.Time{}, bytes.NewReader(payload))
			return
		}
		w.Header().Set("Content-Length", "84")
		w.Header().Set("Content-Range", "bytes 16-99/100")
		w.WriteHeader(206)
		w.Write(payload[16:23])
	})
	proxy.prefetch(context.Background(), 0, 16)
	_, data := prefetchRead(t, client, proxy.root, http.MethodGet, "")
	if !bytes.Equal(data, payload) || calls.Load() != 3 || proxy.Err() != nil {
		t.Fatal("truncated cached tail did not resume")
	}
}

func TestMediaPrefetchRejectsUnsafePrefix(t *testing.T) {
	for _, kind := range []string{"no validator", "weak validator", "wrong range", "truncated", "encoded", "unknown length at limit"} {
		t.Run(kind, func(t *testing.T) {
			proxy, _ := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Length", "80")
				if kind != "no validator" {
					w.Header().Set("ETag", `"one"`)
				}
				switch kind {
				case "weak validator":
					w.Header().Set("ETag", `W/"one"`)
				case "wrong range":
					w.Header().Set("Content-Range", "bytes 1-16/80")
					w.Header().Set("Content-Length", "16")
					w.WriteHeader(206)
				case "truncated":
					w.Write([]byte("tiny"))
					return
				case "encoded":
					w.Header().Set("Content-Encoding", "gzip")
				case "unknown length at limit":
					w.Header().Del("Content-Length")
					w.(http.Flusher).Flush()
				}
				w.Write(bytes.Repeat([]byte("a"), 80))
			})
			stats := proxy.prefetch(context.Background(), 0, 16)
			if stats.cached != 0 || stats.read > 16 || proxy.Err() != nil {
				t.Fatalf("unsafe prefix published: %+v", stats)
			}
		})
	}
}

func TestMediaPrefetchHLSSelectsOneRenditionAndReusesAssets(t *testing.T) {
	for _, quality := range []int{0, 720} {
		t.Run(strconv.Itoa(quality), func(t *testing.T) {
			var mu sync.Mutex
			hits := map[string]int{}
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				hits[r.URL.Path]++
				mu.Unlock()
				if strings.HasSuffix(r.URL.Path, ".m3u8") {
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					fmt.Fprint(w, "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\none.m4s\n#EXTINF:4,\ntwo.m4s\n#EXTINF:4,\nthree.m4s\n#EXT-X-ENDLIST\n")
					return
				}
				http.ServeContent(w, r, "asset", time.Time{}, strings.NewReader("fixture bytes"))
			}))
			defer origin.Close()
			media := providerMedia{URL: origin.URL + "/master.m3u8", Playlist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720\n720/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000,RESOLUTION=1920x1080\n1080/index.m3u8\n"}
			d := &Downloader{client: origin.Client()}
			proxy, err := d.newHLSProxy(context.Background(), media, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer proxy.Close()
			stats := proxy.prefetch(context.Background(), quality, 4096)
			folder := "/1080/"
			if quality == 720 {
				folder = "/720/"
			}
			if stats.requests != 5 || stats.cached == 0 || stats.cached > 4096 {
				t.Fatalf("unexpected HLS warmup: %+v", stats)
			}
			mu.Lock()
			for _, name := range []string{"index.m3u8", "init.mp4", "key.bin", "one.m4s", "two.m4s"} {
				if hits[folder+name] != 1 {
					t.Errorf("missing warmup: %s %+v", name, hits)
				}
			}
			if len(hits) != 5 {
				t.Errorf("warmed extra segments/renditions: %+v", hits)
			}
			mu.Unlock()
			_, master := prefetchRead(t, origin.Client(), proxy.root, "GET", "")
			variant := prefetchVariant(string(master), quality)
			_, playlist := prefetchRead(t, origin.Client(), variant, "GET", "")
			// Read all warmed URI resources as a real player would.
			for _, match := range hlsURIAttribute.FindAllStringSubmatch(string(playlist), -1) {
				prefetchRead(t, origin.Client(), match[1], "GET", "")
			}
			segments := 0
			for _, line := range strings.Split(string(playlist), "\n") {
				if strings.HasPrefix(line, "http") && segments < 2 {
					prefetchRead(t, origin.Client(), line, "GET", "")
					segments++
				}
			}
			mu.Lock()
			for address, count := range hits {
				if count != 1 {
					t.Errorf("refetched warmed asset: %s %d", address, count)
				}
			}
			mu.Unlock()
		})
	}
}

func TestMediaPrefetchBudgetsAndUnsupportedPlaylists(t *testing.T) {
	t.Run("bytes", func(t *testing.T) {
		payload := bytes.Repeat([]byte("a"), mediaPrefetchBytes+100)
		proxy, _ := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("ETag", `"one"`)
			http.ServeContent(w, r, "media", time.Time{}, bytes.NewReader(payload))
		})
		stats := proxy.prefetch(context.Background(), 0, mediaPrefetchBytes*2)
		if stats.cached != mediaPrefetchBytes || stats.read != mediaPrefetchBytes || stats.requests != 1 {
			t.Fatalf("unbounded bytes: %+v", stats)
		}
	})
	t.Run("redirects", func(t *testing.T) {
		var calls atomic.Int32
		proxy, _ := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) { calls.Add(1); http.Redirect(w, r, "/fixture.mp4", 302) })
		stats := proxy.prefetch(context.Background(), 0, 100)
		if calls.Load() != mediaPrefetchRequests || stats.requests != mediaPrefetchRequests || stats.cached != 0 {
			t.Fatalf("unbounded redirects: %+v calls=%d", stats, calls.Load())
		}
	})
	for _, playlist := range []string{"#EXTM3U\n#EXTINF:4,\none.ts\n", "#EXTM3U\n#EXT-X-BYTERANGE:16@0\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n"} {
		t.Run(playlist, func(t *testing.T) {
			var calls atomic.Int32
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
				fmt.Fprint(w, playlist)
			}))
			defer origin.Close()
			d := &Downloader{client: origin.Client()}
			proxy, err := d.newHLSProxy(context.Background(), providerMedia{URL: origin.URL + "/index.m3u8", Playlist: playlist}, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer proxy.Close()
			stats := proxy.prefetch(context.Background(), 0, 1024)
			if stats.cached != 0 || calls.Load() > 1 {
				t.Fatal("live/BYTERANGE segments warmed")
			}
			prefetchRead(t, origin.Client(), proxy.root, "GET", "")
		})
	}
}

func TestMediaPrefetchPreservesCredentialScope(t *testing.T) {
	var foreignCalls atomic.Int32
	foreign := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		foreignCalls.Add(1)
		if r.Header.Get("Cookie") != "" {
			t.Error("prefetch leaked cookie")
		}
		w.Write([]byte("clear segment"))
	}))
	defer foreign.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "grant=secret" {
			t.Error("missing origin grant")
		}
		http.Redirect(w, r, foreign.URL+"/segment.ts", 302)
	}))
	defer origin.Close()
	d := &Downloader{client: origin.Client()}
	proxy, err := d.newHLSProxy(context.Background(), providerMedia{URL: origin.URL + "/index.m3u8", Playlist: "#EXTM3U\n#EXTINF:4,\nredirect.ts\n#EXT-X-ENDLIST\n", credentials: &providerMediaCredentials{origin: origin.URL, cookie: "grant=secret"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	stats := proxy.prefetch(context.Background(), 0, 1024)
	if stats.cached == 0 || stats.requests != 2 {
		t.Fatalf("scoped warmup failed: %+v", stats)
	}
	_, playlist := prefetchRead(t, origin.Client(), proxy.root, "GET", "")
	for _, line := range strings.Split(string(playlist), "\n") {
		if strings.HasPrefix(line, "http") {
			prefetchRead(t, origin.Client(), line, "GET", "")
		}
	}
	if foreignCalls.Load() != 1 {
		t.Fatal("credential-scoped cached segment was fetched again")
	}
}

func TestMobilePrefetchCancellationPromotionAndRelease(t *testing.T) {
	for _, action := range []string{"promotion", "release", "close", "expired", "before dispatch"} {
		t.Run(action, func(t *testing.T) {
			began, stopped := make(chan struct{}), make(chan struct{})
			var calls atomic.Int32
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if calls.Add(1) == 1 {
					close(began)
				}
				<-r.Context().Done()
				close(stopped)
			}))
			defer origin.Close()
			c, err := NewMobileClient(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			choice, _ := mobilePlaybackChoices(providerMedia{URL: origin.URL + "/extensionless"}, nil, 0)
			plan, err := c.openMobilePlayback(choice)
			if err != nil {
				t.Fatal(err)
			}
			session := plan["session"].(string)
			if action == "before dispatch" {
				c.cancelPlaybackPrefetch(session)
				result, err := c.prefetchPlayback(context.Background(), session)
				if err != nil || result["url"] != plan["url"] || calls.Load() != 0 {
					t.Fatal("cancel-before-dispatch started work")
				}
				return
			}
			completed := make(chan error, 1)
			go func() {
				result, err := c.prefetchPlayback(context.Background(), session)
				if action == "promotion" && err == nil {
					address, _ := url.Parse(result["url"].(string))
					if !strings.HasSuffix(address.Path, ".mp4") {
						completed <- fmt.Errorf("extensionless MP4 lost its kind")
						return
					}
				}
				completed <- err
			}()
			select {
			case <-began:
			case <-time.After(time.Second * 3):
				t.Fatal("warmup did not start")
			}
			switch action {
			case "promotion":
				c.cancelPlaybackPrefetch(session)
			case "expired":
				c.mu.Lock()
				choice := c.playbacks[session]
				choice.created = time.Now().Add(-3 * time.Minute)
				c.playbacks[session] = choice
				c.mu.Unlock()
				c.cancelPlaybackPrefetch(session)
			case "release":
				c.Call(fmt.Sprintf(`{"method":"release","id":%q}`, session))
			case "close":
				c.Close()
			}
			select {
			case <-stopped:
			case <-time.After(time.Second * 3):
				t.Fatal("warmup request survived cancellation")
			}
			select {
			case err := <-completed:
				if action == "promotion" && err != nil {
					t.Fatal(err)
				}
				if action == "expired" && err == nil {
					t.Fatal("warmup returned an expired playback session")
				}
			case <-time.After(time.Second * 3):
				t.Fatal("warmup result blocked")
			}
			if action == "release" || action == "close" {
				c.mu.Lock()
				retained := len(c.prefetches) + len(c.proxies) + len(c.playbacks)
				c.mu.Unlock()
				if retained != 0 {
					t.Fatal("released session retained resources")
				}
			}
		})
	}
}

func TestMobilePrefetchSharesWorkAndRetainsCompletedPrefix(t *testing.T) {
	began, stopped := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path == "/first.ts" {
			w.Write([]byte("cached first segment"))
			return
		}
		close(began)
		<-r.Context().Done()
		close(stopped)
	}))
	defer origin.Close()
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	choice, _ := mobilePlaybackChoices(providerMedia{URL: origin.URL + "/index.m3u8", Playlist: "#EXTM3U\n#EXTINF:4,\nfirst.ts\n#EXTINF:4,\nsecond.ts\n#EXT-X-ENDLIST\n"}, nil, 0)
	plan, err := c.openMobilePlayback(choice)
	if err != nil {
		t.Fatal(err)
	}
	session := plan["session"].(string)
	results := make(chan map[string]any, 2)
	done := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			result, err := c.prefetchPlayback(context.Background(), session)
			results <- result
			done <- err
		}()
	}
	select {
	case <-began:
	case <-time.After(3 * time.Second):
		t.Fatal("second segment did not start")
	}
	c.cancelPlaybackPrefetch(session)
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("promotion did not stop second segment")
	}
	for i := 0; i < 2; i++ {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		result := <-results
		if result["url"] != plan["url"] {
			t.Fatal("prefetch changed the playback session")
		}
	}
	_, playlist := prefetchRead(t, origin.Client(), plan["url"].(string), "GET", "")
	for _, line := range strings.Split(string(playlist), "\n") {
		if strings.HasPrefix(line, "http") {
			_, data := prefetchRead(t, origin.Client(), line, "GET", "")
			if string(data) != "cached first segment" {
				t.Fatal("completed prefix lost on promotion")
			}
			break
		}
	}
	if calls.Load() != 2 {
		t.Fatal("shared warmup or completed prefix was fetched twice")
	}
}

func TestMediaPrefetchDeadlineAndTLSFallback(t *testing.T) {
	t.Run("deadline", func(t *testing.T) {
		stopped := make(chan struct{})
		proxy, _ := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done(); close(stopped) })
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		defer cancel()
		stats := proxy.prefetch(ctx, 0, 100)
		if stats.cached != 0 || stats.millis > 2000 {
			t.Fatal("warmup did not respect its deadline")
		}
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
			t.Fatal("deadline left network work running")
		}
	})
	t.Run("TLS fallback", func(t *testing.T) {
		foreign := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("fallback escaped media origin") }))
		defer foreign.Close()
		origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/redirect.mp4" {
				http.Redirect(w, r, foreign.URL+"/video.mp4", 302)
				return
			}
			w.Write([]byte("media prefix"))
		}))
		defer origin.Close()
		base := http.DefaultTransport.(*http.Transport).Clone()
		base.Proxy = nil
		defer base.CloseIdleConnections()
		d := &Downloader{client: &http.Client{Transport: base}}
		for _, address := range []string{origin.URL + "/fixture.mp4", origin.URL + "/redirect.mp4"} {
			proxy, err := d.newHLSProxy(context.Background(), providerMedia{URL: address, certificateFallback: true}, nil)
			if err != nil {
				t.Fatal(err)
			}
			stats := proxy.prefetch(context.Background(), 0, 100)
			proxy.Close()
			if strings.Contains(address, "fixture") && stats.cached != 12 || strings.Contains(address, "redirect") && stats.cached != 0 {
				t.Fatalf("TLS scope or fallback changed: %+v", stats)
			}
		}
		if base.TLSClientConfig != nil && base.TLSClientConfig.InsecureSkipVerify {
			t.Fatal("shared TLS verification was disabled")
		}
	})
}

func TestMediaPrefetchLastModifiedContinuation(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), 100)
	var calls atomic.Int32
	modified, _ := http.ParseTime("Wed, 01 Jan 2025 00:00:00 GMT")
	proxy, client := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 2 && r.Header.Get("If-Range") != modified.Format(http.TimeFormat) {
			t.Error("continuation lost Last-Modified validator")
		}
		http.ServeContent(w, r, "media", modified, bytes.NewReader(payload))
	})
	if stats := proxy.prefetch(context.Background(), 0, 16); stats.cached != 16 {
		t.Fatal("valid Last-Modified prefix discarded")
	}
	_, data := prefetchRead(t, client, proxy.root, "GET", "")
	if !bytes.Equal(data, payload) || calls.Load() != 2 {
		t.Fatal("Last-Modified continuation failed")
	}
}

func TestMediaPrefetchHLSRequestBudget(t *testing.T) {
	var calls atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.Write([]byte("fixture key")) }))
	defer origin.Close()
	playlist := "#EXTM3U\n"
	for i := 0; i < 20; i++ {
		playlist += fmt.Sprintf("#EXT-X-KEY:METHOD=AES-128,URI=\"key%d\"\n", i)
	}
	playlist += "#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"
	d := &Downloader{client: origin.Client()}
	proxy, err := d.newHLSProxy(context.Background(), providerMedia{URL: origin.URL + "/index.m3u8", Playlist: playlist}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	stats := proxy.prefetch(context.Background(), 0, 4096)
	if calls.Load() != mediaPrefetchRequests || stats.requests != mediaPrefetchRequests {
		t.Fatalf("unbounded HLS requests: %+v", stats)
	}
}
