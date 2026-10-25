package app

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"maps"
	"strings"
	"time"
)

const (
	mobileSeasonPageQueries = 4
	mobileSeasonQueryLimit  = 32
	mobileSeasonResultLimit = 200
	mobileSeasonCursorLimit = 64
	mobileSeasonCursorBytes = 256 * 1024
	mobileSeasonPageTimeout = 10 * time.Second
	mobileSeasonCursorTTL   = 20 * time.Minute
)

// Published cursors are immutable. Replaying a page or canceling one owner never
// advances another owner's probes, even when both owners search the same title.
type mobileSeasonCursor struct {
	query     string
	page      int
	entry     hongguoSearchEntry
	groups    []mobileSeasonGroup
	attempted map[string]bool
	requests  int
	expires   time.Time
}

type mobileSeasonGroup struct {
	series     *hongguoSearchSeries
	nextSeason int
	misses     int
	done       bool
}

type mobileSeasonProbe struct {
	group     int
	query     string
	extension bool
	season    int
}

func (cursor *mobileSeasonCursor) clone() *mobileSeasonCursor {
	copy := *cursor
	copy.entry = cloneHongguoSearchEntry(cursor.entry)
	copy.attempted = maps.Clone(cursor.attempted)
	copy.groups = append([]mobileSeasonGroup(nil), cursor.groups...)
	for index := range copy.groups {
		series := *cursor.groups[index].series
		series.known = maps.Clone(series.known)
		series.labels = maps.Clone(series.labels)
		copy.groups[index].series = &series
	}
	return &copy
}

func (cursor *mobileSeasonCursor) nextProbe() (mobileSeasonProbe, bool) {
	// Known gaps take priority over looking beyond the highest known season.
	for index, group := range cursor.groups {
		if query := group.series.nextQuery(cursor.attempted); query != "" {
			return mobileSeasonProbe{group: index, query: query}, true
		}
	}
	for index, group := range cursor.groups {
		if group.done {
			continue
		}
		query := group.series.extensionQuery(group.nextSeason, cursor.attempted)
		if query != "" {
			_, season, _, _ := hongguoSearchSeason(query)
			return mobileSeasonProbe{group: index, query: query, extension: true, season: season}, true
		}
	}
	return mobileSeasonProbe{}, false
}

func (cursor *mobileSeasonCursor) accept(probe mobileSeasonProbe, dramas []Drama) {
	cursor.attempted[probe.query] = true
	cursor.requests++
	group := &cursor.groups[probe.group]
	maximum := group.series.maximum
	var matches []Drama
	for _, drama := range dramas {
		if group.series.add(drama) {
			matches = append(matches, drama)
		}
	}
	cursor.entry.Dramas = mergeHongguoSearchDramas(cursor.entry.Dramas, matches)
	if group.series.maximum > maximum {
		group.nextSeason, group.misses = group.series.maximum+1, 0
		group.done = false
	} else if probe.extension && probe.season > 0 {
		// Count a missing season only after both Chinese and numeric forms have
		// been checked. Empty pages still leave later known gaps searchable.
		next := group.series.extensionQuery(group.nextSeason, cursor.attempted)
		_, season, _, _ := hongguoSearchSeason(next)
		if next == "" || season > probe.season {
			group.nextSeason = probe.season + 1
			group.misses++
			group.done = group.misses >= hongguoSearchSeasonExtensionMisses
		}
	}
}

// Website pages can reveal a new series or a later known season. Preserve the
// existing probe history while updating gaps and extension starting points.
func (cursor *mobileSeasonCursor) mergeResults(dramas []Drama) {
	cursor.entry.Dramas = mergeHongguoSearchDramas(cursor.entry.Dramas, dramas)
	for _, series := range hongguoSearchSeriesGroups(cursor.query, cursor.entry.Dramas, true) {
		found := false
		for index := range cursor.groups {
			group := &cursor.groups[index]
			if group.series.key == series.key && group.series.unit == series.unit {
				if series.maximum > group.series.maximum {
					group.nextSeason, group.misses, group.done = series.maximum+1, 0, false
				}
				group.series = series
				found = true
				break
			}
		}
		if !found {
			cursor.groups = append(cursor.groups, mobileSeasonGroup{series: series, nextSeason: series.maximum + 1})
		}
	}
}

func (c *MobileClient) searchHongguoPage(ctx context.Context, request mobileRequest, read *mobileSearchRead) (map[string]any, error) {
	query, err := hongguoSearchKeyword(request.Query)
	if err != nil {
		return nil, err
	}
	page := max(1, request.Page)
	var cursor *mobileSeasonCursor
	if request.Continuation == "" && page == 1 {
		entry, err := c.downloader.searchHongguoProgress(ctx, query, func(entry hongguoSearchEntry) {
			c.updateSearch(request.RequestID, read, map[string]any{"items": mobileDramas(entry.Dramas), "limited": true, "total": entry.Total}, false)
		}, false)
		if err != nil {
			return nil, err
		}
		cursor = &mobileSeasonCursor{query: query, entry: entry, attempted: map[string]bool{query: true}}
		for _, series := range hongguoSearchSeriesGroups(query, entry.Dramas, true) {
			cursor.groups = append(cursor.groups, mobileSeasonGroup{series: series, nextSeason: series.maximum + 1})
		}
	} else {
		c.mu.Lock()
		saved := c.seasonCursors[request.Continuation]
		if saved != nil && saved.query == query && saved.page+1 == page && time.Now().Before(saved.expires) {
			cursor = saved.clone()
		}
		c.mu.Unlock()
		if cursor == nil {
			return map[string]any{"items": []any{}, "limited": true, "restartRequired": true, "warning": "续搜已过期，请重新搜索"}, nil
		}
	}
	cursor.page = page
	warning := ""
	if page > 1 {
		probeCtx, cancel := context.WithTimeout(ctx, mobileSeasonPageTimeout)
		defer cancel()
		cursor.entry.Warning = ""
		used := 0
		if cursor.entry.WebsiteMore {
			used++
			website, err := c.downloader.fetchHongguoSearchPage(probeCtx, query, cursor.entry.WebsitePage+1)
			if err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				warning = "综合搜索续页暂未完成，已保留结果，可继续加载"
			} else {
				cursor.entry.WebsitePage, cursor.entry.WebsiteMore = website.WebsitePage, website.WebsiteMore
				cursor.entry.Total = max(cursor.entry.Total, website.Total)
				cursor.mergeResults(website.Dramas)
			}
		}
		if cursor.entry.NamesPending {
			used++
			names, err := c.downloader.fetchHongguoSearchNames(probeCtx, query)
			if err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				warning = strings.Trim(warning+"；名称检索暂未完成，已保留结果，可继续加载", "；")
			} else {
				cursor.entry.NamesPending = false
				cursor.mergeResults(names)
			}
		}
		for ; used < mobileSeasonPageQueries && cursor.requests < mobileSeasonQueryLimit; used++ {
			probe, ok := cursor.nextProbe()
			if !ok || len(cursor.entry.Dramas) >= mobileSeasonResultLimit {
				break
			}
			names, err := c.downloader.fetchHongguoSearchNames(probeCtx, probe.query)
			if err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				// Do not consume a failed probe; the next page can retry it.
				warning = strings.Trim(warning+"；分季续搜暂未完成，已保留结果，可继续查找", "；")
				break
			}
			cursor.accept(probe, names)
			c.updateSearch(request.RequestID, read, map[string]any{"items": mobileDramas(cursor.entry.Dramas), "limited": true, "total": max(cursor.entry.Total, len(cursor.entry.Dramas))}, false)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	_, pending := cursor.nextProbe()
	more := (cursor.entry.WebsiteMore || cursor.entry.NamesPending || pending && cursor.requests < mobileSeasonQueryLimit) && page < 200 && len(cursor.entry.Dramas) < mobileSeasonResultLimit
	limited := cursor.entry.Limited || pending || warning != ""
	for _, group := range cursor.groups {
		limited = limited || len(group.series.known) < group.series.maximum
	}
	if len(cursor.entry.Dramas) > mobileSeasonResultLimit {
		cursor.entry.Dramas = cursor.entry.Dramas[:mobileSeasonResultLimit]
		limited = true
	}
	if (pending || cursor.entry.WebsiteMore || cursor.entry.NamesPending) && !more {
		warning = "本次查找已达上限，可用完整剧名继续搜索"
	}
	continuation := ""
	if more {
		continuation, err = c.rememberSeasonCursor(ctx, cursor)
		if err != nil {
			return nil, err
		}
		if continuation == "" {
			more, limited = false, true
			warning = "搜索结果已达保存上限，可用完整剧名继续搜索"
		}
	}
	if cursor.entry.Warning != "" {
		warning = cursor.entry.Warning
	}
	return map[string]any{"items": mobileDramas(cursor.entry.Dramas), "total": max(cursor.entry.Total, len(cursor.entry.Dramas)), "limited": limited, "warning": warning, "hasMore": more, "continuation": continuation}, nil
}

func (c *MobileClient) rememberSeasonCursor(ctx context.Context, cursor *mobileSeasonCursor) (string, error) {
	metadata, err := json.Marshal(cursor.entry)
	if err != nil || len(metadata) > mobileSeasonCursorBytes {
		return "", err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", errors.New("暂时无法保存续搜状态，请重新搜索")
	}
	token := base64.RawURLEncoding.EncodeToString(nonce[:])
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if c.seasonCursors == nil {
		c.seasonCursors = map[string]*mobileSeasonCursor{}
	}
	for token, saved := range c.seasonCursors {
		if !time.Now().Before(saved.expires) {
			delete(c.seasonCursors, token)
		}
	}
	if len(c.seasonCursors) >= mobileSeasonCursorLimit {
		oldest := ""
		for token, saved := range c.seasonCursors {
			if oldest == "" || saved.expires.Before(c.seasonCursors[oldest].expires) {
				oldest = token
			}
		}
		delete(c.seasonCursors, oldest)
	}
	cursor.expires = time.Now().Add(mobileSeasonCursorTTL)
	c.seasonCursors[token] = cursor
	return token, nil
}
