package app

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"
)

func (d *Downloader) fetchHuangguoRankingPage(ctx context.Context, board rankingBoard) (rankingPage, error) {
	var result rankingPage
	_, err := d.readHuangguoAPI(ctx, "/api/ranks/"+board.path, func(raw []byte, base string) error {
		var err error
		result, err = parseHuangguoAPIRanking(raw, base, board.path)
		return err
	})
	if err == nil {
		return result, nil
	}
	if !huangguoAPICanFallback(ctx, err) {
		return rankingPage{}, err
	}
	return d.fetchHuangguoHTMLRankingPage(ctx, board)
}

func parseHuangguoAPIRanking(raw []byte, base, kind string) (rankingPage, error) {
	var data struct {
		Type  string             `json:"type"`
		Items *[]json.RawMessage `json:"items"`
	}
	if json.Unmarshal(raw, &data) != nil || data.Type != kind || data.Items == nil || len(*data.Items) > 100 {
		return rankingPage{}, errors.New("黄果接口未返回有效榜单")
	}
	result := rankingPage{Items: make([]rankingItem, 0, len(*data.Items)), TotalPages: 1}
	seen := map[string]bool{}
	previous := 0
	for _, raw := range *data.Items {
		item, err := decodeHuangguoAPIMap(raw)
		if err != nil {
			return rankingPage{}, err
		}
		item["id"] = item["video_id"]
		drama, ok := huangguoAPIDrama(item, base, mapString(item, "cate_name"))
		rank, _ := strconv.Atoi(mapString(item, "rank"))
		if !ok || rank <= previous || seen[drama.ID] {
			return rankingPage{}, errors.New("黄果接口榜单身份或名次不正确")
		}
		seen[drama.ID], previous = true, rank
		result.Items = append(result.Items, rankingItem{Rank: rank, Drama: drama, Metric: strings.TrimSpace(mapString(item, "metric_label") + " " + mapString(item, "metric_value"))})
	}
	return result, nil
}

func (d *Downloader) fetchHuangguoHTMLRankingPage(ctx context.Context, board rankingBoard) (rankingPage, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	ctx = context.WithValue(ctx, providerTextExactURLKey{}, true)
	ctx = context.WithValue(ctx, providerTextSingleAttemptKey{}, true)
	discoveryCtx, discoveryCancel := context.WithTimeout(ctx, 8*time.Second)
	base := d.huangguoAIContentBaseURL(discoveryCtx)
	discoveryCancel()
	custom := d.huangguoAIPinned()
	seen := map[string]bool{}
	var lastErr error
	for pass := 0; pass < 2; pass++ {
		bases := []string{base}
		if !custom {
			discoveryCtx, discoveryCancel := context.WithTimeout(ctx, 8*time.Second)
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
			// Allow DNS recovery and TLS setup before abandoning a usable route.
			requestCtx, requestCancel := context.WithTimeout(ctx, 8*time.Second)
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
