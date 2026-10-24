package app

import (
	"context"
	"errors"
	"maps"
	"strconv"
)

// Only conflicting pages share a gate. Waiting respects the bridge deadline;
// library snapshots use their own short gate and never cover remote requests.
func (c *MobileClient) lockCatalog(ctx context.Context, key string) (func(), error) {
	c.mu.Lock()
	if c.catalogGates == nil {
		c.catalogGates = map[string]chan struct{}{}
	}
	gate := c.catalogGates[key]
	if gate == nil {
		gate = make(chan struct{}, 1)
		c.catalogGates[key] = gate
	}
	c.mu.Unlock()
	select {
	case gate <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-gate
			return nil, err
		}
		return func() { <-gate }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (c *MobileClient) aggregateCatalog(ctx context.Context, request mobileRequest) (map[string]any, error) {
	if request.Source != sourceHongguo && request.Source != sourceHuangdou && request.Source != "huangguo" {
		return nil, errors.New("未知站源")
	}
	if request.Page < 0 || request.Page > 200 && request.Source != sourceHongguo {
		return nil, errors.New("页码超出范围")
	}
	unlock, err := c.lockCatalog(ctx, request.Source)
	if err != nil {
		return nil, publicError(err)
	}
	defer unlock()

	if request.Source == "huangguo" {
		return c.huangguoCatalogPage(ctx, request)
	}
	var rows []Drama
	more := false
	if request.Source == sourceHongguo {
		unlockSnapshot, lockErr := c.lockCatalog(ctx, "library")
		if lockErr != nil {
			return nil, publicError(lockErr)
		}
		known := append([]Drama(nil), c.known...)
		unlockSnapshot()
		ctx = withKnownHongguoDramas(ctx, known)
		if request.Page > 1 {
			ctx = context.WithValue(ctx, libraryMoreKey{}, true)
		}
		previousState := c.downloader.hongguoCatalogSnapshot()
		rows, err = c.downloader.fetchHongguoDramas(ctx)
		state := c.downloader.hongguoCatalogSnapshot()
		more = hongguoCatalogHasMore(state)
		if ctx.Err() != nil {
			c.rollbackCatalogPage(previousState)
			return nil, publicError(ctx.Err())
		}
		unlockSnapshot, saveErr := c.lockCatalog(ctx, "library")
		if saveErr == nil {
			c.hongguoState = state
			byID := make(map[string]Drama, len(c.known)+len(rows))
			for _, batch := range [][]Drama{c.known, rows} {
				for _, row := range batch {
					byID[row.ID] = row
				}
			}
			c.known = make([]Drama, 0, len(byID))
			for _, row := range byID {
				c.known = append(c.known, row)
			}
			saveErr = c.saveLibraryCache()
			unlockSnapshot()
		} else {
			c.rollbackCatalogPage(previousState)
		}
		err = errors.Join(err, saveErr)
	} else if request.Page > 1 {
		client := newHuangdouAPIClient(c.downloader)
		var decoded any
		err = client.call(ctx, "/drama/list", map[string]any{"page": strconv.Itoa(request.Page), "page_size": "50"}, &decoded)
		if err == nil {
			for _, item := range huangdouList(decoded) {
				if drama := huangdouDramaFromMap(item); drama.ID != "" {
					rows = append(rows, drama)
				}
			}
		}
	} else {
		rows, err = c.downloader.fetchAllDramas(ctx, request.Source)
	}
	if ctx.Err() != nil {
		return nil, publicError(ctx.Err())
	}
	if request.Source == sourceHuangdou {
		more = len(rows) > 0 && request.Page < 200
	}
	return mobileCatalogResult(rows, more, err, "available")
}

func (c *MobileClient) huangguoCatalogPage(ctx context.Context, request mobileRequest) (map[string]any, error) {
	page := max(1, request.Page)
	unlock, err := c.lockCatalog(ctx, "library")
	if err != nil {
		return nil, publicError(err)
	}
	cursors := maps.Clone(c.huangguo)
	unlock()
	if page == 1 || cursors == nil {
		cursors = map[string]mobileHuangguoCursor{}
	}
	rows, more, err := c.downloader.mobileHuangguoCatalog(context.WithValue(ctx, providerTextNoCacheKey{}, true), page, cursors)
	if ctx.Err() != nil {
		return nil, publicError(ctx.Err())
	}
	unlock, saveErr := c.lockCatalog(ctx, "library")
	if saveErr == nil {
		c.huangguo = cursors
		saveErr = c.saveLibraryCache()
		unlock()
	}
	result, resultErr := mobileCatalogResult(rows, more && page < 200, errors.Join(err, saveErr), "page")
	if result != nil {
		result["page"] = page
	}
	return result, resultErr
}

// Caller owns the library gate, so writes always include both sources' latest
// committed state even if their network requests complete in reverse order.
func (c *MobileClient) saveLibraryCache() error {
	return writeLibraryCache(c.downloader.cfg.dataDirectory(), libraryCache{
		HongguoApp: c.hongguoState, Dramas: c.known, Huangguo: c.huangguo,
	})
}

// The source gate is still held. Keep a canceled partial scan from advancing
// offsets past rows that were never committed to this client's known library.
func (c *MobileClient) rollbackCatalogPage(previous *hongguoCatalogState) {
	client := c.downloader.hongguoClient()
	client.mu.Lock()
	client.state.Feeds = maps.Clone(previous.Feeds)
	client.mu.Unlock()
}

func mobileCatalogResult(rows []Drama, more bool, err error, scope string) (map[string]any, error) {
	warning := ""
	if err != nil {
		if len(rows) == 0 {
			return nil, publicError(err)
		}
		warning = publicError(err).Error()
	}
	return map[string]any{"items": mobileDramas(rows), "hasMore": more, "warning": warning, "catalogScope": scope}, nil
}
