package app

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// HGhub's fixed official publisher is independent of the main landing domain.
// Read its data, never execute scripts or follow a publisher to another origin.
const huangguoAIPublishURL = "https://huangguoai.pages.dev/"

// The official landing page also advertises this independent address entry.
// It publishes current content routes; it is never itself a playback origin.
const huangguoAIFallbackEntryURL = "https://hgai15.com/"

var huangguoPublishScript = regexp.MustCompile(`(?is)<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']`)
var huangguoPublishArray = regexp.MustCompile(`(?s)\bvar\s+(urls|subdomains)\s*=\s*\[([^\]]*)\]`)
var huangguoPublishString = regexp.MustCompile(`["']([a-zA-Z0-9./-]{1,253})["']`)

func parseHuangguoPublishRoutes(script string) []string {
	arrays := map[string][]string{}
	for _, match := range huangguoPublishArray.FindAllStringSubmatch(script, -1) {
		if len(match[2]) > 16384 {
			return nil
		}
		if _, duplicate := arrays[match[1]]; duplicate {
			return nil
		}
		var values []string
		for _, line := range strings.Split(match[2], "\n") {
			// Domain strings contain no URL schemes; comments are not route data.
			line, _, _ = strings.Cut(line, "//")
			for _, value := range huangguoPublishString.FindAllStringSubmatch(line, -1) {
				values = append(values, value[1])
			}
		}
		arrays[match[1]] = values
	}
	subs := arrays["subdomains"]
	if len(subs) == 0 {
		subs = []string{""}
	}
	var routes []string
	seen := map[string]bool{}
	for _, domain := range arrays["urls"] {
		domain = strings.TrimSuffix(domain, "/")
		if strings.ContainsAny(domain, "/:") {
			continue
		}
		for _, sub := range subs {
			host := domain
			if sub != "" {
				if strings.ContainsAny(sub, "/.:") {
					continue
				}
				host = sub + "." + domain
			}
			origin, host, ok := huangguoAIContentOrigin("https://" + host)
			if !ok || seen[origin] {
				continue
			}
			seen[origin] = true
			huangguoAIDiscoveredHosts.Store(host, true)
			routes = append(routes, origin)
			if len(routes) == 60 {
				return routes
			}
		}
	}
	return routes
}

func (d *Downloader) discoverHuangguoPublisher(ctx context.Context) []string {
	work, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	read := func(address string) (string, error) {
		requestCtx := context.WithValue(work, coverRequestKey{}, true)
		requestCtx = context.WithValue(requestCtx, coverSourceKey{}, sourceHuangguoAI)
		req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, address, nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("User-Agent", userAgent)
		req.Header.Set("Referer", address)
		client := *d.client
		client.Jar = nil
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
		response, err := d.doPreparedCatalogRequestWithClient(req, 3*time.Second, nil, &client)
		if err != nil {
			return "", err
		}
		defer response.Body.Close()
		raw, err := io.ReadAll(io.LimitReader(response.Body, 256*1024+1))
		if err != nil || len(raw) > 256*1024 || response.StatusCode != 200 || catalogResponseBlockReason(response, raw) != "" {
			return "", errors.New("黄果发布页暂时不可用")
		}
		return string(bytes.TrimSpace(raw)), nil
	}
	// Try the published HTML entry before the script-only publisher, so a slow
	// or blocked pages.dev connection cannot consume the entire discovery budget.
	if raw, err := read(huangguoAIFallbackEntryURL); err == nil && work.Err() == nil {
		if routes := parseHuangguoAIRoutes(raw); len(routes) > 0 {
			return routes
		}
	}
	if work.Err() != nil {
		return nil
	}
	html, err := read(huangguoAIPublishURL)
	if err != nil {
		return nil
	}
	base, _ := url.Parse(huangguoAIPublishURL)
	script := base.ResolveReference(&url.URL{Path: "publish.js"})
	for _, match := range huangguoPublishScript.FindAllStringSubmatch(html, -1) {
		candidate, err := url.Parse(match[1])
		if err != nil {
			continue
		}
		candidate = base.ResolveReference(candidate)
		if candidate.Scheme == "https" && candidate.Host == base.Host && candidate.User == nil && candidate.Fragment == "" && strings.HasSuffix(candidate.Path, ".js") {
			script = candidate
			break
		}
	}
	raw, err := read(script.String())
	if err != nil || work.Err() != nil {
		return nil
	}
	return parseHuangguoPublishRoutes(raw)
}
