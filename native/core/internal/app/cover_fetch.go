package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// The category API and HTML pages use different Huangguo image CDNs.
func isHuangguoImageHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	return host == "pic.tuafjz.cn" || host == "pic.zdmhyg.cn" || strings.HasSuffix(host, ".zdmhyg.cn")
}

func isHongguoImageHost(host string) bool {
	host = strings.ToLower(host)
	return host == "hongguoduanju.com" || host == "www.hongguoduanju.com" ||
		strings.HasSuffix(host, ".byteimg.com") || strings.HasSuffix(host, ".fqnovelpic.com")
}

// Image decoding is handled by the mobile platform.
func (downloader *Downloader) fetchCoverImage(ctx context.Context, remoteURL string, decode func([]byte, string) []byte) ([]byte, error) {
	ctx = context.WithValue(ctx, coverRequestKey{}, true)
	// Legacy Huangguo catalogs (and saved mobile records) contain relative paths.
	// Resolve relative paths through the source CDN mapping.
	remoteURL, ok := buildImageURL(remoteURL)
	if !ok {
		return nil, errors.New("封面地址不受支持")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, remoteURL, nil)
	if err != nil {
		return nil, err
	}
	if !validImageURL(request.URL) {
		return nil, errors.New("封面地址不受支持")
	}
	referer := downloader.coverReferer(ctx, remoteURL)
	request.Header.Set("Referer", referer)
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Accept", "image/webp,image/jpeg,image/png,image/gif,*/*;q=0.5")
	client := *downloader.client
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) >= 5 || !validImageURL(request.URL) {
			return errors.New("封面重定向地址不受支持")
		}
		request.Header.Set("Referer", referer)
		return nil
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("封面上游 HTTP %d", response.StatusCode)
	}
	if response.ContentLength > maxCoverBytes {
		return nil, errors.New("封面文件过大")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxCoverBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxCoverBytes {
		return nil, errors.New("封面文件过大")
	}
	if decode != nil {
		data = decode(data, remoteURL)
	}
	if isKnownImage(data) {
		return data, nil
	}
	if isHEICImage(data) {
		return data, nil
	}
	return nil, errors.New("封面内容无效，请检查代理或站点是否需要验证")
}
