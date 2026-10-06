package app

// MobileClient embeds the existing provider parsers without starting the desktop
// HTTP UI, downloading executables, or requiring a remote business server.
import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

type MobileClient struct {
	canceledSearches map[string]mobileCanceledRead
	downloader       *Downloader
	mu               sync.Mutex
	proxies          map[string]*hlsProxy
	playbacks        map[string]mobilePlaybackChoice
	prefetches       map[string]*mobilePrefetchRead
	searches         map[string]*mobileSearchRead
	covers           coverImageCache
	catalogMu        sync.Mutex
	known            []Drama
	huangguo         map[string]mobileHuangguoCursor
}

func NewMobileClient(directory string) (*MobileClient, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("数据目录必须为绝对路径")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	cfg := defaultConfig()
	cfg.dataDir = directory
	cfg.OutputDir = filepath.Join(directory, "media")
	cfg.MaxPagesPerSort = 1
	cfg.Retries = 2
	downloader := NewDownloader(cfg)
	var known []Drama
	var huangguo map[string]mobileHuangguoCursor
	if cache, err := readLibraryCache(directory); err == nil {
		downloader.restoreHongguoCatalog(cache.HongguoApp)
		known, huangguo = cache.Dramas, cache.Huangguo
	}
	return &MobileClient{downloader: downloader, proxies: make(map[string]*hlsProxy), known: known, huangguo: huangguo}, nil
}

type mobileRequest struct {
	Path           string                     `json:"path"`
	OutputPath     string                     `json:"outputPath"`
	RequestID      string                     `json:"requestId"`
	Category       string                     `json:"category"`
	Recommendation hongguoRecommendationQuery `json:"recommendation"`
	Method         string                     `json:"method"`
	Source         string                     `json:"source"`
	ID             string                     `json:"id"`
	Query          string                     `json:"query"`
	URL            string                     `json:"url"`
	Board          string                     `json:"board"`
	Page           int                        `json:"page"`
	Quality        int                        `json:"quality"`
	Chapter        Chapter                    `json:"chapter"`
}

func mobileDramas(rows []Drama) []map[string]any {
	result := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		source := dramaProvider(row)
		if matchesSourceFilter(source, "huangguo") {
			source = "huangguo"
		}
		result = append(result, map[string]any{"id": row.ID, "source": source,
			"title": row.DisplayTitle(), "description": firstNonEmpty(row.Intro, row.Desc),
			"cover": bestDramaCover(row), "category": firstNonEmpty(row.Category, row.CategoryName, row.ChannelName),
			"episodes": followingEpisodeCount(row), "heat": row.Heat, "date": row.OnlineDate,
			"vip": row.VIP, "status": row.ReleaseStatus, "tags": row.Tags})
	}
	return result
}

func (c *MobileClient) Call(raw string) (string, error) {
	var request mobileRequest
	if len(raw) > 1024*1024 {
		return "", errors.New("请求过大")
	}
	if err := json.Unmarshal([]byte(raw), &request); err != nil {
		return "", errors.New("请求格式错误")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	defer cancel()
	var value any
	switch request.Method {
	case "coreInfo":
		value = map[string]any{"protocol": mobileProtocol, "sourceDigest": mobileSourceDigest, "version": mobileBuildVersion}
	case "libraryImport":
		result, err := c.importLibrary(ctx, request)
		if err != nil {
			return "", publicError(err)
		}
		value = result
	case "libraryExport":
		result, err := c.exportLibrary(ctx, request)
		if err != nil {
			return "", publicError(err)
		}
		value = result
	case "cover":
		source, _, valid := splitProviderDramaID(request.ID)
		if !valid && rankingSourceID.MatchString(request.ID) {
			source = "cloudfront"
		}
		request.URL = mobileCoverURL(request.ID, request.URL)
		cacheKey := request.URL
		if request.ID != "" {
			cacheKey = "drama:" + request.ID + "\x00" + request.URL
		}
		data, err := c.covers.load(ctx, cacheKey, func(ctx context.Context) ([]byte, error) {
			ctx = context.WithValue(ctx, coverSourceKey{}, source)
			if request.URL != "" {
				data, err := c.downloader.fetchCoverImage(ctx, request.URL, decodeImageBytes)
				if err == nil || request.ID == "" {
					return data, err
				}
			}
			address, err := c.downloader.mobileCoverAddress(ctx, request.ID)
			if err != nil {
				return nil, err
			}
			return c.downloader.fetchCoverImage(ctx, mobileCoverURL(request.ID, address), decodeImageBytes)
		})
		if err != nil {
			return "", publicError(err)
		}
		value = map[string]any{"data": base64.StdEncoding.EncodeToString(data), "contentType": imageContentType(data)}
	case "downloadPlan":
		if request.Chapter.ID == "" {
			return "", errors.New("缺少分集 ID")
		}
		plan, err := c.downloadPlan(ctx, request)
		if err != nil {
			return "", err
		}
		value = plan
	case "categories":
		adapter, ok := c.downloader.mobileSource(request.Source)
		if !ok {
			return "", errors.New("当前站源没有在线分类")
		}
		categories, err := adapter.categories(ctx)
		if err != nil {
			return "", publicError(err)
		}
		value = map[string]any{"items": append([]nativeCategory{{ID: "", Name: "全部"}}, categories...)}
	case "catalog":
		if adapter, ok := c.downloader.mobileSource(request.Source); ok {
			result, err := c.sourcePage(ctx, request, adapter)
			if err != nil {
				return "", err
			}
			value = result
			break
		}
		if request.Source == "huangguo" {
			page := max(1, request.Page)
			if request.Page < 0 || page > 200 {
				return "", errors.New("页码超出范围")
			}
			c.catalogMu.Lock()
			defer c.catalogMu.Unlock()
			if page == 1 || c.huangguo == nil {
				c.huangguo = map[string]mobileHuangguoCursor{}
			}
			rows, more, err := c.downloader.mobileHuangguoCatalog(context.WithValue(ctx, providerTextNoCacheKey{}, true), page, c.huangguo)
			if saveErr := writeLibraryCache(c.downloader.cfg.dataDirectory(), libraryCache{HongguoApp: c.downloader.hongguoCatalogSnapshot(), Dramas: c.known, Huangguo: c.huangguo}); saveErr != nil {
				err = errors.Join(err, saveErr)
			}
			warning := ""
			if err != nil {
				if len(rows) == 0 {
					return "", publicError(err)
				}
				warning = publicError(err).Error()
			}
			value = map[string]any{"items": mobileDramas(rows), "hasMore": more && page < 200, "page": page, "warning": warning, "catalogScope": "page"}
			break
		}
		c.catalogMu.Lock()
		defer c.catalogMu.Unlock()
		if request.Source != "hongguo" && request.Source != "huangdou" && request.Source != "huangguo" {
			return "", errors.New("未知站源")
		}
		var rows []Drama
		var err error
		hasMore := false
		if request.Page > 200 && request.Source != sourceHongguo {
			return "", errors.New("页码超出范围")
		}
		if request.Source == sourceHongguo {
			ctx = withKnownHongguoDramas(ctx, c.known)
			if request.Page > 1 {
				ctx = context.WithValue(ctx, libraryMoreKey{}, true)
			}
			rows, err = c.downloader.fetchHongguoDramas(ctx)
			state := c.downloader.hongguoCatalogSnapshot()
			byID := make(map[string]Drama, len(c.known)+len(rows))
			for _, row := range c.known {
				byID[row.ID] = row
			}
			for _, row := range rows {
				byID[row.ID] = row
			}
			c.known = c.known[:0]
			for _, row := range byID {
				c.known = append(c.known, row)
			}
			hasMore = hongguoCatalogHasMore(state)
			if saveErr := writeLibraryCache(c.downloader.cfg.dataDirectory(), libraryCache{HongguoApp: state, Dramas: c.known, Huangguo: c.huangguo}); saveErr != nil && err == nil {
				err = saveErr
			}
		} else if request.Source == sourceHuangdou && request.Page > 1 {
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
		if request.Source == sourceHuangdou {
			hasMore = len(rows) > 0 && request.Page < 200
		}
		warning := ""
		if err != nil {
			if len(rows) == 0 {
				return "", publicError(err)
			}
			warning = publicError(err).Error()
		}
		value = map[string]any{"items": mobileDramas(rows), "warning": warning, "hasMore": hasMore, "catalogScope": "available"}
	case "recommendations":
		page, err := c.downloader.fetchHongguoRecommendations(ctx, request.Recommendation)
		if err != nil {
			return "", publicError(err)
		}
		value = map[string]any{"items": mobileDramas(page.Dramas), "hasMore": page.HasMore, "nextOffset": page.NextOffset, "sessionId": page.SessionID}
	case "detail":
		if request.ID == "" {
			return "", errors.New("缺少短剧 ID")
		}
		var detail Drama
		var err error
		if _, _, valid := splitProviderDramaID(request.ID); valid {
			detail, err = c.downloader.fetchDramaMetadata(ctx, Drama{ID: request.ID})
		} else if rankingSourceID.MatchString(request.ID) {
			err = c.downloader.fetchAPI(ctx, "/api/app/playlet/detail/"+url.PathEscape(request.ID), nil, &detail)
		} else {
			return "", errors.New("无效的剧集 ID")
		}
		if err != nil {
			return "", publicError(err)
		}
		if detail.ID != request.ID {
			return "", errors.New("详情与请求剧集不符")
		}
		value = map[string]any{"item": mobileDramas([]Drama{detail})[0]}
	case "suggestions":
		if request.Source != sourceHongguo {
			return "", errors.New("当前站源暂无搜索联想")
		}
		items, err := c.downloader.hongguoSearchSuggestions(ctx, request.Query)
		if err != nil {
			return "", publicError(err)
		}
		value = map[string]any{"items": items}
	case "searchProgress":
		value = c.searchProgress(request, false)
	case "cancelSearch":
		value = c.searchProgress(request, true)
	case "search":
		searchCtx, read, beginErr := c.beginSearch(ctx, request)
		if beginErr != nil {
			return "", beginErr
		}
		ctx = searchCtx
		defer func() {
			if read != nil {
				c.mu.Lock()
				if c.searches[request.RequestID] == read {
					read.done = true
				}
				c.mu.Unlock()
			}
		}()
		if request.Source == "huangguo" {
			items, more, err := c.downloader.searchHuangguoAI(ctx, request.Query, request.Page)
			if err != nil {
				return "", publicError(err)
			}
			value = map[string]any{"items": mobileDramas(items), "hasMore": more, "scope": "huangguoai"}
			break
		}
		if adapter, ok := c.downloader.mobileSource(request.Source); ok {
			result, err := c.sourcePage(ctx, request, adapter)
			if err != nil {
				return "", err
			}
			value = result
			break
		}
		if request.Source != "hongguo" {
			return "", errors.New("当前站源尚未接入联网搜索，可继续使用本地筛选")
		}
		rows, err := c.downloader.searchHongguoDramasProgress(context.WithValue(ctx, hongguoSearchSeasonExtensionKey{}, true), request.Query, func(entry hongguoSearchEntry) {
			c.updateSearch(request.RequestID, read, map[string]any{"items": mobileDramas(entry.Dramas), "warning": entry.Warning, "limited": entry.Limited, "total": entry.Total}, false)
		})
		if err != nil {
			return "", publicError(err)
		}
		value = map[string]any{"items": mobileDramas(rows.Dramas), "warning": rows.Warning, "limited": rows.Limited, "total": rows.Total}
	case "chapters":
		if request.ID == "" {
			return "", errors.New("缺少短剧 ID")
		}
		title, chapters, err := c.downloader.GetDramaChapters(ctx, request.ID)
		if err != nil {
			return "", publicError(err)
		}
		value = map[string]any{"title": title, "chapters": chapters}
	case "boards":
		boards := make([]rankingBoard, 0)
		for _, board := range rankingBoards {
			if board.Source == request.Source {
				boards = append(boards, board)
			}
		}
		value = map[string]any{"items": boards}
	case "ranking":
		board, ok := findRankingBoard(request.Board)
		if !ok {
			return "", errors.New("未知榜单")
		}
		page := request.Page
		if page < 1 {
			page = 1
		}
		if page > 100 {
			return "", errors.New("页码超出范围")
		}
		result, err := c.downloader.loadRankingPage(ctx, board, page, false)
		if err != nil {
			return "", publicError(err)
		}
		rows := make([]map[string]any, 0, len(result.Items))
		for _, item := range result.Items {
			rows = append(rows, map[string]any{"rank": item.Rank, "position": item.Position, "drama": mobileDramas([]Drama{item.Drama})[0]})
		}
		value = map[string]any{"items": rows, "hasMore": result.HasMore, "warning": result.Warning, "kind": result.Kind, "description": result.Description}
	case "resolve":
		if request.Chapter.ID == "" {
			return "", errors.New("缺少分集 ID")
		}
		media, key, err := c.downloader.resolvePlaybackMedia(ctx, Task{DramaID: request.ID, Chapter: request.Chapter})
		if err != nil {
			return "", publicError(err)
		}
		choice, err := mobilePlaybackChoices(media, key, request.Quality)
		if err != nil {
			return "", err
		}
		choice, err = c.prepareMobileChoice(ctx, choice)
		if err != nil {
			return "", publicError(err)
		}
		value, err = c.openMobilePlayback(choice)
		if err != nil {
			return "", publicError(err)
		}
	case "fallback":
		c.mu.Lock()
		choice, exists := c.playbacks[request.ID]
		c.mu.Unlock()
		if !exists || time.Since(choice.created) > 2*time.Minute {
			return "", errors.New("播放线路已过期，请重新解析")
		}
		choice.index++
		var err error
		value, err = c.openMobilePlayback(choice)
		if err != nil {
			return "", publicError(err)
		}
	case "prefetch":
		result, err := c.prefetchPlayback(ctx, request.ID)
		if err != nil {
			return "", publicError(err)
		}
		value = result
	case "cancelPrefetch":
		c.cancelPlaybackPrefetch(request.ID)
		value = map[string]any{"ok": true}
	case "release":
		c.mu.Lock()
		proxy := c.proxies[request.ID]
		delete(c.proxies, request.ID)
		delete(c.playbacks, request.ID)
		if read := c.prefetches[request.ID]; read != nil {
			read.cancel()
			delete(c.prefetches, request.ID)
		}
		c.mu.Unlock()
		if proxy != nil {
			proxy.Close()
		}
		value = map[string]any{"ok": true}
	default:
		return "", errors.New("未知操作")
	}
	encoded, err := json.Marshal(value)
	return string(encoded), err
}

func (c *MobileClient) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for id, read := range c.searches {
		read.cancel()
		delete(c.searches, id)
	}
	c.playbacks = nil
	for id, read := range c.prefetches {
		read.cancel()
		delete(c.prefetches, id)
	}
	for id, proxy := range c.proxies {
		proxy.Close()
		delete(c.proxies, id)
	}
}
