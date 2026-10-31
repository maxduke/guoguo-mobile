// Playback route and compatibility adaptation of hongguoTV, GPL-3.0-only.
// Pinned sources and local scope: native/core/UPSTREAM.md.
package app

import (
	"net/http"
	"strings"
	"time"
)

const hongguoPlayerMaxAttempts = 4

func (downloader *Downloader) hongguoPlayerRequestAttempts() int {
	if attempts := downloader.cfg.hongguoPlayerAttempts; attempts > 0 {
		return min(attempts, hongguoPlayerMaxAttempts)
	}
	return downloader.hongguoRequestAttempts()
}

func hongguoPlaybackRetryDelay(attempt int) time.Duration {
	return [...]time.Duration{0, 700 * time.Millisecond, 1500 * time.Millisecond, 3 * time.Second}[min(attempt, 3)]
}

func hongguoPlaybackBaseURL(base string, attempt int) string {
	// Only the fixed anonymous playback cluster may change origin. In particular,
	// retain injected endpoints and never apply this policy to signed requests.
	if strings.TrimRight(base, "/") != hongguoAppBaseURL {
		return base
	}
	routes := [...]string{hongguoAppBaseURL, "https://api5-normal-hl.fqnovel.com", "https://api5-normal-lf.fqnovel.com"}
	return routes[attempt%len(routes)]
}

func hongguoFreshPlayerClient(client *http.Client) (*http.Client, func()) {
	base := client.Transport
	if base == nil {
		base = http.DefaultTransport
	}
	for {
		switch transport := base.(type) {
		case *imageTransport:
			base = transport.base
		case *huangguoBrowserTransport:
			base = transport.base
		case *cdnTransport:
			// Player POST requests already bypass CDN routing.
			base = transport.base
		case *http.Transport:
			fresh := transport.Clone()
			fresh.DisableKeepAlives = true
			// Clone's protocol callback map can still reference the old HTTP/2
			// transport. Rebuild it so retries retain HTTP/2 with an isolated pool.
			fresh.TLSNextProto = nil
			retry := *client
			retry.Transport = fresh
			// Preserve TLS verification, DNS, proxy, timeouts and cookie/redirect
			// isolation. Never evict the shared connection pool to force a retry.
			return &retry, fresh.CloseIdleConnections
		default:
			// Keep caller-supplied transports (including offline fixtures) intact.
			return client, func() {}
		}
	}
}
