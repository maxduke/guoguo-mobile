package app

import (
	"context"
	"crypto/aes"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

func (downloader *Downloader) resolvePlaybackMedia(ctx context.Context, task Task) (providerMedia, []byte, error) {
	if isHuangguoProviderSource(sourceFromDramaID(task.DramaID)) || isHuangguoProviderSource(task.Chapter.Source) || task.Chapter.PageURL != "" || isProviderHTTPMediaURL(task.Chapter.VideoURL) || strings.HasPrefix(task.Chapter.VideoURL, "hongguo-cenc://") {
		media, err := downloader.resolveProviderMedia(ctx, task)
		return media, nil, err
	}
	if task.Chapter.VideoURL == "" {
		return providerMedia{}, nil, errors.New("此分集没有可用的播放地址")
	}
	var key []byte
	if downloader.cfg.AESKeyHex != "" {
		var err error
		key, err = hex.DecodeString(downloader.cfg.AESKeyHex)
		if err != nil || len(key) != aes.BlockSize {
			return providerMedia{}, nil, errors.New("aesKeyHex 必须是 16 字节 AES 密钥的 hex 编码")
		}
	}
	base, err := downloader.apiEndpoint(ctx)
	if err != nil {
		return providerMedia{}, nil, err
	}
	access, err := downloader.legacyCredentials(ctx)
	if err != nil {
		return providerMedia{}, nil, err
	}
	mediaURL := fmt.Sprintf("%s/api/app/vid/h5/m3u8/%s?token=%s&c=%s", base, strings.TrimLeft(task.Chapter.VideoURL, "/"), url.QueryEscape(access.Token), url.QueryEscape(downloader.cfg.CDNURL))
	playlist, finalURL, err := downloader.fetchRaw(ctx, mediaURL)
	if err != nil {
		return providerMedia{}, nil, err
	}
	if !strings.HasPrefix(strings.TrimSpace(playlist), "#EXTM3U") {
		return providerMedia{}, nil, errors.New("站点未返回有效的播放列表")
	}
	return providerMedia{URL: finalURL, Playlist: playlist, Duration: m3u8Duration(playlist), Referer: legacyFrontendURL + "/"}, key, nil
}
