// Public website playback adapted from jackotom/hongguo-drama, GPL-3.0-only.
// Source revision and local constraints: native/core/UPSTREAM.md.
package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const (
	hongguoPublicPlaybackPath    = "/api/video/protected/fallback-play-info"
	hongguoPublicPlaybackQuality = 360
	hongguoPublicPlaybackLimit   = 64 * 1024
)

var (
	errHongguoPublicEpisodeUnavailable = errors.New("红果官网未开放本集的公开播放")
	errHongguoPublicPlaybackDenied     = errors.New("红果官网暂时拒绝播放请求，请稍后重试")
)

type hongguoPublicPlaybackRequestKey struct{}

func (d *Downloader) resolveHongguoPublicMedia(ctx context.Context, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	traceHongguoStage(ctx, "public_playback")
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	ctx = context.WithValue(ctx, hongguoPublicPlaybackRequestKey{}, true)
	ctx = context.WithValue(ctx, coverSourceKey{}, sourceHongguo)
	body, _ := json.Marshal(map[string]string{"item_id": videoID})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoBaseURL+hongguoPublicPlaybackPath, bytes.NewReader(body))
	if err != nil {
		return providerMedia{}, err
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Referer", hongguoBaseURL+"/")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")

	release, err := d.limiter.acquire(ctx, request)
	if err != nil {
		var backoff *requestBackoff
		if errors.As(err, &backoff) {
			traceHongguoPublicDenial(ctx, backoff.status)
			return providerMedia{}, errHongguoPublicPlaybackDenied
		}
		return providerMedia{}, err
	}
	defer release()
	traceNetwork(ctx)
	response, err := hongguoAnonymousClient(d.client).Do(request)
	if err != nil {
		traceHongguoFailure(ctx, "fallback_request_failed")
		return providerMedia{}, err
	}
	defer response.Body.Close()
	raw, readErr := io.ReadAll(io.LimitReader(response.Body, hongguoPublicPlaybackLimit+1))
	traceUpdate(ctx, func(v *mobileDiagnostic) { v.HTTPStatus, v.ResponseBytes = response.StatusCode, int64(len(raw)) })
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}

	var data struct {
		Error    string      `json:"error"`
		ItemID   json.Number `json:"item_id"`
		MainURL  string      `json:"main_url"`
		Expires  json.Number `json:"url_expire"`
		Code     json.Number `json:"code"`
		BaseResp struct {
			StatusCode json.Number `json:"StatusCode"`
		} `json:"base_resp"`
	}
	valid := readErr == nil && len(raw) <= hongguoPublicPlaybackLimit && json.Unmarshal(raw, &data) == nil
	if catalogResponseBlockReason(response, raw) != "" {
		d.limiter.observeBlock(request, response)
		traceHongguoPublicDenial(ctx, response.StatusCode)
		return providerMedia{}, errHongguoPublicPlaybackDenied
	}
	if response.StatusCode == http.StatusForbidden && valid && data.Error == "public_fallback_unavailable" {
		// This denial applies to the current episode. Other episodes may be public.
		traceHongguoFailure(ctx, "public_episode_unavailable")
		return providerMedia{}, errHongguoPublicEpisodeUnavailable
	}
	if response.StatusCode != http.StatusOK {
		d.limiter.observe(request, response)
		switch response.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden, http.StatusTooManyRequests:
			traceHongguoPublicDenial(ctx, response.StatusCode)
			return providerMedia{}, errHongguoPublicPlaybackDenied
		}
		traceHongguoFailure(ctx, "http_error")
		return providerMedia{}, fmt.Errorf("红果官网播放接口 HTTP %d", response.StatusCode)
	}

	seconds, expiryErr := data.Expires.Int64()
	expires := time.Unix(seconds, 0)
	code := data.Code.String()
	if !valid || data.Error != "" || firstNonEmpty(data.BaseResp.StatusCode.String(), code) != "0" || code != "" && code != "0" ||
		data.ItemID != "" && data.ItemID.String() != videoID || !hongguoAllowedMediaURL(data.MainURL) ||
		expiryErr != nil || seconds <= 0 || !expires.After(time.Now().Add(5*time.Second)) || expires.UnixMilli() <= 0 {
		traceHongguoFailure(ctx, "fallback_invalid")
		return providerMedia{}, errors.New("红果官网未返回有效的公开播放地址")
	}
	remote, err := url.Parse(data.MainURL)
	if err != nil || !validImageURL(remote) {
		traceHongguoFailure(ctx, "fallback_invalid")
		return providerMedia{}, errors.New("红果官网未返回有效的公开播放地址")
	}
	return providerMedia{
		URL: data.MainURL, Referer: hongguoBaseURL + "/", Quality: hongguoPublicPlaybackQuality,
		credentials: &providerMediaCredentials{
			publicOnly: true, origin: providerMediaOrigin(remote), referer: hongguoBaseURL + "/",
			userAgent: userAgent, expires: expires,
		},
	}, nil
}

func traceHongguoPublicDenial(ctx context.Context, status int) {
	traceUpdate(ctx, func(v *mobileDiagnostic) {
		v.HTTPStatus = status
		v.SourceFailure = "http_denied"
		if status == http.StatusTooManyRequests {
			v.SourceFailure = "rate_limited"
		}
	})
}
