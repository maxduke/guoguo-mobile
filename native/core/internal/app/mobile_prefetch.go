package app

import (
	"context"
	"errors"
	"time"
)

type mobilePrefetchRead struct {
	cancel context.CancelFunc
	done   chan struct{}
	stats  mediaPrefetchStats
}

func (c *MobileClient) prefetchPlayback(ctx context.Context, session string) (map[string]any, error) {
	c.mu.Lock()
	choice, exists := c.playbacks[session]
	if !exists || time.Since(choice.created) >= 2*time.Minute || choice.index < 0 || choice.index >= len(choice.media) {
		c.mu.Unlock()
		return nil, errors.New("播放会话已过期，请重新解析")
	}
	media := choice.media[choice.index]
	if media.credentials != nil && !media.credentials.expires.IsZero() && !time.Now().Add(5*time.Second).Before(media.credentials.expires) {
		c.mu.Unlock()
		return nil, errors.New("播放授权即将过期，请重新解析")
	}
	proxy := c.proxies[session]
	if choice.prefetchCanceled {
		result := mobilePlaybackResult(session, choice, proxy)
		result["prefetchedBytes"] = 0
		c.mu.Unlock()
		return result, nil
	}
	if proxy == nil {
		var err error
		proxy, err = c.downloader.newHLSProxy(context.Background(), media, choice.key)
		if err != nil {
			c.mu.Unlock()
			return nil, err
		}
		if c.proxies == nil {
			c.proxies = make(map[string]*hlsProxy)
		}
		c.proxies[session] = proxy
	}
	if c.prefetches == nil {
		c.prefetches = make(map[string]*mobilePrefetchRead)
	}
	read := c.prefetches[session]
	owner := read == nil
	var warming context.Context
	if owner {
		var cancel context.CancelFunc
		warming, cancel = context.WithTimeout(proxy.ctx, mediaPrefetchTimeout)
		read = &mobilePrefetchRead{cancel: cancel, done: make(chan struct{})}
		c.prefetches[session] = read
	}
	c.mu.Unlock()
	if owner {
		stop := context.AfterFunc(ctx, read.cancel)
		read.stats = proxy.prefetch(warming, media.Quality, mediaPrefetchBytes)
		stop()
		read.cancel()
		close(read.done)
	} else {
		select {
		case <-read.done:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	c.mu.Lock()
	current, exists := c.playbacks[session]
	c.mu.Unlock()
	if !exists {
		return nil, errors.New("播放会话已释放")
	}
	if time.Since(current.created) >= 2*time.Minute {
		return nil, errors.New("播放会话已过期，请重新解析")
	}
	credentials := current.media[current.index].credentials
	if credentials != nil && !credentials.expires.IsZero() && !time.Now().Add(5*time.Second).Before(credentials.expires) {
		return nil, errors.New("播放授权即将过期，请重新解析")
	}
	result := mobilePlaybackResult(session, current, proxy)
	result["prefetchedBytes"], result["prefetchMs"] = read.stats.cached, read.stats.millis
	return result, nil
}
func (c *MobileClient) cancelPlaybackPrefetch(session string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if choice, ok := c.playbacks[session]; ok {
		choice.prefetchCanceled = true
		c.playbacks[session] = choice
	}
	if read := c.prefetches[session]; read != nil {
		read.cancel()
	}
}
