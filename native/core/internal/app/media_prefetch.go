package app

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const mediaPrefetchBytes = 4 << 20
const mediaPrefetchRequests = 8
const mediaPrefetchTimeout = 6 * time.Second

type prefetchedMedia struct {
	data      []byte
	remote    string
	header    http.Header
	total     int64
	playlist  bool
	validator string
}
type mediaPrefetchStats struct {
	cached, read int64
	requests     int
	millis       int64
}

// Warm only this playback session. Memory, requests, depth and time are bounded;
// failures leave ordinary playback available and never publish incomplete HLS.
func (proxy *hlsProxy) prefetch(ctx context.Context, quality int, budget int64) mediaPrefetchStats {
	proxy.prefetchMu.Lock()
	defer proxy.prefetchMu.Unlock()
	if proxy.prefetchRun {
		return proxy.prefetchStats
	}
	proxy.prefetchRun = true
	started := time.Now()
	stats := mediaPrefetchStats{}
	remaining := min(budget, int64(mediaPrefetchBytes))
	client := *proxy.client
	redirect := client.CheckRedirect
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if stats.requests >= mediaPrefetchRequests {
			return fmt.Errorf("媒体预取重定向请求已达上限")
		}
		stats.requests++
		if redirect != nil {
			return redirect(request, via)
		}
		return nil
	}
	visited := map[string]bool{}
	var warm func(string, int) bool
	warm = func(local string, depth int) bool {
		if ctx.Err() != nil || remaining <= 0 || stats.requests >= mediaPrefetchRequests || depth > 2 || visited[local] {
			return false
		}
		visited[local] = true
		parsed, err := url.Parse(local)
		if err != nil || !strings.HasPrefix(local, proxy.base) {
			return false
		}
		proxy.mu.Lock()
		asset, exists := proxy.assets[parsed.Path]
		closed := proxy.closed
		proxy.mu.Unlock()
		if !exists || closed {
			return false
		}
		body, remote, playlist := asset.body, asset.remote, asset.playlist
		if len(body) == 0 {
			request, err := proxy.mediaRequest(ctx, http.MethodGet, remote)
			if err != nil {
				return false
			}
			if !playlist {
				request.Header.Set("Range", fmt.Sprintf("bytes=0-%d", remaining-1))
			}
			if proxy.credentials != nil {
				if err := proxy.credentials.apply(request); err != nil {
					return false
				}
			}
			stats.requests++
			response, err := client.Do(request)
			if err != nil {
				return false
			}
			if (response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent) || !identityMediaResponse(response) {
				response.Body.Close()
				return false
			}
			limit := remaining
			data, readErr := io.ReadAll(io.LimitReader(response.Body, limit))
			response.Body.Close()
			remaining -= int64(len(data))
			stats.read += int64(len(data))
			if readErr != nil || len(data) == 0 || ctx.Err() != nil {
				return false
			}
			total := response.ContentLength
			if response.StatusCode == http.StatusPartialContent {
				span, valid := parseMediaByteRange(response.Header.Get("Content-Range"))
				if !valid || span.start != 0 || span.end+1 != int64(len(data)) || response.ContentLength >= 0 && response.ContentLength != int64(len(data)) {
					return false
				}
				total = span.total
			} else {
				if response.Header.Get("Content-Range") != "" {
					return false
				}
				if total < 0 {
					// A read reaching its limit does not prove EOF for chunked responses.
					if int64(len(data)) == limit {
						return false
					}
					total = int64(len(data))
				}
				if total < int64(len(data)) {
					return false
				}
			}
			playlist = playlist || strings.Contains(strings.ToLower(response.Header.Get("Content-Type")), "mpegurl") || bytes.HasPrefix(bytes.TrimSpace(bytes.TrimPrefix(data, []byte("\ufeff"))), []byte("#EXTM3U"))
			validator := mediaPrefetchValidator(response.Header)
			if total > int64(len(data)) && (playlist || validator == "") {
				return false
			}
			if playlist && (!bytes.HasPrefix(bytes.TrimSpace(bytes.TrimPrefix(data, []byte("\ufeff"))), []byte("#EXTM3U")) || !strings.Contains(string(data), "#EXT-X-ENDLIST") && !strings.Contains(string(data), "#EXT-X-STREAM-INF:")) {
				return false
			}
			if response.Request != nil && response.Request.URL != nil {
				remote = response.Request.URL.String()
			}
			cached := prefetchedMedia{data: data, remote: remote, header: response.Header.Clone(), total: total, playlist: playlist, validator: validator}
			proxy.mu.Lock()
			if !proxy.closed && ctx.Err() == nil {
				proxy.prefetched[parsed.Path] = cached
				stats.cached += int64(len(data))
			}
			proxy.mu.Unlock()
			body = data
		}
		if !playlist {
			return true
		}
		if !strings.Contains(string(body), "#EXT-X-ENDLIST") && !strings.Contains(string(body), "#EXT-X-STREAM-INF:") {
			return false
		}
		if strings.Contains(string(body), "#EXT-X-BYTERANGE:") || strings.Contains(string(body), "BYTERANGE=") {
			return true
		}
		rewritten, err := proxy.rewritePlaylist(string(body), remote)
		if err != nil {
			return false
		}
		if strings.Contains(rewritten, "#EXT-X-STREAM-INF:") {
			if variant := prefetchVariant(rewritten, quality); variant != "" {
				return warm(variant, depth+1)
			}
			return true
		}
		segments := 0
		seconds := float64(0)
		for _, raw := range strings.Split(rewritten, "\n") {
			line := strings.TrimSpace(raw)
			if strings.HasPrefix(line, "#EXT-X-KEY:") || strings.HasPrefix(line, "#EXT-X-MAP:") {
				for _, match := range hlsURIAttribute.FindAllStringSubmatch(line, -1) {
					if !warm(match[1], depth+1) {
						return false
					}
				}
			}
			if strings.HasPrefix(line, "#EXTINF:") {
				value := strings.SplitN(strings.TrimPrefix(line, "#EXTINF:"), ",", 2)[0]
				duration, _ := strconv.ParseFloat(value, 64)
				seconds += duration
			}
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if !warm(line, depth+1) {
				break
			}
			segments++
			if segments >= 2 || seconds >= 8 {
				break
			}
		}
		return true
	}
	warm(proxy.root, 0)
	stats.millis = time.Since(started).Milliseconds()
	proxy.prefetchStats = stats
	return stats
}

func mediaPrefetchValidator(header http.Header) string {
	etag := strings.TrimSpace(header.Get("ETag"))
	if len(etag) >= 2 && strings.HasPrefix(etag, `"`) && strings.HasSuffix(etag, `"`) {
		return etag
	}
	modified := strings.TrimSpace(header.Get("Last-Modified"))
	if _, err := http.ParseTime(modified); err == nil {
		return modified
	}
	return ""
}
func prefetchVariant(raw string, quality int) string {
	best, bestHeight, bestBandwidth := "", -1, int64(-1)
	lines := strings.Split(raw, "\n")
	for index, line := range lines {
		if !strings.HasPrefix(strings.TrimSpace(line), "#EXT-X-STREAM-INF:") {
			continue
		}
		height := 0
		if match := reResolution.FindStringSubmatch(line); len(match) == 3 {
			height, _ = strconv.Atoi(match[2])
		}
		if quality > 0 && (height == 0 || height > quality) {
			continue
		}
		bandwidth := int64(0)
		if match := reBandwidth.FindStringSubmatch(line); len(match) == 2 {
			bandwidth, _ = strconv.ParseInt(match[1], 10, 64)
		}
		for _, next := range lines[index+1:] {
			next = strings.TrimSpace(next)
			if next == "" || strings.HasPrefix(next, "#") {
				continue
			}
			if height > bestHeight || height == bestHeight && bandwidth > bestBandwidth {
				best, bestHeight, bestBandwidth = next, height, bandwidth
			}
			break
		}
	}
	return best
}
func (proxy *hlsProxy) mediaRequest(ctx context.Context, method, address string) (*http.Request, error) {
	request, err := http.NewRequestWithContext(ctx, method, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Referer", proxy.referer)
	request.Header.Set("Accept-Encoding", "identity")
	if origin, err := url.Parse(proxy.referer); err == nil && origin.Host != "" {
		request.Header.Set("Origin", origin.Scheme+"://"+origin.Host)
	}
	return request, nil
}

func prefetchRequestedRange(raw string, total int64) (int64, int64, bool) {
	if raw == "" {
		return 0, total - 1, total > 0
	}
	if !strings.HasPrefix(raw, "bytes=") || strings.Contains(raw, ",") {
		return 0, 0, false
	}
	first, last, ok := strings.Cut(strings.TrimPrefix(raw, "bytes="), "-")
	if !ok {
		return 0, 0, false
	}
	start, err := strconv.ParseInt(first, 10, 64)
	if err != nil || start < 0 || start >= total {
		return 0, 0, false
	}
	end := total - 1
	if last != "" {
		end, err = strconv.ParseInt(last, 10, 64)
		if err != nil || end < start {
			return 0, 0, false
		}
		end = min(end, total-1)
	}
	return start, end, true
}

func (proxy *hlsProxy) invalidatePrefetch(path string, cached prefetchedMedia) {
	proxy.mu.Lock()
	if current, exists := proxy.prefetched[path]; exists && len(current.data) > 0 && &current.data[0] == &cached.data[0] {
		delete(proxy.prefetched, path)
	}
	proxy.mu.Unlock()
}

// Validate the continuation before emitting any cached bytes. A changed origin
// object, ignored Range, encoding or validator causes normal upstream fallback.
func (proxy *hlsProxy) servePrefetched(writer http.ResponseWriter, request *http.Request, asset hlsAsset, cached prefetchedMedia) bool {
	if value := request.Header.Get("If-Range"); value != "" && value != cached.validator {
		return false
	}
	if cached.total == int64(len(cached.data)) {
		writer.Header().Set("Content-Type", firstNonEmpty(cached.header.Get("Content-Type"), hlsAssetContentType(asset.extension), "application/octet-stream"))
		if etag := cached.header.Get("ETag"); etag != "" {
			writer.Header().Set("ETag", etag)
		}
		modified, _ := http.ParseTime(cached.header.Get("Last-Modified"))
		reader := &prefetchCountingReader{Reader: bytes.NewReader(cached.data), proxy: proxy}
		http.ServeContent(writer, request, "media", modified, reader)
		return true
	}
	start, end, valid := prefetchRequestedRange(request.Header.Get("Range"), cached.total)
	if !valid || start >= int64(len(cached.data)) {
		return false
	}
	var tail *resumableMediaReader
	if end >= int64(len(cached.data)) && request.Method != http.MethodHead {
		if cached.validator == "" {
			return false
		}
		if proxy.acquire != nil {
			release, err := proxy.acquire(request.Context())
			if err != nil {
				return false
			}
			defer release()
		}
		upstream, err := proxy.mediaRequest(request.Context(), http.MethodGet, cached.remote)
		if err != nil {
			return false
		}
		upstream.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", len(cached.data), end))
		upstream.Header.Set("If-Range", cached.validator)
		response, err := proxy.fetch(upstream)
		if err != nil {
			proxy.invalidatePrefetch(request.URL.Path, cached)
			return false
		}
		span, ok := parseMediaByteRange(response.Header.Get("Content-Range"))
		if response.StatusCode != http.StatusPartialContent || !ok || span.start != int64(len(cached.data)) || span.end != end || span.total != cached.total || response.ContentLength >= 0 && response.ContentLength != end-span.start+1 || !identityMediaResponse(response) || cached.header.Get("ETag") != "" && response.Header.Get("ETag") != cached.header.Get("ETag") || cached.header.Get("Last-Modified") != "" && response.Header.Get("Last-Modified") != cached.header.Get("Last-Modified") {
			response.Body.Close()
			proxy.invalidatePrefetch(request.URL.Path, cached)
			return false
		}
		tail = proxy.mediaReader(upstream, response)
		defer tail.Close()
	}
	for _, header := range []string{"ETag", "Last-Modified"} {
		if value := cached.header.Get(header); value != "" {
			writer.Header().Set(header, value)
		}
	}
	writer.Header().Set("Content-Type", firstNonEmpty(cached.header.Get("Content-Type"), hlsAssetContentType(asset.extension), "application/octet-stream"))
	writer.Header().Set("Accept-Ranges", "bytes")
	writer.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	if request.Header.Get("Range") != "" {
		writer.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, cached.total))
		writer.WriteHeader(http.StatusPartialContent)
	}
	if request.Method == http.MethodHead {
		return true
	}
	prefix := cached.data[start:min(end+1, int64(len(cached.data)))]
	written, err := writer.Write(prefix)
	proxy.reusedBytes.Add(int64(written))
	if err == nil && tail != nil {
		_, err = io.CopyN(writer, tail, end-int64(len(cached.data))+1)
		if err != nil && tail.failure != nil && request.Context().Err() == nil {
			proxy.recordError(tail.failure)
		}
	}
	return true
}

type prefetchCountingReader struct {
	*bytes.Reader
	proxy *hlsProxy
}

func (reader *prefetchCountingReader) Read(buffer []byte) (int, error) {
	n, err := reader.Reader.Read(buffer)
	reader.proxy.reusedBytes.Add(int64(n))
	return n, err
}
