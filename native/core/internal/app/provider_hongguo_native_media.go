package app

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
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
	traceHongguoStage(ctx, "registration")
	identity, err := downloader.registerHongguoPlaybackDevice(ctx)
	if err != nil {
		if ctx.Err() == nil {
			err = hongguoRefused(ctx, "registration_failed", err)
		}
		return providerMedia{}, err
	}
	// One current GET, with one legacy POST only after an empty HTTP 200 body.
	// Never restart the model ladder for rejection, wrong identity or bad media.
	work, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	traceHongguoStage(ctx, "model")
	query := url.Values{
		"video_id": {videoID}, "video_id_type": {"0"}, "device_level": {"1"},
		"need_all_video_definition": {"1"}, "need_mp4_align": {"0"}, "use_os_player": {"0"},
		"video_platform": {"1024"}, "source": {"0"}, "from_video_id": {""},
	}
	result, err := downloader.hongguoRequest(work, http.MethodGet, hongguoVideoTabPath, query, nil, 1, 0, &identity)
	if hongguoEmptyAttemptCount(err) == 1 && downloader.hongguoPlayerRequestAttempts() > 1 && work.Err() == nil {
		// A fresh identity is optional; explicit refusal and caller cancellation
		// still stop recovery, while a transient registration failure can retain it.
		if deadline, ok := work.Deadline(); ok && time.Until(deadline) >= 8*time.Second {
			traceHongguoStage(ctx, "registration")
			fresh, registerErr := downloader.registerHongguoPlaybackDevice(work)
			if registerErr == nil {
				identity = fresh
			} else if work.Err() != nil {
				return providerMedia{}, work.Err()
			} else if hongguoRegistrationRefused(registerErr) {
				return providerMedia{}, hongguoRefused(ctx, "registration_failed", registerErr)
			}
		}
		select {
		case <-time.After(time.Second):
		case <-work.Done():
			return providerMedia{}, work.Err()
		}
		traceHongguoStage(ctx, "model")
		payload := map[string]any{
			"biz_param": map[string]any{
				"detail_page_version": 0, "device_level": 1, "disable_digg_stat": false,
				"need_all_video_definition": true, "need_mp4_align": false,
				"use_os_player": false, "use_server_dns": false, "video_platform": 1024,
			},
			"mixed_video_id_map": map[string]any{"1004": ids[:1]},
		}
		result, err = downloader.hongguoRequest(work, http.MethodPost, hongguoLegacyPlayerPath, nil, payload, 1, 1, &identity)
		if hongguoEmptyAttemptCount(err) == 1 {
			err = errHongguoPlaybackRecoveryExhausted
		}
	}
	if work.Err() != nil {
		return providerMedia{}, work.Err()
	}
	if err != nil {
		return providerMedia{}, err
	}
	data := nestedMap(result, "data")
	if _, wrapped := data["video_model_data"]; wrapped {
		data = nestedMap(data, "video_model_data")
	}
	fallbackAttempted := false
	media, err := downloader.resolveHongguoAppModel(work, nestedMap(data, videoID), &fallbackAttempted)
	if err != nil {
		return providerMedia{}, err
	}
	if work.Err() != nil {
		return providerMedia{}, work.Err()
	}
	downloader.keepHongguoUpcomingModels(work, map[string]any{"data": data}, ids[1:])
	return media, nil
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
