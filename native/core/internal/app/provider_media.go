package app

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type providerMedia struct {
	certificateOrigin   string
	certificateFallback bool
	credentials         *providerMediaCredentials
	URL                 string
	Referer             string
	Duration            time.Duration
	Playlist            string
	HLSKey              []byte
	CENCKey             []byte
	Quality             int
	Variants            []providerMedia
}

func (d *Downloader) providerBaseURL(source string) string {
	source = canonicalProviderSource(source)
	var configured, fallback string
	switch source {
	case sourceHuangguoAI:
		configured, fallback = d.cfg.HuangguoAIURL, huangguoAIBaseURL
	case sourceHuangguoVideo:
		configured, fallback = d.cfg.HuangguoVideoURL, huangguoVideoBaseURL
	case sourceHuangdou:
		configured, fallback = d.cfg.HuangdouURL, huangdouBaseURL
	case sourceHongguo:
		configured, fallback = d.cfg.HongguoURL, hongguoBaseURL
	case sourceHuangju:
		configured, fallback = d.cfg.HuangjuURL, huangjuBaseURL
	case sourceYeguo:
		configured, fallback = d.cfg.YeguoURL, yeguoBaseURL
	case sourceDSD:
		configured, fallback = d.cfg.DSDURL, dsdBaseURL
	default:
		if isDuanjuProviderSource(source) {
			return d.duanjuBaseURL(source)
		}
		fallback = "https://d2pypzndaqisk.cloudfront.net"
	}
	return strings.TrimRight(firstNonEmpty(configured, fallback), "/")
}

func sourceFromDramaID(id string) string {
	if source, _, ok := splitProviderDramaID(id); ok {
		return source
	}
	return ""
}

func providerSourceForURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	switch {
	case host == "huangju.net" || host == "www.huangju.net" || host == "api.huangju.net":
		return sourceHuangju
	case host == "ygdj7.com" || host == "www.ygdj7.com" || host == "yeguodj.com" || host == "www.yeguodj.com" || strings.HasSuffix(host, ".ygrwdsgt.cc") || strings.HasSuffix(host, ".buxefaex.cc") || strings.HasSuffix(host, ".callawtj.cc") || strings.HasSuffix(host, ".fzchosdi.cc"):
		return sourceYeguo
	case host == "dsd.com.se" || host == "www.dsd.com.se":
		return sourceDSD
	case huangguoAIIsKnownHost(raw) || host == "huangguoai.com" || strings.HasSuffix(host, ".ediayikma.cc") || strings.HasSuffix(host, ".agdkczeyx.cc"):
		return sourceHuangguoAI
	case host == "huangguo.video":
		return sourceHuangguoVideo
	case host == "tideember.cc" || host == "xqjurgek.top":
		return sourceHuangdou
	case host == "hongguoduanju.com" || host == "www.hongguoduanju.com":
		return sourceHongguo
	default:
		return duanjuSourceForHost(host)
	}
}

func (d *Downloader) providerURLCandidates(raw string) []string {
	source := providerSourceForURL(raw)
	if source == "" || isDuanjuProviderSource(source) {
		return []string{raw}
	}
	parsed, _ := url.Parse(raw)
	if source == sourceHuangguoAI && huangguoAIIsContentHost(parsed.Hostname()) {
		return []string{raw}
	}
	d.providerMu.Lock()
	preferred := d.providerHosts[source]
	d.providerMu.Unlock()
	var candidates []string
	seen := map[string]bool{}
	add := func(candidate string) {
		if candidate != "" && !seen[candidate] {
			seen[candidate] = true
			candidates = append(candidates, candidate)
		}
	}
	add(rehostProviderURL(parsed, preferred))
	configured := d.providerBaseURL(source)
	add(rehostProviderURL(parsed, configured))
	if providerSourceForURL(configured) == "" {
		return candidates
	}
	for _, candidate := range providerURLCandidates(raw) {
		add(candidate)
	}
	return candidates
}

func (d *Downloader) resolveProviderMedia(ctx context.Context, task Task) (providerMedia, error) {
	if source, _, valid := splitProviderDramaID(task.DramaID); valid {
		if adapter, ok := d.mobileSource(source); ok {
			return adapter.resolve(ctx, task)
		}
	}

	chapter := task.Chapter
	chapter.Source = canonicalProviderSource(chapter.Source)
	if chapter.Source == "" {
		chapter.Source = sourceFromDramaID(task.DramaID)
	}
	if strings.HasPrefix(chapter.VideoURL, "hongguo-cenc://") {
		return d.resolveHongguoMedia(ctx, task)
	}
	if chapter.PageURL == "" && (chapter.Source == sourceHuangguoAI || chapter.Source == sourceHuangguoVideo) {
		if source, sourceID, valid := splitProviderDramaID(task.DramaID); valid {
			_, chapters, err := d.GetHuangguoChapters(ctx, source, sourceID)
			if err != nil {
				return providerMedia{}, fmt.Errorf("刷新旧任务播放地址失败: %w", err)
			}
			matched := false
			for _, fresh := range chapters {
				if fresh.ID == chapter.ID || fresh.EpisodeString(task.Index) == chapter.EpisodeString(task.Index) {
					chapter = fresh
					matched = true
					break
				}
			}
			if !matched {
				return providerMedia{}, fmt.Errorf("原章节已变化，请更新该合集后重新下载")
			}
		}
	}
	media := providerMedia{certificateFallback: chapter.Source == sourceHuangguoAI || chapter.Source == sourceHuangguoVideo, URL: chapter.VideoURL, Referer: firstNonEmpty(chapter.Referer, d.providerBaseURL(chapter.Source)+"/")}
	if chapter.Source == sourceHuangdou {
		_, sourceID, valid := splitProviderDramaID(task.DramaID)
		if valid {
			sequence, err := strconv.Atoi(chapter.EpisodeString(task.Index))
			if err != nil || sequence < 1 {
				return providerMedia{}, fmt.Errorf("黄豆集数无效")
			}
			client := newHuangdouAPIClient(d)
			media, err = d.resolveHuangdouPlayback(ctx, client, sourceID, sequence)
			if err != nil {
				return providerMedia{}, err
			}
			media.Referer = client.host + "/home"
		}
	}
	if chapter.PageURL != "" && (chapter.Source == sourceHuangguoAI || chapter.Source == sourceHuangguoVideo) {
		pageCtx := ctx
		if chapter.Source == sourceHuangguoAI {
			_, sourceID, valid := splitProviderDramaID(task.DramaID)
			if !valid {
				return providerMedia{}, fmt.Errorf("黄果播放缺少剧集身份")
			}
			episode := chapter.EpisodeString(task.Index)
			pageCtx = context.WithValue(ctx, providerTextValidatorKey{}, providerTextValidator(func(body, effectiveURL string) error {
				return validateHuangguoAIPlaybackPage(body, effectiveURL, sourceID, episode)
			}))
			chapter.PageURL = huangguoAIPlaybackPageURL(d.huangguoAIContentBaseURL(ctx), sourceID, episode)
		}
		body, pageURL, err := d.fetchProviderTextURL(pageCtx, chapter.PageURL, media.Referer)
		if err != nil {
			return providerMedia{}, err
		}
		if chapter.Source == sourceHuangguoAI {
			media.URL = parseAIVideoURL(body, pageURL)
		} else {
			media.URL = parseDataHLS(body, pageURL)
		}
		d.providerMu.Lock()
		if preferred := d.providerHosts[chapter.Source]; preferred != "" {
			media.Referer = preferred + "/"
		}
		d.providerMu.Unlock()
	}
	if !isProviderHTTPMediaURL(media.URL) {
		return providerMedia{}, fmt.Errorf("%s 未返回有效播放地址，请刷新章节或确认站点访问权限", chapter.Source)
	}
	if media.certificateFallback {
		media.certificateOrigin = media.URL
	}
	parsed, _ := url.Parse(media.URL)
	if strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		client := mediaHTTPClient(d.client, media)
		if media.certificateFallback {
			defer client.CloseIdleConnections()
		}
		playlist, finalURL, err := d.fetchMediaPlaylistWithClient(ctx, media.URL, media.Referer, client)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取播放列表失败: %w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, fmt.Errorf("站点未返回有效 M3U8，可能需要登录或链接已失效")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist, media.URL = playlist, finalURL
	}
	return media, nil
}
