package app

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type huangguoLine struct {
	URL  string `json:"url"`
	Host string `json:"host"`
}

// The picker only offers origins published by the existing official discovery
// path. Public DNS validation remains in the shared transport for every read.
func normalizeHuangguoLine(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || !validImageURL(u) || u.RawQuery != "" || u.Fragment != "" || u.Path != "" && u.Path != "/" {
		return "", false
	}
	return "https://" + strings.ToLower(u.Host), true
}

func (d *Downloader) restoreHuangguoLine() {
	file, err := os.Open(filepath.Join(d.cfg.dataDirectory(), "huangguo-line.json"))
	if err != nil {
		return
	}
	defer file.Close()
	var saved struct {
		Version int    `json:"version"`
		URL     string `json:"url"`
	}
	raw, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil || len(raw) > 4096 || json.Unmarshal(raw, &saved) != nil || saved.Version != 1 {
		return
	}
	if origin, ok := normalizeHuangguoLine(saved.URL); ok {
		d.huangguoLine = origin
		parsed, _ := url.Parse(origin)
		huangguoAIDiscoveredHosts.Store(parsed.Hostname(), true)
	}
}

func (d *Downloader) huangguoLines(ctx context.Context, refresh bool) map[string]any {
	warning := ""
	if refresh {
		work, cancel := context.WithTimeout(ctx, 8*time.Second)
		if len(d.discoverHuangguoAIRoutes(work, true)) == 0 {
			warning = "线路列表暂时无法更新，已保留现有线路"
		}
		cancel()
	}
	d.providerMu.Lock()
	selected, active := d.huangguoLine, d.providerHosts[sourceHuangguoAI]
	routes := append([]string(nil), d.huangguoAIRoutes...)
	d.providerMu.Unlock()
	if selected != "" {
		routes = append(routes, selected)
	}
	items := make([]huangguoLine, 0, len(routes))
	seen := map[string]bool{}
	for _, route := range routes {
		origin, ok := normalizeHuangguoLine(route)
		if !ok || seen[origin] || len(items) >= 12 {
			continue
		}
		seen[origin] = true
		parsed, _ := url.Parse(origin)
		items = append(items, huangguoLine{URL: origin, Host: parsed.Hostname()})
	}
	return map[string]any{"items": items, "selected": selected, "active": active, "warning": warning}
}

func (d *Downloader) knownHuangguoLine(raw string) (string, bool) {
	origin, ok := normalizeHuangguoLine(raw)
	if !ok {
		return "", false
	}
	d.providerMu.Lock()
	defer d.providerMu.Unlock()
	if origin == d.huangguoLine {
		return origin, true
	}
	for _, route := range d.huangguoAIRoutes {
		if candidate, valid := normalizeHuangguoLine(route); valid && candidate == origin {
			return origin, true
		}
	}
	return "", false
}

func (d *Downloader) selectHuangguoLine(ctx context.Context, raw string) (map[string]any, error) {
	d.huangguoLineMu.Lock()
	defer d.huangguoLineMu.Unlock()
	selected := ""
	if raw != "" {
		var ok bool
		selected, ok = d.knownHuangguoLine(raw)
		if !ok {
			return nil, errors.New("请先刷新并选择官方发布的黄果线路")
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// Commit the small preference before changing the live selection. A failed
	// write cannot silently switch the user's source for the current session.
	file, err := os.CreateTemp(d.cfg.dataDirectory(), ".huangguo-line-*.tmp")
	if err != nil {
		return nil, errors.New("黄果线路设置保存失败，请重试")
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(map[string]any{"version": 1, "url": selected})
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = ctx.Err()
	}
	if err == nil {
		err = os.Rename(file.Name(), filepath.Join(d.cfg.dataDirectory(), "huangguo-line.json"))
	}
	if err != nil {
		return nil, errors.New("黄果线路设置保存失败，请重试")
	}
	d.providerMu.Lock()
	d.huangguoLine = selected
	d.huangguoLineRevision++
	d.huangguoAIUnsupported, d.huangguoAIUnsupportedUntil = "", time.Time{}
	d.providerMu.Unlock()
	return d.huangguoLines(ctx, false), nil
}

func (d *Downloader) probeHuangguoLine(ctx context.Context, raw string) (map[string]any, error) {
	origin, ok := d.knownHuangguoLine(raw)
	if !ok {
		return nil, errors.New("请先刷新并选择官方发布的黄果线路")
	}
	started := time.Now()
	reply, err := d.requestHuangguoAPI(ctx, origin, "/api/videos?page=1&size=1", true)
	if err == nil {
		_, _, err = parseHuangguoAPIPage(reply.data, origin, "", 1)
	}
	failure := diagnosticFailure(err)
	if err != nil && (failure == "other" || errors.Is(err, errHuangguoAPIUnavailable)) {
		failure = "invalid_data"
	}
	parsed, _ := url.Parse(origin)
	return map[string]any{"host": parsed.Hostname(), "httpStatus": reply.status, "apiValid": err == nil, "elapsedMs": time.Since(started).Milliseconds(), "failure": failure, "mediaChecked": false}, nil
}
