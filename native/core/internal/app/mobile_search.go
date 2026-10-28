package app

import (
	"context"
	"errors"
	"strings"
	"time"
)

type mobileCanceledRead struct {
	source, query string
	expires       time.Time
}

type mobileSearchRead struct {
	source, query string
	cancel        context.CancelFunc
	updated       time.Time
	value         map[string]any
	done          bool
}

func (c *MobileClient) beginSearch(ctx context.Context, request mobileRequest) (context.Context, *mobileSearchRead, error) {
	if request.RequestID == "" {
		return ctx, nil, nil
	}
	if len(request.RequestID) > 128 {
		return ctx, nil, errors.New("搜索请求标识过长")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for id, canceled := range c.canceledSearches {
		if time.Now().After(canceled.expires) {
			delete(c.canceledSearches, id)
		}
	}
	if canceled, exists := c.canceledSearches[request.RequestID]; exists && canceled.source == request.Source && canceled.query == strings.TrimSpace(request.Query) {
		return ctx, nil, context.Canceled
	}
	if c.searches == nil {
		c.searches = map[string]*mobileSearchRead{}
	}
	for id, old := range c.searches {
		if time.Since(old.updated) > 2*time.Minute {
			old.cancel()
			delete(c.searches, id)
		}
	}
	if old := c.searches[request.RequestID]; old != nil {
		old.cancel()
		delete(c.searches, request.RequestID)
	}
	if len(c.searches) >= 16 {
		return ctx, nil, errors.New("搜索请求过多，请稍后重试")
	}
	ctx, cancel := context.WithCancel(ctx)
	read := &mobileSearchRead{source: request.Source, query: strings.TrimSpace(request.Query), cancel: cancel, updated: time.Now(), value: map[string]any{"items": []any{}}}
	c.searches[request.RequestID] = read
	return ctx, read, nil
}
func (c *MobileClient) updateSearch(id string, read *mobileSearchRead, value map[string]any, done bool) {
	if read == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.searches[id] != read {
		return
	}
	read.value, read.done, read.updated = value, done, time.Now()
}
func (c *MobileClient) searchProgress(request mobileRequest, cancel bool) map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	read := c.searches[request.RequestID]
	if cancel && request.RequestID != "" && len(request.RequestID) <= 128 {
		if c.canceledSearches == nil {
			c.canceledSearches = map[string]mobileCanceledRead{}
		}
		if len(c.canceledSearches) >= 32 {
			for id, canceled := range c.canceledSearches {
				if time.Now().After(canceled.expires) {
					delete(c.canceledSearches, id)
				}
			}
			if len(c.canceledSearches) >= 32 {
				for id := range c.canceledSearches {
					delete(c.canceledSearches, id)
					break
				}
			}
		}
		c.canceledSearches[request.RequestID] = mobileCanceledRead{source: request.Source, query: strings.TrimSpace(request.Query), expires: time.Now().Add(mobileCancellationRetention)}
	}
	if read == nil || read.source != request.Source || read.query != strings.TrimSpace(request.Query) {
		return map[string]any{"items": []any{}, "done": true}
	}
	if cancel {
		read.cancel()
		delete(c.searches, request.RequestID)
		return map[string]any{"done": true}
	}
	result := make(map[string]any, len(read.value)+3)
	for key, value := range read.value {
		result[key] = value
	}
	result["done"], result["source"], result["query"] = read.done, read.source, read.query
	return result
}
