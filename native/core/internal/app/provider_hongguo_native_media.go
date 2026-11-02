package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	fetch := func(limit, offset int) (hongguoPlayerResponse, providerMedia, error) {
		result, err := downloader.hongguoPlayerRequestWithAttempts(ctx, "/novel/player/multi_video_model/v1/", payload, limit, offset)
		if err != nil {
			return result, providerMedia{}, err
		}
		// Never substitute another episode when the requested ID is missing.
		media, err := parseHongguoAppMedia(nestedMap(result.data, "data", videoID))
		return result, media, err
	}
	// Two old-identity rounds and at most one replacement-identity round fit in
	// the existing request deadline. Optional background lookahead never rotates
	// the identity or starts additional rounds on behalf of the current player.
	lookaheadHint, _ := ctx.Value(hongguoMetadataAheadKey{}).(int)
	recoverIdentity := attempts == hongguoPlayerMaxAttempts && len(metadataAhead) == 0 && lookaheadHint == 0
	for round := 0; round < 3; round++ {
		result, media, err := fetch(limit, 0)
		emptyAttempts := hongguoEmptyAttemptCount(err)
		if err != nil && len(ids) > 1 && attempts > 1 && ctx.Err() == nil {
			var backoff *requestBackoff
			if !errors.As(err, &backoff) && !errors.Is(err, errHongguoDeviceRegistration) {
				select {
				case <-time.After(hongguoPlaybackRetryDelay(1)):
				case <-ctx.Done():
					return providerMedia{}, ctx.Err()
				}
				firstLease := result.lease
				ids = ids[:1]
				payload["mixed_video_id_map"] = map[string]any{"1004": ids}
				result, media, err = fetch(attempts-1, 1)
				remainingEmpty := hongguoEmptyAttemptCount(err)
				if emptyAttempts >= 0 && remainingEmpty >= 0 && result.lease == firstLease {
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
			downloader.hongguoPlaybackModelSucceeded(result.lease)
			downloader.keepHongguoUpcomingModels(result.data, ids[1:], result.lease.identity)
			return media, nil
		}
		if recoverIdentity {
			allEmpty := emptyAttempts == attempts
			retry, rotate := downloader.hongguoPlaybackRoundFailed(result.lease, allEmpty)
			if retry && round < 2 {
				if rotate {
					changed, rotateErr := downloader.rotateHongguoPlaybackDevice(ctx, result.lease)
					if rotateErr != nil {
						return providerMedia{}, rotateErr
					}
					if !changed {
						return providerMedia{}, errHongguoPlaybackRecoveryExhausted
					}
				}
				select {
				case <-time.After(hongguoPlaybackRetryDelay(1)):
					continue
				case <-ctx.Done():
					return providerMedia{}, ctx.Err()
				}
			}
			if allEmpty && downloader.hongguoPlaybackRecoveryAttempted(result.lease) {
				return providerMedia{}, errHongguoPlaybackRecoveryExhausted
			}
		}
		return providerMedia{}, err
	}
	return providerMedia{}, errHongguoPlaybackRecoveryExhausted
}

func parseHongguoAppMedia(entry map[string]any) (providerMedia, error) {
	model, _ := entry["video_model"].(map[string]any)
	if encoded, ok := entry["video_model"].(string); ok {
		decoder := json.NewDecoder(strings.NewReader(encoded))
		decoder.UseNumber()
		if err := decoder.Decode(&model); err != nil {
			return providerMedia{}, errors.New("红果 App 播放信息格式异常")
		}
	}
	return selectHongguoAppMedia(model)
}

func selectHongguoAppMedia(model map[string]any) (providerMedia, error) {
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var selected providerMedia
	bestQuality := -1
	var keyErr error
	choices := make(map[int]providerMedia)
	scores := make(map[int]int)
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		gear := strings.ToLower(mapString(variant, "gear_des_key"))
		if codec == "bytevc2" || codec == "bvc2" || strings.Contains(gear, "bytevc2") || strings.Contains(gear, "bvc2") {
			continue
		}
		address := mapString(variant, "main_url")
		if len(address) > 8192 || !isProviderHTTPMediaURL(address) {
			continue
		}
		media := providerMedia{URL: address, Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = hongguoContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(hongguoQualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		if previous, exists := scores[height]; !exists || quality > previous {
			choices[height], scores[height] = media, quality
		}
		if selected.URL == "" || quality > bestQuality {
			selected, bestQuality = media, quality
		}
	}
	if selected.URL != "" {
		for _, media := range choices {
			selected.Variants = append(selected.Variants, media)
		}
		sort.Slice(selected.Variants, func(i, j int) bool { return selected.Variants[i].Quality > selected.Variants[j].Quality })
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	return providerMedia{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}
