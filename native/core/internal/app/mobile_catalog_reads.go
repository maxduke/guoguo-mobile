package app

import (
	"context"
	"errors"
	"time"
)

type mobileCatalogRead struct {
	source, category string
	page             int
	cancel           context.CancelFunc
}

type mobileCatalogCancellation struct {
	source, category string
	page             int
	expires          time.Time
}

func (c *MobileClient) beginCatalogRead(ctx context.Context, request mobileRequest) (context.Context, func(), error) {
	if !request.Background {
		return ctx, func() {}, nil
	}
	if _, supported := c.downloader.mobileSource(request.Source); !supported {
		return ctx, nil, errors.New("聚合目录使用按需加载")
	}
	if !diagnosticID.MatchString(request.RequestID) {
		return ctx, nil, errors.New("缺少目录预取请求标识")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return ctx, nil, context.Canceled
	}
	for id, old := range c.canceledCatalogs {
		if time.Now().After(old.expires) {
			delete(c.canceledCatalogs, id)
		}
	}
	if old, exists := c.canceledCatalogs[request.RequestID]; exists && old.source == request.Source && old.category == request.Category && old.page == request.Page {
		return ctx, nil, context.Canceled
	}
	if c.catalogReads == nil {
		c.catalogReads = map[string]*mobileCatalogRead{}
	}
	if c.catalogReads[request.RequestID] != nil || len(c.catalogReads) >= 8 {
		return ctx, nil, errors.New("目录预取请求过多")
	}
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, backgroundCatalogKey{}, true), 8*time.Second)
	read := &mobileCatalogRead{source: request.Source, category: request.Category, page: request.Page, cancel: cancel}
	c.catalogReads[request.RequestID] = read
	return ctx, func() {
		cancel()
		c.mu.Lock()
		if c.catalogReads[request.RequestID] == read {
			delete(c.catalogReads, request.RequestID)
		}
		c.mu.Unlock()
	}, nil
}

func (c *MobileClient) cancelCatalogRead(request mobileRequest) {
	if !diagnosticID.MatchString(request.RequestID) {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if c.canceledCatalogs == nil {
		c.canceledCatalogs = map[string]mobileCatalogCancellation{}
	}
	if len(c.canceledCatalogs) >= 32 {
		oldestID := ""
		var oldest time.Time
		for id, value := range c.canceledCatalogs {
			if oldestID == "" || value.expires.Before(oldest) {
				oldestID, oldest = id, value.expires
			}
		}
		delete(c.canceledCatalogs, oldestID)
	}
	c.canceledCatalogs[request.RequestID] = mobileCatalogCancellation{source: request.Source, category: request.Category, page: request.Page, expires: time.Now().Add(mobileCancellationRetention)}
	if read := c.catalogReads[request.RequestID]; read != nil && read.source == request.Source && read.category == request.Category && read.page == request.Page {
		read.cancel()
	}
}
