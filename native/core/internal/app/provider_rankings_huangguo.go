package app

import (
	"context"
	"errors"
	"strings"
	"time"
)

func (d *Downloader) fetchHuangguoRankingPage(ctx context.Context, board rankingBoard) (rankingPage, error) {
	ctx, cancel := context.WithTimeout(ctx, 18*time.Second)
	defer cancel()
	ctx = context.WithValue(ctx, providerTextExactURLKey{}, true)
	ctx = context.WithValue(ctx, providerTextSingleAttemptKey{}, true)
	base := d.huangguoAIContentBaseURL(ctx)
	configured := strings.TrimSpace(d.cfg.HuangguoAIURL)
	custom := configured != "" && !huangguoAIIsProviderRoute(configured) && !huangguoAIIsDeprecatedRoute(configured)
	seen := map[string]bool{}
	var lastErr error
	for pass := 0; pass < 2; pass++ {
		bases := []string{base}
		if !custom {
			discoveryCtx, discoveryCancel := context.WithTimeout(ctx, 4*time.Second)
			bases = append(bases, d.discoverHuangguoAIRoutes(discoveryCtx, pass == 1)...)
			discoveryCancel()
		}
		for _, route := range bases {
			route = strings.TrimRight(route, "/")
			if seen[route] {
				continue
			}
			seen[route] = true
			if err := ctx.Err(); err != nil {
				return rankingPage{}, err
			}
			requestCtx, requestCancel := context.WithTimeout(ctx, 3*time.Second)
			requestCtx = context.WithValue(requestCtx, providerTextValidatorKey{}, providerTextValidator(func(body, address string) error {
				_, err := parseHuangguoRanking(body, board, address)
				return err
			}))
			body, address, err := d.fetchProviderTextURL(requestCtx, route+"/ranks/"+board.path+"/", route+"/")
			requestCancel()
			if err == nil {
				return parseHuangguoRanking(body, board, address)
			}
			lastErr = err
		}
		if custom {
			break
		}
	}
	if err := ctx.Err(); err != nil {
		return rankingPage{}, err
	}
	if lastErr == nil {
		lastErr = errors.New("黄果未返回可用榜单线路")
	}
	return rankingPage{}, lastErr
}
