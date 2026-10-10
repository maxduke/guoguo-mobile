package app

import (
	"bytes"
	"container/list"
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

const mediaSegmentCacheBytes = 32 << 20
const mediaSegmentObjectBytes = 8 << 20
const mediaSegmentCacheObjects = 128
const mediaSegmentPending = 4

// Only an ended media playlist establishes immutable objects. Byte-range
// playlists and master playlists do not establish full segment identities.
func immutableHLSPlaylist(raw string) bool {
	ended, media := false, false
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "#EXT-X-ENDLIST" {
			ended = true
		}
		if strings.HasPrefix(line, "#EXTINF:") {
			media = true
		}
		if strings.HasPrefix(line, "#EXT-X-STREAM-INF:") || strings.HasPrefix(line, "#EXT-X-MEDIA:") || strings.HasPrefix(line, "#EXT-X-I-FRAME-STREAM-INF:") || strings.HasPrefix(line, "#EXT-X-BYTERANGE:") || strings.Contains(line, "BYTERANGE=") {
			return false
		}
	}
	return ended && media
}

func mediaNoStore(header http.Header) bool {
	for _, value := range header.Values("Cache-Control") {
		for _, directive := range strings.Split(value, ",") {
			name, _, _ := strings.Cut(strings.TrimSpace(directive), "=")
			if strings.EqualFold(name, "no-store") {
				return true
			}
		}
	}
	return false
}

type mediaCacheStats struct {
	Hits, Misses, Bytes int64
}

type mediaSegmentCache struct {
	mu       sync.Mutex
	closed   bool
	entries  map[string]*mediaSegmentJob
	flights  map[string]*mediaSegmentJob
	lru      list.List
	reserved int64
	stats    mediaCacheStats
}

type mediaSegmentJob struct {
	key           string
	ctx           context.Context
	cancel        context.CancelFunc
	ready         chan struct{}
	changed       chan struct{}
	header        http.Header
	response      *http.Response // Uncacheable response is handed to one subscriber.
	releaseSlot   func()
	acquireFailed bool
	data          []byte
	size          int64
	users         int
	done          bool
	err           error
	cached        *list.Element
}

func newMediaSegmentCache() *mediaSegmentCache {
	return &mediaSegmentCache{entries: make(map[string]*mediaSegmentJob), flights: make(map[string]*mediaSegmentJob)}
}

// Hits count requests reusing a completed object or joining an in-flight full
// segment. Misses count eligible full GETs without such reuse (including budget
// fallbacks). Bytes is the size of completed retained objects, not reservations.
func (proxy *hlsProxy) cacheStats() mediaCacheStats {
	proxy.mu.Lock()
	cache := proxy.segmentCache
	proxy.mu.Unlock()
	if cache == nil {
		return mediaCacheStats{}
	}
	cache.mu.Lock()
	defer cache.mu.Unlock()
	return cache.stats
}

func (cache *mediaSegmentCache) close() {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	cache.closed = true
	for _, job := range cache.flights {
		job.cancel()
	}
	for _, job := range cache.entries {
		job.cached = nil
		job.cancel()
		if job.users == 0 {
			cache.reserved -= job.size
			job.size = 0
			job.data = nil
		}
	}
	clear(cache.entries)
	cache.lru.Init()
	cache.stats.Bytes = 0
}

// Pin active readers: eviction never moves their bytes outside the budget.
func (cache *mediaSegmentCache) reserve(size int64) bool {
	for cache.reserved+size > mediaSegmentCacheBytes || cache.lru.Len()+len(cache.flights) > mediaSegmentCacheObjects {
		var victim *mediaSegmentJob
		for item := cache.lru.Back(); item != nil; item = item.Prev() {
			job := item.Value.(*mediaSegmentJob)
			if job.users == 0 {
				victim = job
				break
			}
		}
		if victim == nil {
			return false
		}
		delete(cache.entries, victim.key)
		cache.lru.Remove(victim.cached)
		victim.cached = nil
		cache.reserved -= victim.size
		cache.stats.Bytes -= int64(len(victim.data))
		victim.size, victim.data = 0, nil
	}
	cache.reserved += size
	return true
}

func (cache *mediaSegmentCache) release(job *mediaSegmentJob) {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	job.users--
	if job.users != 0 {
		return
	}
	if !job.done {
		job.cancel()
		// Keep canceled work in flights until its worker exits: pending work
		// remains bounded even when clients repeatedly cancel and reconnect.
	}
	if job.done && job.cached == nil {
		cache.reserved -= job.size
		job.size, job.data = 0, nil
		if job.response != nil {
			job.response.Body.Close()
			job.response = nil
		}
		if job.releaseSlot != nil {
			job.releaseSlot()
			job.releaseSlot = nil
		}
		job.cancel()
	}
}

func (proxy *hlsProxy) serveSegmentCache(writer http.ResponseWriter, request *http.Request, asset hlsAsset) (bool, *http.Response, context.Context, func()) {
	if !asset.immutable || asset.playlist || len(asset.body) != 0 || mediaNoStore(request.Header) {
		return false, nil, nil, nil
	}
	proxy.mu.Lock()
	cache := proxy.segmentCache
	proxy.mu.Unlock()
	if cache == nil {
		return false, nil, nil, nil
	}
	key := request.URL.Path
	cache.mu.Lock()
	if cache.closed {
		cache.mu.Unlock()
		return false, nil, nil, nil
	}
	job := cache.entries[key]
	completed := job != nil
	fullGET := request.Method == http.MethodGet && request.Header.Get("Range") == "" && request.Header.Get("If-Range") == ""
	if !completed && !fullGET {
		cache.mu.Unlock()
		return false, nil, nil, nil
	}
	if completed {
		cache.lru.MoveToFront(job.cached)
	} else {
		job = cache.flights[key]
		if job != nil && job.ctx.Err() != nil {
			cache.mu.Unlock()
			return false, nil, nil, nil
		}
	}
	if job != nil {
		cache.stats.Hits++
	} else {
		cache.stats.Misses++
		if len(cache.flights) >= mediaSegmentPending {
			cache.mu.Unlock()
			return false, nil, nil, nil
		}
		ctx := proxy.ctx
		if ctx == nil {
			ctx = context.Background()
		}
		ctx, cancel := context.WithCancel(ctx)
		job = &mediaSegmentJob{key: key, ctx: ctx, cancel: cancel, ready: make(chan struct{}), changed: make(chan struct{})}
		cache.flights[key] = job
		go proxy.fetchSegment(cache, job, asset)
	}
	job.users++
	cache.mu.Unlock()
	handedOff := false
	defer func() {
		if !handedOff {
			cache.release(job)
		}
	}()
	select {
	case <-request.Context().Done():
		return true, nil, nil, nil
	case <-job.ready:
	}
	cache.mu.Lock()
	header, err, acquireFailed := job.header, job.err, job.acquireFailed
	passthrough := job.response
	job.response = nil
	sized := job.size > 0
	cache.mu.Unlock()
	if passthrough != nil {
		handedOff = true
		stop := context.AfterFunc(request.Context(), job.cancel)
		return false, passthrough, job.ctx, func() {
			stop()
			cache.release(job)
		}
	}
	if !sized {
		if err != nil {
			if acquireFailed {
				http.Error(writer, "媒体连接正在等待资源，请稍后重试", http.StatusServiceUnavailable)
				return true, nil, nil, nil
			}
			proxy.fail(writer, request, err)
			return true, nil, nil, nil
		}
		return false, nil, nil, nil
	}
	copySegmentHeaders(writer.Header(), header, asset)
	if completed {
		modified, _ := http.ParseTime(header.Get("Last-Modified"))
		http.ServeContent(writer, request, "media", modified, bytes.NewReader(job.data))
		return true, nil, nil, nil
	}
	writer.WriteHeader(http.StatusOK)
	reader := &mediaSegmentReader{cache: cache, job: job, ctx: request.Context()}
	if _, err := io.Copy(writer, reader); err != nil && request.Context().Err() == nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
		proxy.recordError(err)
	}
	return true, nil, nil, nil
}

func copySegmentHeaders(destination, source http.Header, asset hlsAsset) {
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Content-Encoding", "ETag", "Last-Modified"} {
		if value := source.Get(name); value != "" {
			destination.Set(name, value)
		}
	}
	if contentType := hlsAssetContentType(asset.extension); contentType != "" {
		destination.Set("Content-Type", contentType)
	}
}

// The URL was validated when the asset was registered.
func mustMediaRequest(proxy *hlsProxy, ctx context.Context, address string) *http.Request {
	request, _ := proxy.mediaRequest(ctx, http.MethodGet, address)
	return request
}

func cacheableSegmentResponse(response *http.Response) bool {
	contentType := strings.TrimSpace(strings.SplitN(strings.ToLower(response.Header.Get("Content-Type")), ";", 2)[0])
	// A CDN challenge or API error can be a complete 200 response. Retaining it
	// would make a retry fail locally even after the upstream recovers.
	nonMedia := contentType == "text/html" || contentType == "application/json" || contentType == "application/xml" || contentType == "text/xml" || contentType == "text/javascript" || contentType == "application/javascript" || strings.HasSuffix(contentType, "+json") || strings.HasSuffix(contentType, "+xml")
	if response.StatusCode != http.StatusOK || response.ContentLength <= 0 || response.ContentLength > mediaSegmentObjectBytes || !identityMediaResponse(response) || response.Header.Get("Content-Range") != "" || mediaNoStore(response.Header) || response.Header.Get("Vary") != "" || strings.Contains(contentType, "mpegurl") || nonMedia {
		return false
	}
	if value := response.Header.Get("Content-Length"); value != "" {
		length, err := strconv.ParseInt(value, 10, 64)
		if err != nil || length != response.ContentLength {
			return false
		}
	}
	headerBytes := 0
	for key, values := range response.Header {
		headerBytes += len(key)
		for _, value := range values {
			headerBytes += len(value)
		}
	}
	return headerBytes <= 8192
}

func (proxy *hlsProxy) fetchSegment(cache *mediaSegmentCache, job *mediaSegmentJob, asset hlsAsset) {
	var release func()
	var response *http.Response
	var err error
	if proxy.acquire != nil {
		release, err = proxy.acquire(job.ctx)
		job.acquireFailed = err != nil
	}
	if err == nil {
		response, err = proxy.fetch(mustMediaRequest(proxy, job.ctx, asset.remote))
	}
	// Admission happens after headers. Unknown-sized and oversized bodies stay
	// streaming responses, with no additional request or buffer for the owner.
	cache.mu.Lock()
	accepted := err == nil && !cache.closed && job.ctx.Err() == nil && cacheableSegmentResponse(response) && cache.reserve(response.ContentLength)
	if accepted {
		job.size, job.header = response.ContentLength, response.Header.Clone()
		job.data = make([]byte, 0, int(job.size))
	} else {
		job.response, job.err, job.done = response, err, true
		job.releaseSlot, release = release, nil
		delete(cache.flights, job.key)
	}
	close(job.ready)
	if !accepted && job.users == 0 {
		if response != nil {
			response.Body.Close()
			job.response = nil
		}
		if job.releaseSlot != nil {
			job.releaseSlot()
			job.releaseSlot = nil
		}
		job.cancel()
	}
	cache.mu.Unlock()
	if !accepted {
		if release != nil {
			release()
		}
		return
	}
	if release != nil {
		defer release()
	}
	reader := proxy.mediaReader(mustMediaRequest(proxy, job.ctx, asset.remote), response)
	defer reader.Close()
	defer job.cancel()
	buffer := make([]byte, 32<<10)
	for {
		n, readErr := reader.Read(buffer)
		validEnd := false
		if errors.Is(readErr, io.EOF) {
			// mediaReader stops at the declared size. Confirm that the final
			// upstream body really ended there before retaining a full object.
			var extra [1]byte
			count, endErr := reader.body.Read(extra[:])
			validEnd = count == 0 && errors.Is(endErr, io.EOF)
		}
		cache.mu.Lock()
		if n > 0 {
			job.data = append(job.data, buffer[:n]...)
			close(job.changed)
			job.changed = make(chan struct{})
		}
		if readErr != nil {
			job.done = true
			delete(cache.flights, job.key)
			if validEnd && int64(len(job.data)) == job.size && job.ctx.Err() == nil && !cache.closed {
				job.cached = cache.lru.PushFront(job)
				cache.entries[job.key] = job
				cache.stats.Bytes += int64(len(job.data))
			} else if !errors.Is(readErr, io.EOF) {
				job.err = readErr
			}
			close(job.changed)
			if job.users == 0 && job.cached == nil {
				cache.reserved -= job.size
				job.size, job.data = 0, nil
			}
			cache.mu.Unlock()
			return
		}
		cache.mu.Unlock()
	}
}

type mediaSegmentReader struct {
	cache  *mediaSegmentCache
	job    *mediaSegmentJob
	ctx    context.Context
	offset int
}

func (reader *mediaSegmentReader) Read(buffer []byte) (int, error) {
	for {
		if err := reader.ctx.Err(); err != nil {
			return 0, err
		}
		reader.cache.mu.Lock()
		job := reader.job
		if reader.cache.closed {
			reader.cache.mu.Unlock()
			return 0, context.Canceled
		}
		if err := job.ctx.Err(); err != nil && !job.done {
			reader.cache.mu.Unlock()
			return 0, err
		}
		if reader.offset < len(job.data) {
			n := copy(buffer, job.data[reader.offset:])
			reader.offset += n
			reader.cache.mu.Unlock()
			return n, nil
		}
		if job.done {
			err := job.err
			reader.cache.mu.Unlock()
			if err == nil {
				err = io.EOF
			}
			return 0, err
		}
		changed := job.changed
		reader.cache.mu.Unlock()
		select {
		case <-reader.ctx.Done():
			return 0, reader.ctx.Err()
		case <-job.ctx.Done():
			// A completed worker cancels its context to release resources.
			// Recheck completion under the lock before consuming the result.
			continue
		case <-changed:
		}
	}
}
