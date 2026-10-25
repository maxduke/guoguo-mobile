package sourcecheck

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// Media probes keep only safe status fields. Playback URLs, headers, keys and
// provider errors never become report fields. This is not a full decode test.
func probeMedia(ctx context.Context, client Client, source, id string, chapter json.RawMessage) Step {
	started := time.Now()
	step := Step{Operation: "media_sample", Status: "failed"}
	if ctx.Err() != nil {
		step.Status, step.Reason = "skipped", "budget"
		return step
	}
	work, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	request, _ := json.Marshal(map[string]any{"method": "resolve", "source": source, "id": id, "chapter": chapter, "timeoutMs": 12000})
	raw, err := client.Call(string(request))
	var media struct {
		URL, Session string
		Headers      map[string]string
		HLS          bool
	}
	if err != nil || json.Unmarshal([]byte(raw), &media) != nil || media.URL == "" {
		step.Reason, step.ElapsedMS = "resolve_failed", time.Since(started).Milliseconds()
		return step
	}
	if media.Session != "" {
		defer func() {
			request, _ := json.Marshal(map[string]any{"method": "release", "id": media.Session, "timeoutMs": 1000})
			_, _ = client.Call(string(request))
		}()
	}
	step = probeMediaURL(work, &http.Client{Timeout: 12 * time.Second}, media.URL, media.Headers, media.HLS, false, 0)
	step.Operation, step.ElapsedMS = "media_sample", time.Since(started).Milliseconds()
	if step.Status == "passed" {
		step.Items = 1
	}
	return step
}

var mediaKeyURI = regexp.MustCompile(`URI="([^"]+)"`)

func probeMediaURL(ctx context.Context, client *http.Client, address string, headers map[string]string, playlist, encrypted bool, depth int) Step {
	step := Step{Status: "failed", Reason: "media_unavailable"}
	get := func(address string, limit int64) ([]byte, int, error) {
		parsed, err := url.Parse(address)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" || parsed.User != nil {
			return nil, 0, fmt.Errorf("unsupported media")
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
		if err != nil {
			return nil, 0, err
		}
		for key, value := range headers {
			request.Header.Set(key, value)
		}
		request.Header.Set("Range", fmt.Sprintf("bytes=0-%d", limit-1))
		request.Header.Set("Accept-Encoding", "identity")
		response, err := client.Do(request)
		if err != nil {
			return nil, 0, err
		}
		defer response.Body.Close()
		body, err := io.ReadAll(io.LimitReader(response.Body, limit))
		return body, response.StatusCode, err
	}
	limit := int64(1024)
	if playlist || strings.Contains(strings.ToLower(address), ".m3u8") {
		limit = 65536
	}
	body, status, err := get(address, limit)
	step.HTTPStatus, step.MediaBytes = status, len(body)
	if err != nil {
		if ctx.Err() != nil {
			step.Reason = "timeout"
		}
		return step
	}
	if status < 200 || status >= 300 {
		step.Reason = fmt.Sprintf("http_%d", status)
		return step
	}
	text := strings.TrimSpace(string(body))
	if strings.HasPrefix(text, "#EXTM3U") {
		if depth >= 2 {
			step.Status, step.Reason = "partial", "manifest_depth"
			return step
		}
		base, _ := url.Parse(address)
		resolve := func(reference string) string {
			parsed, err := url.Parse(reference)
			if err != nil {
				return ""
			}
			return base.ResolveReference(parsed).String()
		}
		master := false
		for _, line := range strings.Split(text, "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "#EXT-X-STREAM-INF:") {
				master = true
			}
			if strings.HasPrefix(line, "#EXT-X-KEY:") && !strings.Contains(line, "METHOD=NONE") {
				if !strings.Contains(line, "METHOD=AES-128,") {
					step.Status, step.Reason = "partial", "unsupported_key"
					return step
				}
				match := mediaKeyURI.FindStringSubmatch(line)
				if len(match) < 2 {
					step.Reason = "unsupported_key"
					return step
				}
				key, code, err := get(resolve(match[1]), 17)
				if err != nil || code < 200 || code >= 300 || len(key) != 16 {
					step.Reason = "key_unavailable"
					return step
				}
				encrypted = true
			}
			if line != "" && !strings.HasPrefix(line, "#") {
				return probeMediaURL(ctx, client, resolve(line), headers, master, encrypted, depth+1)
			}
		}
		step.Status, step.Reason = "partial", "no_segment_in_sample"
		return step
	}
	lower := strings.ToLower(text)
	if strings.HasPrefix(lower, "<html") || strings.HasPrefix(lower, "<!doctype") || json.Valid(body) || len(body) == 0 {
		step.Reason = "non_media_body"
		return step
	}
	prefix := body[:min(len(body), 64)]
	if bytes.Contains(prefix, []byte("ftyp")) || bytes.Contains(prefix, []byte("moof")) || bytes.Contains(prefix, []byte("styp")) {
		step.MediaKind = "mp4"
	} else if len(body) > 188 && body[0] == 0x47 && body[188] == 0x47 {
		step.MediaKind = "mpegts"
	} else if encrypted {
		step.MediaKind = "encrypted_segment"
	} else {
		step.Status, step.Reason = "partial", "unrecognized_media_prefix"
		return step
	}
	step.Status, step.Reason = "passed", ""
	return step
}
