// Bounded metadata reuse adapted from hongguoTV ContentRepository.streamLadder.
// GPL-3.0-only; see native/core/UPSTREAM.md for the pinned reference.
package app

import (
	"context"
	"encoding/json"
	"strings"
	"time"
)

const (
	hongguoModelLookahead  = 2
	hongguoModelCacheLimit = 6
	hongguoModelMaxBytes   = 256 * 1024
	hongguoModelTTL        = time.Minute
)

type hongguoMetadataAheadKey struct{}

type hongguoUpcomingModel struct {
	entry     json.RawMessage
	expiresAt time.Time
}

// Hints carry a count, not IDs supplied by the UI. Only a fresh, previously
// validated detail response can establish the adjacent episodes of this series.
func (downloader *Downloader) hongguoUpcomingVideoIDs(ctx context.Context, seriesID, videoID string) []string {
	count, _ := ctx.Value(hongguoMetadataAheadKey{}).(int)
	if count <= 0 || count > hongguoModelLookahead {
		return nil
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	detail, found := client.details[seriesID]
	if !found || !time.Now().Before(detail.ExpiresAt) {
		return nil
	}
	for index, chapter := range detail.Chapters {
		if chapter.VideoURL != "hongguo-cenc://"+videoID {
			continue
		}
		ids := make([]string, 0, count)
		for _, next := range detail.Chapters[index+1:] {
			id := strings.TrimPrefix(next.VideoURL, "hongguo-cenc://")
			if !hongguoNumericID.MatchString(id) {
				break
			}
			ids = append(ids, id)
			if len(ids) == count {
				break
			}
		}
		return ids
	}
	return nil
}

// Entries leave the cache on first use, so a retry obtains fresh URLs/keys.
func (downloader *Downloader) takeHongguoUpcomingModel(videoID string) json.RawMessage {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	client.expireHongguoUpcomingModels(time.Now())
	entry := client.upcomingModels[videoID]
	delete(client.upcomingModels, videoID)
	return entry.entry
}

func (client *hongguoAppClient) expireHongguoUpcomingModels(now time.Time) {
	for id, entry := range client.upcomingModels {
		if !now.Before(entry.expiresAt) {
			delete(client.upcomingModels, id)
		}
	}
}

func (downloader *Downloader) keepHongguoUpcomingModels(result map[string]any, ids []string) {
	entries := make(map[string]json.RawMessage, len(ids))
	for _, id := range ids {
		entry := nestedMap(result, "data", id)
		body, err := json.Marshal(entry)
		if err != nil || len(body) > hongguoModelMaxBytes {
			continue
		}
		if _, err := parseHongguoAppMedia(entry); err != nil {
			continue
		}
		entries[id] = body
	}
	if len(entries) == 0 {
		return
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	now := time.Now()
	client.expireHongguoUpcomingModels(now)
	if client.upcomingModels == nil {
		client.upcomingModels = make(map[string]hongguoUpcomingModel)
	}
	for id, entry := range entries {
		client.upcomingModels[id] = hongguoUpcomingModel{entry: entry, expiresAt: now.Add(hongguoModelTTL)}
	}
	for len(client.upcomingModels) > hongguoModelCacheLimit {
		oldestID := ""
		var oldest time.Time
		for id, entry := range client.upcomingModels {
			if oldestID == "" || entry.expiresAt.Before(oldest) || entry.expiresAt.Equal(oldest) && id < oldestID {
				oldestID, oldest = id, entry.expiresAt
			}
		}
		delete(client.upcomingModels, oldestID)
	}
}
