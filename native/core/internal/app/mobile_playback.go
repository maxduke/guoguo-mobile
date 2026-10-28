package app

import (
	"context"
	"encoding/hex"
	"errors"
	"sort"
	"time"
)

type mobilePlaybackChoice struct {
	media            []providerMedia
	key              []byte
	qualities        []int
	index            int
	created          time.Time
	prefetchCanceled bool
}

func mobilePlaybackChoices(media providerMedia, key []byte, quality int) (mobilePlaybackChoice, error) {
	choice := mobilePlaybackChoice{key: key, created: time.Now(), qualities: []int{}}
	seen, qualities := map[string]bool{}, map[int]bool{}
	for _, option := range append([]providerMedia{media}, media.Variants...) {
		if option.Quality > 0 {
			qualities[option.Quality] = true
		}
		if !isProviderHTTPMediaURL(option.URL) {
			continue
		}
		identity := option.URL + "\x00" + option.Referer + "\x00" + hex.EncodeToString(option.CENCKey) + "\x00" + hex.EncodeToString(option.HLSKey)
		if seen[identity] {
			continue
		}
		seen[identity] = true
		option.Variants = nil
		if quality == 0 || option.Quality == quality {
			choice.media = append(choice.media, option)
		}
	}
	for value := range qualities {
		choice.qualities = append(choice.qualities, value)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(choice.qualities)))
	// Stable ordering tries equal-quality alternatives before lower qualities.
	sort.SliceStable(choice.media, func(i, j int) bool { return choice.media[i].Quality > choice.media[j].Quality })
	if len(choice.media) == 0 {
		return choice, errors.New("没有所选清晰度的可用播放线路")
	}
	return choice, nil
}

func (c *MobileClient) openMobilePlayback(choice mobilePlaybackChoice) (map[string]any, error) {
	return c.openMobilePlaybackContext(context.Background(), choice)
}

func (c *MobileClient) openMobilePlaybackContext(ctx context.Context, choice mobilePlaybackChoice) (map[string]any, error) {
	if choice.index < 0 || choice.index >= len(choice.media) {
		return nil, errors.New("没有其他可用播放线路")
	}
	media := choice.media[choice.index]
	var proxy *hlsProxy
	if media.certificateFallback || media.credentials != nil || media.Playlist != "" || len(choice.key) > 0 || len(media.HLSKey) > 0 {
		var err error
		proxy, err = c.downloader.newHLSProxy(context.Background(), media, choice.key)
		if err != nil {
			return nil, err
		}
	}
	session := randomHex(16)
	choice.prefetchCanceled = false
	c.mu.Lock()
	if c.closed || ctx.Err() != nil {
		err := ctx.Err()
		if err == nil {
			err = context.Canceled
		}
		c.mu.Unlock()
		if proxy != nil {
			proxy.Close()
		}
		return nil, err
	}
	if c.playbacks == nil {
		c.playbacks = make(map[string]mobilePlaybackChoice)
	}
	if len(c.playbacks) >= 8 {
		c.mu.Unlock()
		if proxy != nil {
			proxy.Close()
		}
		return nil, errors.New("播放会话过多，请关闭已有播放器")
	}
	c.playbacks[session] = choice
	if proxy != nil {
		c.proxies[session] = proxy
	}
	c.mu.Unlock()
	return mobilePlaybackResult(session, choice, proxy), nil
}

func mobilePlaybackResult(session string, choice mobilePlaybackChoice, proxy *hlsProxy) map[string]any {
	media := choice.media[choice.index]
	playURL := media.URL
	if proxy != nil {
		playURL = proxy.root
	}
	expires := int64(0)
	if media.credentials != nil && !media.credentials.expires.IsZero() {
		expires = media.credentials.expires.UnixMilli()
	}
	return map[string]any{
		"expiresAt": expires,
		"url":       playURL, "remoteUrl": media.URL, "session": session,
		"headers": map[string]string{"Referer": media.Referer, "User-Agent": userAgent},
		"quality": media.Quality, "qualities": choice.qualities,
		"hls": media.Playlist != "", "castDirect": proxy == nil && len(media.CENCKey) == 0,
		"contentKey": hex.EncodeToString(media.CENCKey),
		"routeIndex": choice.index, "routeCount": len(choice.media),
	}
}
