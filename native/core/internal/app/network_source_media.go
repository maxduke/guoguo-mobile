package app

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
)

func (d *Downloader) fetchMediaPlaylist(ctx context.Context, address, referer string) (string, string, error) {
	if !isProviderHTTPMediaURL(address) {
		return "", "", errors.New("播放列表地址无效")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", "", err
	}
	request.Header.Set("Referer", referer)
	request.Header.Set("User-Agent", userAgent)
	client := d.client
	if credentials, _ := ctx.Value(providerMediaCredentialsKey{}).(*providerMediaCredentials); credentials != nil {
		if err := credentials.apply(request); err != nil {
			return "", "", err
		}
		client = credentials.client(client)
	}
	response, err := client.Do(request)
	if err != nil {
		return "", "", err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, (4<<20)+1))
	if err != nil || len(body) > 4<<20 {
		return "", "", errors.New("播放列表过大或读取失败")
	}
	if response.StatusCode != http.StatusOK || catalogResponseBlockReason(response, body) != "" {
		return "", "", d.catalogResponseError(request, response, body)
	}
	text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
	if !strings.HasPrefix(text, "#EXTM3U") {
		return "", "", errors.New("站源未返回有效播放列表，请重新解析")
	}
	if response.Request != nil && response.Request.URL != nil {
		address = response.Request.URL.String()
	}
	return text, address, nil
}
