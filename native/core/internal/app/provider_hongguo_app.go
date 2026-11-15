package app

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const hongguoAppBaseURL = "https://api5-normal-sinfonlineb.fqnovel.com"
const hongguoAppVersion = "7.3.5.32"
const hongguoAppVersionCode = "73532"
const hongguoAppUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
const hongguoVideoTabPath = "/reading/bookapi/video_tab/multi_video_model/v1/"
const hongguoLegacyPlayerPath = "/novel/player/multi_video_model/v1/"

type hongguoRequestMode uint8

const (
	hongguoSignedAppRequest hongguoRequestMode = iota
	hongguoAnonymousPlayerRequest
)

// An anonymous identity belongs to one logical resolve, including its retries.
type hongguoPlayerIdentity struct {
	deviceID  string
	installID string
	cdid      string
	cookie    string
}

type hongguoCatalogCursor struct {
	Offset        int       `json:"offset"`
	SessionID     string    `json:"sessionId,omitempty"`
	LastID        string    `json:"lastId,omitempty"`
	PageSignature string    `json:"pageSignature,omitempty"`
	Initialized   bool      `json:"initialized"`
	Exhausted     bool      `json:"exhausted"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

type hongguoCatalogState struct {
	Version   int                             `json:"version"`
	DeviceID  string                          `json:"deviceId"`
	InstallID string                          `json:"installId"`
	Feeds     map[string]hongguoCatalogCursor `json:"feeds"`
}

type hongguoAppClient struct {
	mu                     sync.Mutex
	catalogMu              sync.Mutex
	baseURL                string
	state                  hongguoCatalogState
	registrationRetryAfter time.Time
	upcomingModels         map[string]hongguoUpcomingModel
	details                map[string]hongguoDetailEntry
	pending                map[string]*hongguoDetailCall
	searches               map[string]hongguoSearchEntry
	searchPending          map[string]*hongguoSearchCall
	suggestions            map[string]hongguoSuggestionEntry
	suggestPending         map[string]*hongguoSuggestionCall
}

func (downloader *Downloader) hongguoClient() *hongguoAppClient {
	downloader.hongguoOnce.Do(func() {
		downloader.hongguo = &hongguoAppClient{
			baseURL: hongguoAppBaseURL,
			state:   hongguoCatalogState{Version: 1, DeviceID: newHongguoDeviceID(), InstallID: newHongguoDeviceID(), Feeds: map[string]hongguoCatalogCursor{}},
			details: map[string]hongguoDetailEntry{}, pending: map[string]*hongguoDetailCall{},
			searches: map[string]hongguoSearchEntry{}, searchPending: map[string]*hongguoSearchCall{},
			suggestions: map[string]hongguoSuggestionEntry{}, suggestPending: map[string]*hongguoSuggestionCall{},
		}
	})
	return downloader.hongguo
}

func cloneHongguoCatalogState(state *hongguoCatalogState) *hongguoCatalogState {
	if state == nil {
		return nil
	}
	cloned := *state
	cloned.Feeds = make(map[string]hongguoCatalogCursor, len(state.Feeds))
	for name, cursor := range state.Feeds {
		cloned.Feeds[name] = cursor
	}
	return &cloned
}

func (downloader *Downloader) restoreHongguoCatalog(state *hongguoCatalogState) {
	if state == nil || state.Version != 1 {
		return
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.state.Feeds) != 0 {
		return
	}
	cloned := cloneHongguoCatalogState(state)
	if !hongguoNumericID.MatchString(cloned.DeviceID) || !hongguoNumericID.MatchString(cloned.InstallID) {
		return
	}
	for name, cursor := range cloned.Feeds {
		known := false
		for _, genre := range hongguoAppGenres {
			known = known || name == genre.key
		}
		if !known || cursor.Offset < 0 || cursor.Offset > 1_000_000 || len(cursor.SessionID) > 4096 {
			delete(cloned.Feeds, name)
		}
	}
	client.state = *cloned
}

func (downloader *Downloader) hongguoCatalogSnapshot() *hongguoCatalogState {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return cloneHongguoCatalogState(&client.state)
}

func hongguoCatalogInitialized(state *hongguoCatalogState) bool {
	if state != nil && state.Version == 1 {
		for _, cursor := range state.Feeds {
			if cursor.Initialized {
				return true
			}
		}
	}
	return false
}

func hongguoCatalogHasMore(state *hongguoCatalogState) bool {
	for _, genre := range hongguoAppGenres {
		if state == nil || !state.Feeds[genre.key].Exhausted {
			return true
		}
	}
	return false
}

func (downloader *Downloader) hongguoAppRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	return downloader.hongguoRequest(ctx, method, path, extra, payload, 0, 0, nil)
}

func (downloader *Downloader) hongguoRequestAttempts() int {
	return max(1, min(downloader.cfg.Retries, 3))
}

func hongguoAppDeviceQuery() url.Values {
	return url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {hongguoAppVersionCode}, "version_name": {hongguoAppVersion},
		"manifest_version_code": {hongguoAppVersionCode}, "update_version_code": {hongguoAppVersionCode}, "channel": {"update_64"},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
		"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"},
	}
}

func (downloader *Downloader) hongguoRequest(ctx context.Context, method, path string, extra url.Values, payload any, limit, offset int, player *hongguoPlayerIdentity) (map[string]any, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	base, deviceID, installID := client.baseURL, client.state.DeviceID, client.state.InstallID
	client.mu.Unlock()
	mode := hongguoSignedAppRequest
	httpClient := downloader.client
	if player != nil {
		mode = hongguoAnonymousPlayerRequest
		deviceID, installID = player.deviceID, player.installID
		httpClient = hongguoAnonymousClient(httpClient)
	}
	query := hongguoAppDeviceQuery()
	query.Set("device_id", deviceID)
	query.Set("iid", installID)
	for key, values := range extra {
		query[key] = append([]string(nil), values...)
	}
	if mode == hongguoAnonymousPlayerRequest {
		version, code := "7.4.3.32", "74332"
		if path == hongguoVideoTabPath {
			version, code = "7.3.9.32", "73932"
		}
		for _, name := range []string{"version_code", "manifest_version_code", "update_version_code", "pv_player"} {
			query.Set(name, code)
		}
		query.Set("version_name", version)
		for name, value := range map[string]string{
			"host_abi": "arm64-v8a", "dragon_device_type": "phone", "compliance_status": "0",
			"need_personal_recommend": "1", "player_so_load": "1", "is_android_pad_screen": "0",
		} {
			query.Set(name, value)
		}
		query.Set("cdid", player.cdid)
	}
	var body []byte
	var err error
	if payload != nil {
		body, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		if mode == hongguoAnonymousPlayerRequest {
			var compressed bytes.Buffer
			writer := gzip.NewWriter(&compressed)
			if _, err := writer.Write(body); err != nil {
				return nil, err
			}
			if err := writer.Close(); err != nil {
				return nil, err
			}
			body = compressed.Bytes()
		}
	}
	attempts := downloader.hongguoRequestAttempts()
	if mode == hongguoAnonymousPlayerRequest {
		attempts = downloader.hongguoPlayerRequestAttempts()
	}
	if limit > 0 && limit < attempts {
		attempts = limit
	}
	var lastErr error
	emptyResponses := 0
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			delay := time.Duration(attempt) * time.Second
			if mode == hongguoAnonymousPlayerRequest {
				delay = hongguoPlaybackRetryDelay(offset + attempt)
			}
			select {
			case <-time.After(delay):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		attemptClient := httpClient
		if mode == hongguoAnonymousPlayerRequest {
			if offset+attempt > 0 {
				var release func()
				attemptClient, release = hongguoFreshPlayerClient(httpClient)
				defer release()
			}
		}
		request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(base, "/")+path, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Close = mode == hongguoAnonymousPlayerRequest && offset+attempt > 0
		request.Header.Set("User-Agent", hongguoAppUserAgent)
		if mode == hongguoAnonymousPlayerRequest {
			request.Header.Set("User-Agent", strings.Replace(hongguoAppUserAgent, hongguoAppVersionCode, query.Get("version_code"), 1))
		}
		request.Header.Set("Accept", "application/json")
		request.Header.Set("X-XS-From-Web", "0")
		request.Header.Set("Sdk-Version", "2")
		if mode == hongguoAnonymousPlayerRequest && player.cookie != "" {
			request.Header.Set("Cookie", player.cookie)
		}
		comment, _ := ctx.Value(hongguoCommentKey{}).(bool)
		comment = comment && mode == hongguoSignedAppRequest
		var commentNonce hongguoCommentNonce
		if comment {
			commentNonce, err = newHongguoCommentNonce()
			if err != nil {
				return nil, errors.New("无法准备红果文字请求")
			}
			request.Header.Set("Comment-Source", "601")
			request.Header.Set("Server-Channel", "1000")
		}
		if payload != nil {
			request.Header.Set("Content-Type", "application/json; charset=utf-8")
			if mode == hongguoAnonymousPlayerRequest {
				request.Header.Set("Content-Encoding", "gzip")
			}
		}
		response, err := downloader.doPreparedCatalogRequestWithClient(request, 20*time.Second, func(prepared *http.Request) error {
			now := time.Now()
			query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
			if mode == hongguoAnonymousPlayerRequest {
				query.Set("ts", strconv.FormatInt(now.Unix(), 10))
				prepared.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
				prepared.Header.Set("X-SS-Req-Ticket", query.Get("_rticket"))
				prepared.Header.Set("X-TT-Request-Tag", "t=0;n=0")
			}
			prepared.URL.RawQuery = query.Encode()
			if mode == hongguoAnonymousPlayerRequest {
				// Sign the final query and exact POST bytes on every route attempt.
				if err := signHongguoPlayerRequest(prepared, body, now); err != nil {
					return err
				}
				prepared.Header.Set("X-SS-DP", query.Get("aid"))
				prepared.Header.Set("Passport-Sdk-Version", "5051452")
				prepared.Header.Del("X-TT-Request-Tag")
				if path == hongguoVideoTabPath {
					prepared.Header.Set("Passport-Sdk-Version", "50561")
					prepared.Header.Set("X-TT-Request-Tag", "t=0;n=0")
				}
				prepared.Header.Set("X-TT-Store-Region", "cn")
				prepared.Header.Set("X-TT-Store-Region-Src", "did")
				return nil
			}
			if comment {
				signHongguoCommentRequest(prepared, commentNonce, now)
				return nil
			}
			return signHongguoRequest(prepared, body, now)
		}, attemptClient)
		if err != nil {
			lastErr = err
			var backoff *requestBackoff
			if errors.As(err, &backoff) || ctx.Err() != nil {
				if mode == hongguoAnonymousPlayerRequest && backoff != nil {
					return nil, hongguoHTTPRefusal(ctx, backoff.status, err)
				}
				return nil, err
			}
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
		response.Body.Close()
		if mode == hongguoAnonymousPlayerRequest {
			traceUpdate(ctx, func(v *mobileDiagnostic) { v.ResponseBytes = int64(len(content)) })
		}
		if response.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果 App 接口 HTTP %d", response.StatusCode)
			if response.StatusCode >= 400 && response.StatusCode < 500 {
				if mode == hongguoAnonymousPlayerRequest {
					return nil, hongguoHTTPRefusal(ctx, response.StatusCode, lastErr)
				}
				return nil, lastErr
			}
			continue
		}
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if len(content) > providerMaxBodyBytes {
			return nil, errors.New("红果 App 接口未返回有效数据")
		}
		if len(content) == 0 || mode == hongguoAnonymousPlayerRequest && len(bytes.TrimSpace(content)) == 0 {
			lastErr = errors.New("红果 App 接口未返回有效数据")
			if mode == hongguoAnonymousPlayerRequest {
				emptyResponses++
				// Transient empty models share the existing retry budget and identity.
				continue
			}
			return nil, lastErr
		}
		var result map[string]any
		decoder := json.NewDecoder(bytes.NewReader(content))
		decoder.UseNumber()
		if err := decoder.Decode(&result); err != nil || result == nil {
			if mode == hongguoAnonymousPlayerRequest {
				traceHongguoFailure(ctx, "invalid_response")
			}
			return nil, errors.New("红果 App 接口返回格式异常")
		}
		code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
		if code != "" && code != "0" {
			if mode == hongguoAnonymousPlayerRequest {
				traceHongguoFailure(ctx, "business_rejected")
			}
			return nil, fmt.Errorf("红果 App 接口暂不可用（%s）", truncate(code, 20))
		}
		return result, nil
	}
	if mode == hongguoAnonymousPlayerRequest && emptyResponses == attempts {
		traceHongguoFailure(ctx, "empty_model")
		return nil, &hongguoEmptyPlaybackError{attempts: attempts}
	}
	return nil, lastErr
}
