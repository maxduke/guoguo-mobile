package app

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strings"
)

// Sniff ambiguous URLs with a bounded range read; never buffer an entire MP4.
func (d *Downloader) prepareMobileMedia(ctx context.Context, media providerMedia) (providerMedia, error) {
	if media.certificateFallback && media.certificateOrigin == "" {
		media.certificateOrigin = media.URL
	}
	if media.Playlist != "" {
		return media, nil
	}
	parsed, err := url.Parse(media.URL)
	if err != nil {
		return media, err
	}
	extension := strings.ToLower(path.Ext(parsed.Path))
	isPlaylist := extension == ".m3u8"
	if !isPlaylist && extension != ".mp4" && extension != ".m4v" && extension != ".mov" && extension != ".ts" {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, media.URL, nil)
		if err != nil {
			return media, err
		}
		request.Header.Set("Range", "bytes=0-511")
		request.Header.Set("Referer", media.Referer)
		request.Header.Set("User-Agent", userAgent)
		request.Header.Set("Accept-Encoding", "identity")
		client := mediaHTTPClient(d.client, media)
		if media.certificateFallback {
			defer client.CloseIdleConnections()
		}
		if media.credentials != nil {
			if err := media.credentials.apply(request); err != nil {
				return media, err
			}
			client = media.credentials.client(client)
		}
		response, err := client.Do(request)
		if err != nil {
			return media, err
		}
		prefix, readErr := io.ReadAll(io.LimitReader(response.Body, 512))
		response.Body.Close()
		if readErr != nil {
			return media, readErr
		}
		if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
			return media, fmt.Errorf("媒体源 HTTP %d", response.StatusCode)
		}
		isPlaylist = strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(string(prefix), "\ufeff")), "#EXTM3U")
		if response.Request != nil && response.Request.URL != nil && isPlaylist {
			media.URL = response.Request.URL.String()
		}
	}
	if isPlaylist {
		client := mediaHTTPClient(d.client, media)
		if media.certificateFallback {
			defer client.CloseIdleConnections()
		}
		playlistCtx := providerMediaContext(ctx, media.credentials)
		text, finalURL, err := d.fetchMediaPlaylistWithClient(playlistCtx, media.URL, media.Referer, client)
		if err != nil {
			return media, err
		}
		media.Playlist, media.URL = text, finalURL
		media.Duration = m3u8Duration(text)
	}
	return media, nil
}

func (c *MobileClient) prepareMobileChoice(ctx context.Context, choice mobilePlaybackChoice) (mobilePlaybackChoice, error) {
	var lastErr error
	quality := choice.media[choice.index].Quality
	for index := choice.index; index < len(choice.media); index++ {
		if choice.media[index].Quality != quality {
			continue
		}
		media, err := c.downloader.prepareMobileMedia(ctx, choice.media[index])
		if err == nil {
			choice.media[index], choice.index = media, index
			return choice, nil
		}
		lastErr = err
		if ctx.Err() != nil {
			return choice, ctx.Err()
		}
	}
	return choice, lastErr
}
