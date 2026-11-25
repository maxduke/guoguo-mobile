package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// A user-selected or explicitly configured content origin is a fixed choice.
// Automatic recovery only uses origins from the official discovery path.
func (d *Downloader) huangguoAIPinned() bool {
	d.providerMu.Lock()
	selected := d.huangguoLine
	d.providerMu.Unlock()
	configured := strings.TrimRight(strings.TrimSpace(d.cfg.HuangguoAIURL), "/")
	return selected != "" || configured != "" && !huangguoAIIsDeprecatedRoute(configured) &&
		(!huangguoAIIsProviderRoute(configured) || huangguoAIIsContentRoute(configured))
}

// Each read tries at most two official routes within the caller deadline and a
// shared 16-second bound. Playback may try one direct request on an edge 503.
// Validate the actual page/work/episode before remembering a recovered origin.
func (d *Downloader) readHuangguoAPI(ctx context.Context, path string, validate func([]byte, string) error, methods ...string) (huangguoAPIReply, error) {
	work, cancel := context.WithTimeout(ctx, 16*time.Second)
	defer cancel()
	d.providerMu.Lock()
	revision := d.huangguoLineRevision
	d.providerMu.Unlock()
	pinned := d.huangguoAIPinned()
	base := d.huangguoAIContentBaseURL(work)
	d.providerMu.Lock()
	preferred := d.providerHosts[sourceHuangguoAI]
	routes := append([]string(nil), d.huangguoAIRoutes...)
	d.providerMu.Unlock()
	directTried := false
	attempt := func(origin string) (huangguoAPIReply, error) {
		reply, err := d.requestHuangguoAPI(work, origin, path, false, methods...)
		if !directTried && len(methods) > 0 && methods[0] == http.MethodPost && isHuangguoPlaybackAPIPath(path) &&
			reply.status == http.StatusServiceUnavailable && huangguoAPICanFallback(work, err) {
			directTried = true
			// The origin already serves this anonymous playback API directly.
			// Retain the edge failure if the direct endpoint is also unavailable.
			directReply, directErr := d.postHuangguoAPI(work, origin, path, []byte("{}"))
			if directErr == nil || !huangguoAPICanFallback(work, directErr) {
				reply, err = directReply, directErr
			}
		}
		if err == nil {
			err = validate(reply.data, origin)
		}
		if work.Err() != nil {
			return reply, work.Err()
		}
		return reply, err
	}
	finish := func(reply huangguoAPIReply, err error) (huangguoAPIReply, error) {
		if err == nil && !pinned && work.Err() == nil {
			d.providerMu.Lock()
			if d.huangguoLine == "" && d.huangguoLineRevision == revision && d.providerHosts[sourceHuangguoAI] == preferred {
				d.providerHosts[sourceHuangguoAI] = reply.base
			}
			d.providerMu.Unlock()
		}
		if err != nil && len(reply.data) > 0 {
			// After bounded recovery, malformed successful responses must not
			// become empty success or restart another HTML recovery loop.
			err = fmt.Errorf("%w：%w", errHuangguoAPIInvalid, err)
		}
		return reply, err
	}
	reply, err := attempt(base)
	if err == nil || pinned || errors.Is(err, errHuangguoAPIUnavailable) || !huangguoAPICanFallback(work, err) {
		return finish(reply, err)
	}
	next := func(candidates []string) string {
		for _, candidate := range candidates {
			if origin, valid := normalizeHuangguoLine(candidate); valid && origin != base {
				return origin
			}
		}
		return ""
	}
	origin := next(routes)
	if origin == "" && work.Err() == nil {
		origin = next(d.discoverHuangguoAIRoutes(work, true))
		// Discovery may replace an expired preferred origin. Do not mistake
		// our own refresh for a newer successful concurrent read.
		d.providerMu.Lock()
		preferred = d.providerHosts[sourceHuangguoAI]
		d.providerMu.Unlock()
	}
	if origin == "" || work.Err() != nil {
		return finish(reply, err)
	}
	return finish(attempt(origin))
}
