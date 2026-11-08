package app

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"
)

func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string, metadataAhead ...string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	if len(metadataAhead) > hongguoModelLookahead {
		return providerMedia{}, errors.New("红果播放预取范围无效")
	}
	ids := []string{videoID}
	for _, next := range metadataAhead {
		if !hongguoNumericID.MatchString(next) {
			return providerMedia{}, errors.New("红果视频 ID 无效")
		}
		if next != videoID && (len(ids) == 1 || next != ids[1]) {
			ids = append(ids, next)
		}
	}
	if cached := downloader.takeHongguoUpcomingModel(videoID); cached != nil {
		var entry map[string]any
		decoder := json.NewDecoder(bytes.NewReader(cached))
		decoder.UseNumber()
		if decoder.Decode(&entry) == nil {
			if media, err := parseHongguoAppMedia(entry); err == nil {
				traceCache(ctx)
				return media, nil
			}
		}
	}
	payload := map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0,
			// The conservative profile keeps AVC/HEVC lower-quality renditions
			// available instead of receiving ByteVC2-only lower tiers.
			"device_level":              1,
			"disable_digg_stat":         false,
			"need_all_video_definition": true,
			"need_mp4_align":            false,
			"use_os_player":             false,
			"use_server_dns":            false,
			// The player API rejects the detail API's video_platform value of 3.
			"video_platform": 1024,
		},
		"mixed_video_id_map": map[string]any{
			"1004": ids, // Short-drama content type.
		},
	}
	attempts := downloader.hongguoPlayerRequestAttempts()
	limit := 0
	if len(ids) > 1 {
		limit = 1
	}
	// Allocate after the cache check: a cached upcoming model needs no new device.
	register := func() (hongguoPlayerIdentity, error) {
		traceHongguoStage(ctx, "registration")
		identity, err := downloader.registerHongguoPlaybackDevice(ctx)
		if err != nil && ctx.Err() == nil {
			return identity, hongguoRefused(ctx, "registration_failed", err)
		}
		return identity, err
	}
	identity, err := register()
	if err != nil {
		return providerMedia{}, err
	}
	fallbackAttempted := false
	fetch := func(limit, offset int) (map[string]any, providerMedia, error) {
		traceHongguoStage(ctx, "model")
		result, err := downloader.hongguoRequest(ctx, "POST", "/novel/player/multi_video_model/v1/", nil, payload, limit, offset, &identity)
		if err != nil {
			return result, providerMedia{}, err
		}
		media, err := downloader.resolveHongguoAppModel(ctx, nestedMap(result, "data", videoID), &fallbackAttempted)
		return result, media, err
	}
	// One optional fresh-identity round on all-empty foreground failure. Each
	// resolve is independent; no old identity can poison another episode's state.
	lookaheadHint, _ := ctx.Value(hongguoMetadataAheadKey{}).(int)
	recoverIdentity := attempts == hongguoPlayerMaxAttempts && len(metadataAhead) == 0 && lookaheadHint == 0
	for round := 0; round < 2; round++ {
		result, media, err := fetch(limit, 0)
		emptyAttempts := hongguoEmptyAttemptCount(err)
		if err != nil && len(ids) > 1 && attempts > 1 && ctx.Err() == nil {
			var backoff *requestBackoff
			if !errors.As(err, &backoff) && !errors.Is(err, errHongguoDeviceRegistration) && !isHongguoSourceRefusal(err) && !fallbackAttempted {
				select {
				case <-time.After(hongguoPlaybackRetryDelay(1)):
				case <-ctx.Done():
					return providerMedia{}, ctx.Err()
				}
				ids = ids[:1]
				payload["mixed_video_id_map"] = map[string]any{"1004": ids}
				result, media, err = fetch(attempts-1, 1)
				remainingEmpty := hongguoEmptyAttemptCount(err)
				if emptyAttempts >= 0 && remainingEmpty >= 0 {
					emptyAttempts += remainingEmpty
				} else {
					emptyAttempts = -1
				}
			}
		}
		if ctx.Err() != nil {
			return providerMedia{}, ctx.Err()
		}
		if err == nil {
			downloader.keepHongguoUpcomingModels(ctx, result, ids[1:])
			return media, nil
		}
		if !recoverIdentity || emptyAttempts != attempts {
			return providerMedia{}, err
		}
		if round == 1 {
			return providerMedia{}, errHongguoPlaybackRecoveryExhausted
		}
		identity, err = register()
		if err != nil {
			return providerMedia{}, err
		}
	}
	return providerMedia{}, errHongguoPlaybackRecoveryExhausted
}

func decodeHongguoAppModel(entry map[string]any) (map[string]any, error) {
	model, _ := entry["video_model"].(map[string]any)
	if encoded, ok := entry["video_model"].(string); ok {
		decoder := json.NewDecoder(strings.NewReader(encoded))
		decoder.UseNumber()
		var extra any
		if decoder.Decode(&model) != nil || decoder.Decode(&extra) != io.EOF {
			return nil, errors.New("红果 App 播放信息格式异常")
		}
	}
	return model, nil
}

func parseHongguoAppMedia(entry map[string]any) (providerMedia, error) {
	model, err := decodeHongguoAppModel(entry)
	if err != nil {
		return providerMedia{}, err
	}
	return selectHongguoAppMedia(model)
}

func selectHongguoAppMedia(model map[string]any) (providerMedia, error) {
	variants := hongguoModelVariants(model)
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	type candidate struct {
		media         providerMedia
		codecPriority int
	}
	var candidates []candidate
	var keyErr error
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		priority, compatible := hongguoAppCodecPriority(variant)
		if !compatible {
			continue
		}
		key, err := hongguoAppVariantKey(variant)
		if err != nil {
			keyErr = err
			continue
		}
		quality := hongguoAppVariantQuality(variant)
		seen := map[string]bool{}
		for _, address := range hongguoAppVariantAddresses(variant) {
			if len(address) > 8192 || !isProviderHTTPMediaURL(address) || seen[address] {
				continue
			}
			seen[address] = true
			candidates = append(candidates, candidate{media: providerMedia{
				URL: address, Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second)), CENCKey: key, Quality: quality,
			}, codecPriority: priority})
			if len(seen) == hongguoAddressesPerQualityCodec {
				break
			}
		}
	}
	// Preserve the existing highest-quality choice, preferring AVC within a tier.
	// Equal-tier alternatives stay ahead of lower-quality fallback in the player.
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].media.Quality != candidates[j].media.Quality {
			return candidates[i].media.Quality > candidates[j].media.Quality
		}
		return candidates[i].codecPriority < candidates[j].codecPriority
	})
	var options []providerMedia
	seen := map[string]bool{}
	counts := map[[2]int]int{}
	for _, candidate := range candidates {
		media := candidate.media
		identity := media.URL + "\x00" + hex.EncodeToString(media.CENCKey)
		bucket := [2]int{media.Quality, candidate.codecPriority}
		if seen[identity] || counts[bucket] >= hongguoAddressesPerQualityCodec {
			continue
		}
		seen[identity] = true
		counts[bucket]++
		options = append(options, media)
	}
	if len(options) > 0 {
		selected := options[0]
		selected.Variants = options
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	return providerMedia{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}
