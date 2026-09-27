package app

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type providerMediaCredentials struct {
	cookie    string
	origin    string
	referer   string
	userAgent string
	expires   time.Time
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
	request.Header.Del("Cookie")
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
	}
	return nil
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
