package app

import (
	"context"
	"errors"
	"time"
)

// Also covers cancellation arriving while Android is still dispatching a call.
const mobileCancellationRetention = 75 * time.Second

type mobileResolveRead struct {
	drama, chapter string
	cancel         context.CancelFunc
}

type mobileResolveCancellation struct {
	drama, chapter string
	expires        time.Time
}

func (c *MobileClient) beginResolve(ctx context.Context, request mobileRequest) (context.Context, func(), error) {
	if request.RequestID == "" { // Older clients retain their bounded call lifetime.
		return ctx, func() {}, nil
	}
	if !diagnosticID.MatchString(request.RequestID) {
		return ctx, nil, errors.New("播放请求标识无效")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return ctx, nil, context.Canceled
	}
	for id, old := range c.canceledResolves {
		if time.Now().After(old.expires) {
			delete(c.canceledResolves, id)
		}
	}
	if old, ok := c.canceledResolves[request.RequestID]; ok && old.drama == request.ID && old.chapter == request.Chapter.ID {
		return ctx, nil, context.Canceled
	}
	if c.resolveReads == nil {
		c.resolveReads = map[string]*mobileResolveRead{}
	}
	if c.resolveReads[request.RequestID] != nil || len(c.resolveReads) >= 8 {
		return ctx, nil, errors.New("播放请求过多，请稍后重试")
	}
	ctx, cancel := context.WithCancel(ctx)
	read := &mobileResolveRead{drama: request.ID, chapter: request.Chapter.ID, cancel: cancel}
	c.resolveReads[request.RequestID] = read
	return ctx, func() {
		cancel()
		c.mu.Lock()
		if c.resolveReads[request.RequestID] == read {
			delete(c.resolveReads, request.RequestID)
		}
		c.mu.Unlock()
	}, nil
}

func (c *MobileClient) cancelResolve(request mobileRequest) {
	if !diagnosticID.MatchString(request.RequestID) || request.ID == "" || request.Chapter.ID == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if c.canceledResolves == nil {
		c.canceledResolves = map[string]mobileResolveCancellation{}
	}
	if len(c.canceledResolves) >= 64 {
		oldestID := ""
		var oldest time.Time
		for id, old := range c.canceledResolves {
			if oldestID == "" || old.expires.Before(oldest) {
				oldestID, oldest = id, old.expires
			}
		}
		delete(c.canceledResolves, oldestID)
	}
	c.canceledResolves[request.RequestID] = mobileResolveCancellation{drama: request.ID, chapter: request.Chapter.ID, expires: time.Now().Add(mobileCancellationRetention)}
	if read := c.resolveReads[request.RequestID]; read != nil && read.drama == request.ID && read.chapter == request.Chapter.ID {
		read.cancel()
	}
}
