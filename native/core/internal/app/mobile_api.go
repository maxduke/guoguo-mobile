package app

// MobileClient embeds the existing provider parsers without starting the desktop
// HTTP UI, downloading executables, or requiring a remote business server.
import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

type MobileClient struct {
	downloader *Downloader
	mu         sync.Mutex
	proxies    map[string]*hlsProxy
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
	cfg.settingsLoaded = true
	cfg.MaxPagesPerSort = 1
	cfg.Retries = 2
	downloader := NewDownloader(cfg)
	if cache, err := readLibraryCache(directory); err == nil {
		downloader.restoreHongguoCatalog(cache.HongguoApp)
	}
	return &MobileClient{downloader: downloader, proxies: make(map[string]*hlsProxy)}, nil
}

type mobileRequest struct {
	Method  string  `json:"method"`
	Source  string  `json:"source"`
	ID      string  `json:"id"`
	Query   string  `json:"query"`
	Board   string  `json:"board"`
	Page    int     `json:"page"`
	Quality int     `json:"quality"`
	Chapter Chapter `json:"chapter"`
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
			"cover": bestDramaCover(row), "category": firstNonEmpty(row.Category, row.ChannelName, row.CategoryName),
			"episodes": followingEpisodeCount(row), "heat": row.Heat, "date": row.OnlineDate})
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
	case "downloadPlan":
		if request.Chapter.ID == "" {
			return "", errors.New("缺少分集 ID")
		}
		plan, err := c.downloadPlan(ctx, request)
		if err != nil {
			return "", err
		}
		value = plan
	case "catalog":
		if request.Source != "hongguo" && request.Source != "huangdou" && request.Source != "huangguo" {
			return "", errors.New("未知站源")
		}
		var rows []Drama
		var err error
		if request.Page > 200 {
			return "", errors.New("页码超出范围")
		}
		if request.Source == sourceHongguo {
			if request.Page > 1 {
				ctx = context.WithValue(ctx, libraryMoreKey{}, true)
			}
			rows, err = c.downloader.fetchHongguoDramas(ctx)
			state := c.downloader.hongguoCatalogSnapshot()
			if saveErr := writeLibraryCache(c.downloader.cfg.dataDirectory(), libraryCache{HongguoApp: state}); saveErr != nil && err == nil {
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
		warning := ""
		if err != nil {
			if len(rows) == 0 {
				return "", publicError(err)
			}
			warning = publicError(err).Error()
		}
		value = map[string]any{"items": mobileDramas(rows), "warning": warning, "hasMore": request.Source != "huangguo" && len(rows) > 0 && request.Page < 200}
	case "search":
		if request.Source != "hongguo" {
			return "", errors.New("当前站源尚未接入联网搜索，可继续使用本地筛选")
		}
		rows, err := c.downloader.searchHongguoDramas(ctx, request.Query)
		if err != nil {
			return "", publicError(err)
		}
		value = map[string]any{"items": mobileDramas(rows.Dramas)}
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
			rows = append(rows, map[string]any{"rank": item.Rank, "drama": mobileDramas([]Drama{item.Drama})[0]})
		}
		value = map[string]any{"items": rows, "hasMore": result.HasMore, "warning": result.Warning}
	case "resolve":
		if request.Chapter.ID == "" {
			return "", errors.New("缺少分集 ID")
		}
		media, key, err := c.downloader.resolvePlaybackMedia(ctx, Task{DramaID: request.ID, Chapter: request.Chapter})
		if err != nil {
			return "", publicError(err)
		}
		qualities := make([]int, 0, len(media.Variants))
		variants := media.Variants
		for _, variant := range variants {
			qualities = append(qualities, variant.Quality)
			if request.Quality > 0 && variant.Quality == request.Quality {
				media = variant
			}
		}
		playURL := media.URL
		session := ""
		if media.Playlist != "" || len(key) > 0 || len(media.HLSKey) > 0 {
			proxy, err := c.downloader.newHLSProxy(context.Background(), media, key)
			if err != nil {
				return "", err
			}
			session = randomHex(16)
			c.mu.Lock()
			if len(c.proxies) >= 4 {
				c.mu.Unlock()
				proxy.Close()
				return "", errors.New("播放会话过多，请关闭已有播放器")
			}
			c.proxies[session] = proxy
			c.mu.Unlock()
			playURL = proxy.root
		}
		value = map[string]any{"url": playURL, "remoteUrl": media.URL, "session": session,
			"headers": map[string]string{"Referer": media.Referer, "User-Agent": userAgent},
			"quality": media.Quality, "qualities": qualities, "hls": media.Playlist != "", "castDirect": session == "" && len(media.CENCKey) == 0,
			"contentKey": hex.EncodeToString(media.CENCKey)}
	case "release":
		c.mu.Lock()
		proxy := c.proxies[request.ID]
		delete(c.proxies, request.ID)
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
	for id, proxy := range c.proxies {
		proxy.Close()
		delete(c.proxies, id)
	}
}
