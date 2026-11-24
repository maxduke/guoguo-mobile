package app

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

const hppPageSize = 24

type hppItem struct {
	ID           string   `json:"id"`
	Title        string   `json:"title"`
	Description  string   `json:"description"`
	Cover        any      `json:"cover"`
	EpisodeCount int      `json:"episodeCount"`
	Tags         []string `json:"tags"`
	Badge        string   `json:"badge"`
	Type         string   `json:"type"`
	Status       string   `json:"status"`
}

type hppCategory struct {
	ID       string        `json:"id"`
	Label    string        `json:"label"`
	Children []hppCategory `json:"children"`
}

func hppKey(value string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(value))
}

func hppUnkey(value string, maxBytes int) (string, error) {
	if len(value) == 0 || len(value) > base64.RawURLEncoding.EncodedLen(maxBytes) {
		return "", errors.New("插件内容标识无效")
	}
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(data) == 0 || strings.ContainsAny(string(data), "\x00\r\n") {
		return "", errors.New("插件内容标识无效")
	}
	return string(data), nil
}

func (item hppItem) drama(source, home string) Drama {
	if len(item.ID) == 0 || len(item.ID) > 240 || strings.TrimSpace(item.Title) == "" {
		return Drama{}
	}
	id := hppKey(item.ID)
	cover := nativeText(item.Cover)
	if ref, ok := item.Cover.(map[string]any); ok && ref["transform"] != nil {
		cover = ""
	}
	return Drama{
		ID:           providerDramaID(source, id),
		Source:       source,
		SourceID:     id,
		Title:        truncate(item.Title, 300),
		Intro:        truncate(item.Description, 2000),
		Cover:        providerCoverAddress(cover, home),
		EpisodeCount: json.Number(strconv.Itoa(max(0, item.EpisodeCount))),
		Category: map[string]string{
			"short": "短剧", "series": "剧集", "movie": "电影", "anime": "动漫",
			"variety": "综艺", "documentary": "纪录片",
		}[item.Type],
		Remark:        truncate(item.Badge, 80),
		Tags:          item.Tags[:min(20, len(item.Tags))],
		ReleaseStatus: item.Status,
	}
}

func (p *hppInvocation) categories() ([]nativeCategory, error) {
	var groups []hppCategory
	if err := p.call("catalog", "getCategories", nil, &groups); err != nil {
		return nil, err
	}
	items := []nativeCategory{}
	seen := map[string]bool{}
	var collect func([]hppCategory, string, int)
	collect = func(categories []hppCategory, prefix string, depth int) {
		for _, category := range categories {
			if len(items) >= 160 || depth > 4 {
				return
			}
			if len(category.Children) > 0 {
				collect(category.Children, truncate(prefix+category.Label, 70)+" · ", depth+1)
			} else if category.ID != "" && len(category.ID) <= 92 && category.Label != "" && !seen[category.ID] {
				items = append(items, nativeCategory{ID: hppKey(category.ID), Name: truncate(prefix+category.Label, 120)})
				seen[category.ID] = true
			}
		}
	}
	collect(groups, "", 0)
	return items, nil
}

func (d *Downloader) hppAdapter(source string, spec hppSource) mobileSourceAdapter {
	return mobileSourceAdapter{
		categories: func(ctx context.Context) (items []nativeCategory, err error) {
			err = d.useHPP(ctx, spec, func(p *hppInvocation) error {
				items, err = p.categories()
				return err
			})
			return
		},
		catalog: func(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
			return d.hppPage(ctx, source, spec, page, category, query)
		},
		detail: func(ctx context.Context, id string) (Drama, []Chapter, error) {
			return d.hppDetail(ctx, source, spec, id)
		},
		resolve: func(ctx context.Context, task Task) (providerMedia, error) {
			return d.hppResolve(ctx, source, spec, task)
		},
	}
}

func (d *Downloader) hppPage(ctx context.Context, source string, spec hppSource, page int, category, query string) ([]Drama, bool, error) {
	var result struct {
		Items []hppItem `json:"items"`
		Next  any       `json:"next"`
	}
	if page < 1 || page > 500 {
		return nil, false, errors.New("插件页码无效")
	}
	cursor, next := page, page+1
	if source == "tangxin" {
		cursor, next = (page-1)*hppPageSize, page*hppPageSize
	}
	args := map[string]any{"cursor": strconv.Itoa(cursor), "limit": hppPageSize}
	err := d.useHPP(ctx, spec, func(p *hppInvocation) error {
		if query != "" {
			if !spec.search {
				return errors.New("该站源仅支持本地搜索")
			}
			args["query"] = query
			return p.call("search", "search", args, &result)
		}
		if category == "" {
			categories, err := p.categories()
			if err != nil {
				return err
			}
			if len(categories) == 0 {
				return errors.New("插件暂未提供任何目录")
			}
			category = categories[0].ID
		}
		raw, err := hppUnkey(category, 92)
		if err != nil {
			return err
		}
		args["categoryId"] = raw
		return p.call("catalog", "list", args, &result)
	})
	rows := make([]Drama, 0, len(result.Items))
	seen := map[string]bool{}
	for _, item := range result.Items[:min(200, len(result.Items))] {
		row := item.drama(source, spec.home)
		if row.ID != "" && !seen[row.ID] {
			rows = append(rows, row)
			seen[row.ID] = true
		}
	}
	return rows, len(rows) > 0 && nativeText(result.Next) == strconv.Itoa(next), err
}

func (d *Downloader) hppDetail(ctx context.Context, source string, spec hppSource, id string) (Drama, []Chapter, error) {
	raw, err := hppUnkey(id, 240)
	if err != nil {
		return Drama{}, nil, err
	}
	var data struct {
		hppItem
		Playlists []struct {
			ID       string `json:"id"`
			Kind     string `json:"kind"`
			Episodes []struct {
				ID     string `json:"id"`
				Label  string `json:"label"`
				Number int    `json:"episodeNumber"`
			} `json:"episodes"`
		} `json:"playlists"`
	}
	err = d.useHPP(ctx, spec, func(p *hppInvocation) error {
		return p.call("media", "getDetail", map[string]any{"id": raw}, &data)
	})
	if err != nil {
		return Drama{}, nil, err
	}
	if data.ID != raw {
		return Drama{}, nil, errors.New("详情与请求作品不符")
	}
	row := data.hppItem.drama(source, spec.home)
	if row.ID == "" {
		return Drama{}, nil, errors.New("作品资料不完整")
	}
	var chapters []Chapter
	for _, playlist := range data.Playlists {
		if playlist.ID == "" || len(playlist.ID) > 160 || playlist.Kind == "trailer" {
			continue
		}
		seen := map[string]bool{}
		for i, episode := range playlist.Episodes[:min(5000, len(playlist.Episodes))] {
			if episode.ID == "" || len(episode.ID) > 160 || seen[episode.ID] {
				continue
			}
			seen[episode.ID] = true
			number := episode.Number
			if number <= 0 || number > 100000 {
				number = i + 1
			}
			chapter := duanjuChapter(source, id, number, episode.Label, "", "", spec.home)
			chapter.ID = providerChapterID(source, id, hppKey(playlist.ID)+"."+hppKey(episode.ID))
			chapters = append(chapters, chapter)
		}
		if len(chapters) > 0 {
			break
		}
	}
	if len(chapters) > 0 {
		row.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	}
	return row, chapters, nil
}

func (d *Downloader) hppResolve(ctx context.Context, source string, spec hppSource, task Task) (providerMedia, error) {
	_, key, _ := strings.Cut(task.DramaID, ":")
	id, err := hppUnkey(key, 240)
	suffix, matched := strings.CutPrefix(task.Chapter.ID, providerChapterID(source, key, ""))
	playlist, episode, ok := strings.Cut(suffix, ".")
	if err != nil || !matched || !ok || task.Chapter.Source != "" && task.Chapter.Source != source {
		return providerMedia{}, errors.New("插件分集与作品不符")
	}
	playlist, err = hppUnkey(playlist, 160)
	episode, episodeErr := hppUnkey(episode, 160)
	if err != nil || episodeErr != nil {
		return providerMedia{}, errors.New("插件分集标识无效")
	}
	if source == "bfzy" {
		// This plugin may fall back to the first episode when a saved ID is stale.
		_, current, err := d.hppDetail(ctx, source, spec, key)
		if err != nil {
			return providerMedia{}, err
		}
		if !slices.ContainsFunc(current, func(chapter Chapter) bool { return chapter.ID == task.Chapter.ID }) {
			return providerMedia{}, errors.New("分集已更新，请刷新详情")
		}
	}
	var result struct {
		Streams []struct {
			URL       string            `json:"url"`
			Format    string            `json:"format"`
			Kind      string            `json:"kind"`
			Headers   map[string]string `json:"headers"`
			ExpiresAt int64             `json:"expiresAt"`
		} `json:"streams"`
		ExpiresAt int64 `json:"expiresAt"`
	}
	var defaults http.Header
	err = d.useHPP(ctx, spec, func(p *hppInvocation) error {
		defaults = p.mediaHeaders
		args := map[string]any{"mediaId": id, "playlistId": playlist, "episodeId": episode, "reason": "initial"}
		return p.call("media", "resolvePlayback", args, &result)
	})
	if err != nil {
		return providerMedia{}, err
	}
	for _, stream := range result.Streams[:min(4, len(result.Streams))] {
		remote, err := url.Parse(stream.URL)
		if err != nil || !validImageURL(remote) || stream.Kind != "" && stream.Kind != "media" {
			continue
		}
		referer := firstNonEmpty(stream.Headers["Referer"], stream.Headers["referer"], defaults.Get("Referer"))
		agent := firstNonEmpty(stream.Headers["User-Agent"], stream.Headers["user-agent"], defaults.Get("User-Agent"), userAgent)
		media := providerMedia{URL: remote.String(), Referer: referer, credentials: &providerMediaCredentials{
			publicOnly: true, origin: providerMediaOrigin(remote), referer: referer, userAgent: agent,
		}}
		if expiry := firstHPPExpiry(stream.ExpiresAt, result.ExpiresAt); expiry > 0 {
			media.credentials.expires = time.UnixMilli(expiry)
			if !time.Now().Before(media.credentials.expires) {
				continue
			}
		}
		path := strings.ToLower(remote.Path)
		if stream.Format == "hls" || strings.HasSuffix(path, ".m3u8") {
			work := providerMediaContext(ctx, media.credentials)
			media.Playlist, media.URL, err = d.fetchMediaPlaylist(work, media.URL, referer)
			if err != nil {
				continue
			}
			media.Duration = m3u8Duration(media.Playlist)
		} else if stream.Format != "progressive" && !strings.HasSuffix(path, ".mp4") {
			continue
		}
		return media, nil
	}
	return providerMedia{}, errors.New("该插件未返回当前可播放的媒体")
}

func firstHPPExpiry(stream, result int64) int64 {
	if stream > 0 {
		return stream
	}
	return result
}
