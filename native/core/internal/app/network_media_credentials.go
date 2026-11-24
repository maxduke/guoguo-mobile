package app

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

type providerMediaCredentials struct {
	publicOnly       bool
	cookie           string
	origin           string
	referer          string
	userAgent        string
	expires          time.Time
	headers          http.Header
	headerExtensions []string
}

type providerMediaCredentialsKey struct{}

func providerMediaContext(ctx context.Context, credentials *providerMediaCredentials) context.Context {
	return context.WithValue(ctx, providerMediaCredentialsKey{}, credentials)
}

func providerMediaOrigin(address *url.URL) string {
	if address == nil {
		return ""
	}
	scheme := strings.ToLower(address.Scheme)
	host := strings.ToLower(address.Host)
	if scheme == "https" && address.Port() == "443" || scheme == "http" && address.Port() == "80" {
		host = strings.TrimSuffix(host, ":"+address.Port())
	}
	return scheme + "://" + host
}

func (credentials *providerMediaCredentials) apply(request *http.Request) error {
	if credentials.publicOnly {
		if !validImageURL(request.URL) {
			return errors.New("插件媒体地址无效")
		}
		*request = *request.WithContext(context.WithValue(request.Context(), hppPublicRequestKey{}, true))
		request.Header.Del("Referer")
	}
	request.Header.Del("Cookie")
	for name := range credentials.headers {
		request.Header.Del(name)
	}
	if credentials.userAgent != "" {
		request.Header.Set("User-Agent", credentials.userAgent)
	}
	if credentials.referer != "" {
		request.Header.Set("Referer", credentials.referer)
		if address, err := url.Parse(credentials.referer); err == nil {
			request.Header.Set("Origin", providerMediaOrigin(address))
		}
	}
	if providerMediaOrigin(request.URL) == credentials.origin {
		if !credentials.expires.IsZero() && !time.Now().Before(credentials.expires) {
			return errors.New("播放凭证已过期，请重新解析播放")
		}
		request.Header.Set("Cookie", credentials.cookie)
		for _, extension := range credentials.headerExtensions {
			if strings.EqualFold(path.Ext(request.URL.Path), extension) {
				for name, values := range credentials.headers {
					request.Header[name] = append([]string(nil), values...)
				}
				break
			}
		}
	}
	return nil
}

// Website playback grants apply only to media on the selected stream origin.
// Never allow an upstream response to choose arbitrary request header names.
func huangguoPlaybackCredentials(media providerMedia, cdn map[string]any) (*providerMediaCredentials, error) {
	playlists, _ := cdn["m3u8Enabled"].(bool)
	assets, _ := cdn["otherEnabled"].(bool)
	if !playlists && !assets {
		return nil, nil
	}
	name, value, app := mapString(cdn, "authKey"), mapString(cdn, "authValue"), mapString(cdn, "app")
	if !strings.EqualFold(name, "x-cdn-auth") || value == "" || len(value) > 4096 || strings.ContainsAny(value, "\r\n\x00") || app == "" || len(app) > 64 || strings.ContainsAny(app, "\r\n\x00") {
		return nil, errors.New("黄果播放凭证格式不正确")
	}
	u, err := url.Parse(media.URL)
	if err != nil || !validImageURL(u) {
		return nil, errors.New("黄果播放地址不受支持")
	}
	credentials := &providerMediaCredentials{
		origin: providerMediaOrigin(u), referer: media.Referer, userAgent: userAgent,
		headers: http.Header{"X-Cdn-Auth": {value}, "X-Cdn-App": {app}},
	}
	if playlists {
		credentials.headerExtensions = append(credentials.headerExtensions, ".m3u8")
	}
	if assets {
		credentials.headerExtensions = append(credentials.headerExtensions, ".ts", ".m4s", ".key")
	}
	return credentials, nil
}

func (credentials *providerMediaCredentials) client(client *http.Client) *http.Client {
	scoped := *client
	scoped.Jar = nil
	previousRedirect := client.CheckRedirect
	scoped.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("媒体重定向过多")
		}
		if previousRedirect != nil {
			if err := previousRedirect(request, via); err != nil {
				return err
			}
		}
		return credentials.apply(request)
	}
	return &scoped
}

// Background tasks cannot depend on an in-process cookie jar or loopback server.
// CloudFront custom-policy parameters carry the same signed grant on each
// same-origin resource; credentials are never added to third-party assets.
func (credentials *providerMediaCredentials) downloadURL(address string) (string, error) {
	if credentials == nil || credentials.cookie == "" {
		return address, nil
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.User != nil || !isProviderHTTPMediaURL(address) {
		return "", errors.New("媒体资源地址无效")
	}
	if providerMediaOrigin(parsed) != credentials.origin {
		return address, nil
	}
	if !credentials.expires.IsZero() && !time.Now().Before(credentials.expires) {
		return "", errors.New("播放凭证已过期，请重新解析")
	}
	values := parsed.Query()
	request := &http.Request{Header: http.Header{"Cookie": {credentials.cookie}}}
	count := 0
	for _, cookie := range request.Cookies() {
		name := strings.TrimPrefix(cookie.Name, "CloudFront-")
		switch name {
		case "Policy", "Signature", "Key-Pair-Id", "Hash-Algorithm":
			if values.Has(name) {
				return "", errors.New("媒体地址包含冲突的授权参数")
			}
			values.Set(name, cookie.Value)
			if name != "Hash-Algorithm" {
				count++
			}
		}
	}
	if count != 3 {
		return "", errors.New("下载凭证不完整，请重新解析")
	}
	// Keep the original query byte-for-byte: it may participate in the policy.
	signed := url.Values{}
	for _, name := range []string{"Policy", "Signature", "Key-Pair-Id", "Hash-Algorithm"} {
		if values.Has(name) {
			signed.Set(name, values.Get(name))
		}
	}
	if parsed.RawQuery != "" {
		parsed.RawQuery += "&"
	}
	parsed.RawQuery += signed.Encode()
	return parsed.String(), nil
}
