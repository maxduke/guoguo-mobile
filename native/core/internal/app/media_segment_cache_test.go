package app

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func segmentCacheFixture(t *testing.T, playlist string, handler http.HandlerFunc) (*hlsProxy, *http.Client, []string) {
	t.Helper()
	origin := httptest.NewServer(handler)
	t.Cleanup(origin.Close)
	proxy, err := (&Downloader{client: origin.Client(), cfg: Config{Retries: 1}}).newHLSProxy(context.Background(), providerMedia{URL: origin.URL + "/index.m3u8", Playlist: playlist}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(proxy.Close)
	_, rewritten := prefetchRead(t, origin.Client(), proxy.root, "GET", "")
	var assets []string
	for _, line := range strings.Split(string(rewritten), "\n") {
		if strings.HasPrefix(line, "http") {
			assets = append(assets, line)
		}
	}
	for _, match := range hlsURIAttribute.FindAllStringSubmatch(string(rewritten), -1) {
		assets = append(assets, match[1])
	}
	return proxy, origin.Client(), assets
}

func TestSegmentCacheBackwardSeekRangesAndInit(t *testing.T) {
	payload := []byte("complete immutable segment bytes")
	var mu sync.Mutex
	calls := map[string]int{}
	proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"enc.key\"\n#EXTINF:4,\none.ts\n#EXTINF:4,\ntwo.m4s\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls[r.URL.Path]++
		mu.Unlock()
		if r.Header.Get("Accept-Encoding") != "identity" {
			t.Error("missing identity encoding")
		}
		w.Header().Set("ETag", `"segment"`)
		w.Header().Set("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")
		http.ServeContent(w, r, "asset", time.Time{}, bytes.NewReader(payload))
	})
	// Segment bytes (including encrypted payloads) are retained unchanged; keys
	// remain on the normal forwarding path.
	for round := 0; round < 2; round++ {
		for _, address := range assets {
			_, data := prefetchRead(t, client, address, "GET", "")
			if !bytes.Equal(data, payload) {
				t.Fatal("cache changed payload")
			}
		}
	}
	response, data := prefetchRead(t, client, assets[0], "GET", "bytes=-5")
	if response.StatusCode != 206 || !bytes.Equal(data, payload[len(payload)-5:]) || response.Header.Get("ETag") != `"segment"` {
		t.Fatal("cached suffix metadata or bytes changed")
	}
	response, data = prefetchRead(t, client, assets[0], "HEAD", "bytes=1-5")
	if response.StatusCode != 206 || response.ContentLength != 5 || len(data) != 0 {
		t.Fatal("cached HEAD range incorrect")
	}
	request, _ := http.NewRequest("GET", assets[0], nil)
	request.Header.Set("Range", "bytes=0-3")
	request.Header.Set("If-Range", `"changed"`)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	data, err = io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 200 || !bytes.Equal(data, payload) {
		t.Fatal("If-Range mismatch must return complete body")
	}
	mu.Lock()
	defer mu.Unlock()
	for _, name := range []string{"/one.ts", "/two.m4s", "/init.mp4"} {
		if calls[name] != 1 {
			t.Fatalf("backward seek refetched %s: %v", name, calls)
		}
	}
	if calls["/enc.key"] != 2 {
		t.Fatal("key retained in segment cache")
	}
	stats := proxy.cacheStats()
	if stats.Misses != 3 || stats.Hits != 6 || stats.Bytes != int64(3*len(payload)) {
		t.Fatalf("unexpected cache stats: %+v", stats)
	}
}

func TestSegmentCachePlaylistClassification(t *testing.T) {
	for _, raw := range []string{
		"#EXTM3U\n#EXTINF:4,\none.ts\n",
		"#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:4@0\none.ts\n#EXT-X-ENDLIST\n",
		"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\none.ts\n#EXT-X-ENDLIST\n",
		"#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"4@0\"\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n",
		"#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST-FAKE\n",
	} {
		if immutableHLSPlaylist(raw) {
			t.Fatalf("unsafe playlist classified immutable: %q", raw)
		}
	}
	if !immutableHLSPlaylist("#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n") {
		t.Fatal("VOD not recognized")
	}
	// The same URL referenced first by VOD and then by live must have independent
	// cache identities, so a live refresh cannot reuse immutable VOD bytes.
	proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("segment")) })
	_, _ = prefetchRead(t, client, assets[0], "GET", "")
	proxy.mu.Lock()
	var remote string
	for _, asset := range proxy.assets {
		if asset.immutable {
			remote = asset.remote
			break
		}
	}
	proxy.mu.Unlock()
	rewritten, err := proxy.rewritePlaylist("#EXTM3U\n#EXTINF:4,\n"+remote+"\n", remote)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(rewritten, assets[0]) {
		t.Fatal("live and VOD aliases share a cache identity")
	}
}

func TestSegmentCacheUnsafeResponsesStayStreaming(t *testing.T) {
	for _, kind := range []string{"no-store", "encoded", "unknown length", "oversized", "vary", "truncated", "error", "html", "json"} {
		t.Run(kind, func(t *testing.T) {
			var calls atomic.Int32
			payload := []byte("normal segment")
			if kind == "oversized" {
				payload = bytes.Repeat([]byte("x"), mediaSegmentObjectBytes+1)
			}
			proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				switch kind {
				case "no-store":
					w.Header().Set("Cache-Control", "private, NO-STORE")
				case "encoded":
					w.Header().Set("Content-Encoding", "gzip")
				case "unknown length":
					w.(http.Flusher).Flush()
				case "vary":
					w.Header().Set("Vary", "Cookie")
				case "truncated":
					w.Header().Set("Content-Length", "100")
				case "error":
					w.WriteHeader(500)
				case "html":
					w.Header().Set("Content-Type", "text/html; charset=utf-8")
				case "json":
					w.Header().Set("Content-Type", "application/problem+json")
				}
				w.Write(payload)
			})
			for round := 0; round < 2; round++ {
				request, _ := http.NewRequest("GET", assets[0], nil)
				request.Header.Set("Accept-Encoding", "identity")
				response, err := client.Do(request)
				if err != nil {
					t.Fatal(err)
				}
				data, readErr := io.ReadAll(response.Body)
				response.Body.Close()
				if kind == "truncated" {
					if readErr == nil {
						t.Fatal("truncated body reported complete")
					}
				} else if kind != "error" && (readErr != nil || !bytes.Equal(data, payload)) {
					t.Fatalf("streaming fallback changed bytes: %v", readErr)
				}
			}
			if calls.Load() != 2 || proxy.cacheStats().Bytes != 0 {
				t.Fatalf("unsafe response retained: calls=%d stats=%+v", calls.Load(), proxy.cacheStats())
			}
		})
	}
}

func waitSegmentUsers(t *testing.T, proxy *hlsProxy, want int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		proxy.segmentCache.mu.Lock()
		users := 0
		for _, job := range proxy.segmentCache.flights {
			users += job.users
		}
		proxy.segmentCache.mu.Unlock()
		if users >= want {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("concurrent requests did not join shared fetch")
}

func TestSegmentCacheSharesStreamingAndIndependentCancellation(t *testing.T) {
	began, finish, stopped := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	payload := bytes.Repeat([]byte("segment"), 1000)
	proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		w.Write(payload[:7])
		w.(http.Flusher).Flush()
		close(began)
		select {
		case <-finish:
			w.Write(payload[7:])
		case <-r.Context().Done():
			close(stopped)
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	leaderDone := make(chan struct{})
	go func() {
		defer close(leaderDone)
		r, _ := http.NewRequestWithContext(ctx, "GET", assets[0], nil)
		response, err := client.Do(r)
		if err == nil {
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
		}
	}()
	<-began
	followerDone := make(chan error, 1)
	go func() {
		response, err := client.Get(assets[0])
		if err != nil {
			followerDone <- err
			return
		}
		data, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err == nil && !bytes.Equal(data, payload) {
			err = fmt.Errorf("shared segment changed")
		}
		followerDone <- err
	}()
	waitSegmentUsers(t, proxy, 2)
	cancel()
	<-leaderDone
	select {
	case <-stopped:
		t.Fatal("canceling one consumer stopped unrelated consumer")
	default:
	}
	close(finish)
	if err := <-followerDone; err != nil {
		t.Fatal(err)
	}
	_, data := prefetchRead(t, client, assets[0], "GET", "")
	if calls.Load() != 1 || !bytes.Equal(data, payload) || proxy.cacheStats().Bytes != int64(len(payload)) {
		t.Fatal("simultaneous reads did not share a complete cached object")
	}
}

func TestSegmentCacheCancelLastConsumerAndClose(t *testing.T) {
	for _, action := range []string{"cancel", "close"} {
		t.Run(action, func(t *testing.T) {
			began, stopped := make(chan struct{}), make(chan struct{})
			proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Length", "10000")
				w.Write([]byte("prefix"))
				w.(http.Flusher).Flush()
				close(began)
				<-r.Context().Done()
				close(stopped)
			})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan struct{})
			go func() {
				defer close(done)
				request, _ := http.NewRequestWithContext(ctx, "GET", assets[0], nil)
				response, err := client.Do(request)
				if err == nil {
					io.Copy(io.Discard, response.Body)
					response.Body.Close()
				}
			}()
			<-began
			if action == "close" {
				proxy.Close()
			} else {
				cancel()
			}
			select {
			case <-stopped:
			case <-time.After(3 * time.Second):
				t.Fatal("orphan segment fetch survived cancellation")
			}
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("client survived cancellation")
			}
			deadline := time.Now().Add(time.Second)
			for time.Now().Before(deadline) {
				proxy.segmentCache.mu.Lock()
				remaining := proxy.segmentCache.reserved + int64(len(proxy.segmentCache.flights))
				proxy.segmentCache.mu.Unlock()
				if remaining == 0 {
					break
				}
				time.Sleep(time.Millisecond)
			}
			proxy.segmentCache.mu.Lock()
			defer proxy.segmentCache.mu.Unlock()
			if proxy.segmentCache.reserved != 0 || len(proxy.segmentCache.flights) != 0 || proxy.segmentCache.stats.Bytes != 0 {
				t.Fatal("canceled fetch retained buffers or work")
			}
		})
	}
}

func TestSegmentCacheLRUBudgetAndPinnedReaders(t *testing.T) {
	cache := newMediaSegmentCache()
	cache.mu.Lock()
	defer cache.mu.Unlock()
	for index := 0; index < 4; index++ {
		if !cache.reserve(mediaSegmentObjectBytes) {
			t.Fatal("could not fill budget")
		}
		key := fmt.Sprint(index)
		job := &mediaSegmentJob{key: key, size: mediaSegmentObjectBytes, data: make([]byte, mediaSegmentObjectBytes), done: true, users: 1}
		job.cached = cache.lru.PushFront(job)
		cache.entries[key] = job
		cache.stats.Bytes += int64(len(job.data))
	}
	if cache.reserve(1) {
		t.Fatal("evicted active reader outside memory budget")
	}
	cache.entries["0"].users = 0
	if !cache.reserve(mediaSegmentObjectBytes) || cache.entries["0"] != nil || cache.reserved != mediaSegmentCacheBytes {
		t.Fatal("LRU did not evict oldest unpinned object")
	}
}

func TestSegmentCacheRangeMissAndDirectMP4DoNotPopulate(t *testing.T) {
	var calls atomic.Int32
	payload := []byte("0123456789abcdef")
	proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		http.ServeContent(w, r, "media", time.Time{}, bytes.NewReader(payload))
	})
	for round := 0; round < 2; round++ {
		_, data := prefetchRead(t, client, assets[0], "GET", "bytes=2-6")
		if !bytes.Equal(data, payload[2:7]) {
			t.Fatal("uncached range corrupted")
		}
	}
	if calls.Load() != 2 || proxy.cacheStats().Bytes != 0 || proxy.cacheStats().Misses != 0 {
		t.Fatal("partial response was retained as a complete segment")
	}
	direct, directClient := mediaProxyFixture(t, func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "mp4", time.Time{}, bytes.NewReader(payload))
	})
	for round := 0; round < 2; round++ {
		prefetchRead(t, directClient, direct.root, "GET", "")
	}
	if direct.cacheStats() != (mediaCacheStats{}) {
		t.Fatal("arbitrary MP4 entered segment cache")
	}
}

func TestSegmentCacheBoundsPendingBeforeHeaders(t *testing.T) {
	started := make(chan struct{}, mediaSegmentPending)
	var upstreams atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreams.Add(1)
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer origin.Close()
	proxy, err := (&Downloader{client: origin.Client()}).newHLSProxy(context.Background(), providerMedia{URL: origin.URL + "/index.m3u8", Playlist: "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	var clients sync.WaitGroup
	for index := 0; index < mediaSegmentPending; index++ {
		address := proxy.addAsset(hlsAsset{remote: fmt.Sprintf("%s/%d.ts", origin.URL, index), immutable: true})
		clients.Add(1)
		go func() {
			defer clients.Done()
			response, err := origin.Client().Get(address)
			if err == nil {
				response.Body.Close()
			}
		}()
	}
	for index := 0; index < mediaSegmentPending; index++ {
		select {
		case <-started:
		case <-time.After(3 * time.Second):
			t.Fatal("pending fetch did not begin")
		}
	}
	address := proxy.addAsset(hlsAsset{remote: origin.URL + "/excess.ts", immutable: true})
	request := httptest.NewRequest("GET", address, nil)
	handled, response, _, _ := proxy.serveSegmentCache(httptest.NewRecorder(), request, hlsAsset{remote: origin.URL + "/excess.ts", immutable: true})
	if handled || response != nil || upstreams.Load() != mediaSegmentPending {
		t.Fatal("cache started work over pending limit")
	}
	proxy.segmentCache.mu.Lock()
	pending := len(proxy.segmentCache.flights)
	reserved := proxy.segmentCache.reserved
	proxy.segmentCache.mu.Unlock()
	if pending != mediaSegmentPending || reserved != 0 {
		t.Fatal("header stage allocated unbounded buffers")
	}
	proxy.Close()
	clients.Wait()
}

func TestSegmentCacheStreamsBeforeComplete(t *testing.T) {
	first := bytes.Repeat([]byte("a"), 64<<10)
	payload := append(append([]byte{}, first...), bytes.Repeat([]byte("b"), 64<<10)...)
	finish := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(finish) })
	proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		w.Write(first)
		w.(http.Flusher).Flush()
		select {
		case <-finish:
			w.Write(payload[len(first):])
		case <-r.Context().Done():
		}
	})
	prefixRead := make(chan error, 1)
	allRead := make(chan error, 1)
	go func() {
		response, err := client.Get(assets[0])
		if err != nil {
			prefixRead <- err
			allRead <- err
			return
		}
		defer response.Body.Close()
		prefix := make([]byte, len(first))
		_, err = io.ReadFull(response.Body, prefix)
		if err == nil && !bytes.Equal(prefix, first) {
			err = fmt.Errorf("streamed prefix changed")
		}
		prefixRead <- err
		tail, err := io.ReadAll(response.Body)
		if err == nil && !bytes.Equal(tail, payload[len(first):]) {
			err = fmt.Errorf("streamed tail changed")
		}
		allRead <- err
	}()
	select {
	case err := <-prefixRead:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("playback waited for whole segment before streaming")
	}
	if proxy.cacheStats().Bytes != 0 {
		t.Fatal("partial body published as complete")
	}
	once.Do(func() { close(finish) })
	if err := <-allRead; err != nil {
		t.Fatal(err)
	}
	// Client EOF may race the worker's final EOF check; a replay must still join
	// existing work rather than starting a second fetch.
	_, data := prefetchRead(t, client, assets[0], "GET", "")
	if !bytes.Equal(data, payload) {
		t.Fatal("complete replay changed")
	}
}

func TestSegmentCacheResponseAdmissionChecks(t *testing.T) {
	for _, response := range []*http.Response{
		{StatusCode: 200, ContentLength: 8, Header: http.Header{"Content-Length": {"9"}}},
		{StatusCode: 200, ContentLength: 8, Header: http.Header{"Content-Range": {"bytes 0-7/16"}}},
		{StatusCode: 206, ContentLength: 8, Header: make(http.Header)},
		{StatusCode: 200, ContentLength: 8, Header: http.Header{"Content-Type": {"application/vnd.apple.mpegurl"}}},
		{StatusCode: 200, ContentLength: 8, Header: make(http.Header), Uncompressed: true},
	} {
		if cacheableSegmentResponse(response) {
			t.Fatalf("inconsistent/unsafe full object admitted: %+v", response)
		}
	}
}

func TestSegmentCacheRetainsResumptionAndConnectionSlot(t *testing.T) {
	for _, cacheable := range []bool{true, false} {
		t.Run(fmt.Sprint(cacheable), func(t *testing.T) {
			var calls, slots atomic.Int32
			payload := []byte("0123456789abcdef")
			proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
				attempt := calls.Add(1)
				if slots.Load() != 1 {
					t.Errorf("upstream continuation escaped acquisition slot: %d", slots.Load())
				}
				w.Header().Set("ETag", `"segment"`)
				if !cacheable {
					w.Header().Set("Cache-Control", "no-store")
				}
				if attempt == 1 {
					w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
					w.Write(payload[:3])
					return
				}
				http.ServeContent(w, r, "asset", time.Time{}, bytes.NewReader(payload))
			})
			proxy.retries = 3
			proxy.acquire = func(ctx context.Context) (func(), error) { slots.Add(1); return func() { slots.Add(-1) }, nil }
			_, data := prefetchRead(t, client, assets[0], "GET", "")
			if !bytes.Equal(data, payload) || calls.Load() != 2 {
				t.Fatal("cache changed body-resumption behavior")
			}
			_, data = prefetchRead(t, client, assets[0], "GET", "")
			want := int32(2)
			if !cacheable {
				want = 3
			}
			if !bytes.Equal(data, payload) || calls.Load() != want || proxy.Err() != nil {
				t.Fatal("resumed object replay failed")
			}
			if slots.Load() != 0 {
				t.Fatal("acquired connection slot leaked")
			}
		})
	}
}

func TestSegmentCacheRejectsExtraDeclaredBodyBytes(t *testing.T) {
	var calls atomic.Int32
	proxy := &hlsProxy{ctx: context.Background(), segmentCache: newMediaSegmentCache(), assets: make(map[string]hlsAsset), assetIDs: make(map[string]string), base: "http://localhost/media/", client: &http.Client{Transport: rankingTransport(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return &http.Response{StatusCode: 200, ContentLength: 3, Header: http.Header{"Content-Length": {"3"}}, Body: io.NopCloser(strings.NewReader("abcdef")), Request: r}, nil
	})}}
	defer proxy.Close()
	address := proxy.addAsset(hlsAsset{remote: "https://media.example.org/one.ts", immutable: true})
	for round := 0; round < 2; round++ {
		writer := httptest.NewRecorder()
		proxy.ServeHTTP(writer, httptest.NewRequest("GET", address, nil))
		if writer.Body.String() != "abc" {
			t.Fatal("normal declared-length forwarding changed")
		}
	}
	if calls.Load() != 2 || proxy.cacheStats().Bytes != 0 {
		t.Fatal("inconsistent declared body was retained")
	}
}

func TestSegmentCacheSessionIsolation(t *testing.T) {
	var calls atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Write([]byte("segment for " + r.Header.Get("Cookie")))
	}))
	defer origin.Close()
	downloader := &Downloader{client: origin.Client()}
	var proxies []*hlsProxy
	var addresses []string
	for _, cookie := range []string{"grant=one", "grant=two"} {
		proxy, err := downloader.newHLSProxy(context.Background(), providerMedia{URL: origin.URL + "/index.m3u8", Playlist: "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", credentials: &providerMediaCredentials{origin: origin.URL, cookie: cookie}}, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer proxy.Close()
		proxies = append(proxies, proxy)
		_, playlist := prefetchRead(t, origin.Client(), proxy.root, "GET", "")
		for _, line := range strings.Split(string(playlist), "\n") {
			if strings.HasPrefix(line, "http") {
				addresses = append(addresses, line)
			}
		}
	}
	for round := 0; round < 2; round++ {
		for index, address := range addresses {
			_, data := prefetchRead(t, origin.Client(), address, "GET", "")
			want := "segment for grant=one"
			if index == 1 {
				want = "segment for grant=two"
			}
			if string(data) != want {
				t.Fatal("segment cache crossed session credentials")
			}
		}
	}
	if calls.Load() != 2 {
		t.Fatal("isolated sessions did not retain their own objects")
	}
	proxies[0].Close()
	if proxies[0].cacheStats().Bytes != 0 || proxies[1].cacheStats().Bytes == 0 {
		t.Fatal("closing one session did not release only its cache")
	}
}

func TestSegmentCacheNoStorePrefetchCannotBypassPolicy(t *testing.T) {
	var calls atomic.Int32
	proxy, client, assets := segmentCacheFixture(t, "#EXTM3U\n#EXTINF:4,\none.ts\n#EXT-X-ENDLIST\n", func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Cache-Control", "no-store")
		w.Write([]byte("private segment"))
	})
	if stats := proxy.prefetch(context.Background(), 0, 1024); stats.cached != 0 {
		t.Fatal("prefetch retained no-store segment")
	}
	for round := 0; round < 2; round++ {
		prefetchRead(t, client, assets[0], "GET", "")
	}
	if calls.Load() != 3 || proxy.cacheStats().Bytes != 0 {
		t.Fatal("prefetch bypassed no-store playback cache policy")
	}
}
