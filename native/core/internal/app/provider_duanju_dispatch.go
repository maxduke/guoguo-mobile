package app

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

func (d *Downloader) fetchDuanjuCategories(ctx context.Context, source string) ([]nativeCategory, error) {
	source = canonicalProviderSource(source)
	if !isDuanjuProviderSource(source) {
		return nil, errors.New("该站源不支持分类读取")
	}
	if static, found := duanjuStaticCategories[source]; found {
		categories := make([]nativeCategory, 0, len(static))
		for _, entry := range static {
			categories = append(categories, nativeCategory{ID: entry.ID, Name: entry.Name})
		}
		return categories, nil
	}
	switch source {
	case sourceYaguo:
		return d.fetchYaguoCategories(ctx)
	case sourceMaoguo:
		return d.fetchMaoguoCategories(ctx)
	}
	return []nativeCategory{}, nil
}

func (d *Downloader) fetchDuanjuCatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error) {
	source = canonicalProviderSource(source)
	switch source {
	case sourceYaguo:
		return d.fetchYaguoCatalogPage(ctx, page, category)
	case sourceMaoguo:
		return d.fetchMaoguoCatalogPage(ctx, page, category)
	case sourceFanguo:
		return d.fetchFanguoCatalogPage(ctx, page, category)
	case sourceGuanguo:
		return d.fetchGuanguoCatalogPage(ctx, page, category)
	case sourceHeguo:
		return d.fetchHeguoCatalogPage(ctx, page, category)
	case sourceXingguo:
		return d.fetchXingguoCatalogPage(ctx, page, category)
	case sourceNiuguo:
		return d.fetchNiuguoCatalogPage(ctx, page, category)
	case sourceHuaguo, sourceWuguo, sourcePiguo, sourceMiguo, sourceShuangguo:
		return d.fetchMaccmsCatalogPage(ctx, source, page, category)
	case sourceChaoguo:
		return d.fetchChaoguoCatalogPage(ctx, page, category)
	}
	return nil, false, errors.New("该站源暂未接入目录")
}

func (d *Downloader) fetchDuanjuDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error) {
	source = canonicalProviderSource(source)
	switch source {
	case sourceYaguo:
		return d.fetchYaguoDetail(ctx, sourceID)
	case sourceMaoguo:
		return d.fetchMaoguoDetail(ctx, sourceID)
	case sourceFanguo:
		return d.fetchFanguoDetail(ctx, sourceID)
	case sourceGuanguo:
		return d.fetchGuanguoDetail(ctx, sourceID)
	case sourceHeguo:
		return d.fetchHeguoDetail(ctx, sourceID)
	case sourceXingguo:
		return d.fetchXingguoDetail(ctx, sourceID)
	case sourceNiuguo:
		return d.fetchNiuguoDetail(ctx, sourceID)
	case sourceHuaguo, sourceWuguo, sourcePiguo, sourceMiguo, sourceShuangguo:
		return d.fetchMaccmsDetail(ctx, source, sourceID)
	case sourceChaoguo:
		return d.fetchChaoguoDetail(ctx, sourceID)
	}
	return Drama{}, nil, errors.New("该站源暂未接入详情")
}

func (d *Downloader) searchDuanju(ctx context.Context, source, query string) ([]Drama, error) {
	source = canonicalProviderSource(source)
	switch source {
	case sourceYaguo:
		return d.searchYaguo(ctx, query)
	case sourceMaoguo:
		return d.searchMaoguo(ctx, query)
	case sourceFanguo:
		return d.searchFanguo(ctx, query)
	case sourceGuanguo:
		return d.searchGuanguo(ctx, query)
	case sourceHeguo:
		return d.searchHeguo(ctx, query)
	case sourceXingguo:
		return d.searchXingguo(ctx, query)
	case sourceNiuguo:
		return d.searchNiuguo(ctx, query)
	case sourceHuaguo, sourceWuguo, sourcePiguo, sourceMiguo, sourceShuangguo:
		return d.searchMaccms(ctx, source, query)
	case sourceChaoguo:
		items, _, err := d.searchChaoguoPage(ctx, query, 1)
		return items, err
	}
	return nil, errors.New("该站源不支持在线搜索")
}

// searchDuanjuPage adapts the providers' search endpoints to the mobile page contract.
func (d *Downloader) searchDuanjuPage(ctx context.Context, source, query string, page int) ([]Drama, bool, error) {
	switch canonicalProviderSource(source) {
	case sourceFanguo:
		return d.searchFanguoPage(ctx, query, page)
	case sourceHeguo:
		return d.searchHeguoPage(ctx, query, page)
	case sourceXingguo:
		return d.searchXingguoPage(ctx, query, page)
	case sourceMaoguo:
		return d.searchMaoguoPage(ctx, query, page)
	case sourceGuanguo:
		return d.searchGuanguoPage(ctx, query, page)
	case sourceNiuguo:
		return d.searchNiuguoPage(ctx, query, page)
	case sourceHuaguo, sourceWuguo, sourcePiguo, sourceMiguo, sourceShuangguo:
		return d.searchMaccmsPage(ctx, source, query, page)
	case sourceChaoguo:
		return d.searchChaoguoPage(ctx, query, page)
	default:
		if page > 1 {
			return nil, false, nil
		}
		items, err := d.searchDuanju(ctx, source, query)
		return items, false, err
	}
}

func duanjuSupportsSearch(source string) bool {
	spec, found := duanjuSourceSpecFor(source)
	return found && spec.Searcher
}

func duanjuSupportsPaging(source string) bool {
	spec, found := duanjuSourceSpecFor(source)
	return found && spec.Paged
}

func duanjuMoreFlag(data map[string]any) bool {
	value, _ := duanjuMoreFlagPresent(data)
	return value
}

func duanjuMoreFlagPresent(data map[string]any) (bool, bool) {
	for _, key := range []string{"isMore", "hasMore", "has_more", "hasNext"} {
		switch value := data[key].(type) {
		case bool:
			return value, true
		case float64:
			return value > 0, true
		case string:
			return strings.EqualFold(value, "true") || value == "1", true
		}
	}
	return false, false
}

func (d *Downloader) resolveDuanjuMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, sourceID, valid := splitProviderDramaID(task.DramaID)
	if !valid || !isDuanjuProviderSource(source) ||
		(task.Chapter.Source != "" && canonicalProviderSource(task.Chapter.Source) != source) ||
		!strings.HasPrefix(task.Chapter.ID, providerChapterID(source, sourceID, "")) {
		return providerMedia{}, errors.New("分集与站源不匹配，请刷新详情后重试")
	}
	task.Chapter.Source = source
	name := duanjuSourceName(source)
	switch source {
	case sourceHeguo:
		return d.resolveHeguoMedia(ctx, task)
	case sourceGuanguo:
		return d.resolveGuanguoMedia(ctx, task)
	case sourceNiuguo:
		return d.resolveNiuguoMedia(ctx, task)
	}
	base := d.duanjuBaseURL(source)
	if base == "" {
		return providerMedia{}, errors.New("站源地址不可用")
	}
	address := strings.TrimSpace(task.Chapter.VideoURL)
	pageURL := strings.TrimSpace(task.Chapter.PageURL)
	referer := firstNonEmpty(task.Chapter.Referer, base+"/")
	// 网页型站源的分集保存在详情页，需要即时解析真实播放地址。
	if !isProviderHTTPMediaURL(address) || !duanjuLooksLikeMedia(address) {
		if pageURL == "" {
			if source, sourceID, valid := splitProviderDramaID(task.DramaID); valid {
				if _, chapters, err := d.fetchDuanjuDetail(ctx, source, sourceID); err == nil {
					for _, fresh := range chapters {
						if fresh.ID == task.Chapter.ID {
							address = fresh.VideoURL
							pageURL = fresh.PageURL
							break
						}
					}
				}
			}
		}
		if pageURL != "" {
			resolved, err := d.resolveDuanjuWebPage(ctx, source, pageURL, referer)
			if err != nil {
				return providerMedia{}, err
			}
			return d.prepareWebProviderMedia(ctx, resolved, name)
		}
	}
	if !isProviderHTTPMediaURL(address) {
		return providerMedia{}, fmt.Errorf("%s未返回有效播放地址，请刷新章节后重试", name)
	}
	return d.prepareWebProviderMedia(ctx, providerMedia{URL: address, Referer: referer}, name)
}

func duanjuLooksLikeMedia(address string) bool {
	lower := strings.ToLower(address)
	return strings.Contains(lower, ".m3u8") || strings.Contains(lower, ".mp4") || strings.Contains(lower, ".flv")
}

func (d *Downloader) resolveDuanjuWebPage(ctx context.Context, source, pageURL, referer string) (providerMedia, error) {
	body, current, err := d.fetchProviderTextURL(ctx, pageURL, referer)
	if err != nil {
		return providerMedia{}, err
	}
	address := maccmsNormalizePlaybackURL(maccmsPlayerURL(body))
	for hop := 0; hop < 2 && address != "" && !duanjuLooksLikeMedia(address); hop++ {
		if !isProviderHTTPMediaURL(address) || address == current {
			break
		}
		nested, finalURL, err := d.fetchProviderTextURL(ctx, address, current)
		if err != nil {
			return providerMedia{}, err
		}
		if strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(nested, "\ufeff")), "#EXTM3U") {
			return providerMedia{URL: finalURL, Playlist: nested, Referer: current}, nil
		}
		current = finalURL
		address = maccmsNormalizePlaybackURL(maccmsPlayerURL(nested))
	}
	if address == "" || !duanjuLooksLikeMedia(address) {
		return providerMedia{}, fmt.Errorf("%s未返回有效播放地址，请刷新章节后重试", duanjuSourceName(source))
	}
	return providerMedia{URL: address, Referer: current}, nil
}

func (d *Downloader) duanjuSourceProbe(ctx context.Context, source string) (string, error) {
	source = canonicalProviderSource(source)
	items, _, err := d.fetchDuanjuCatalogPage(ctx, source, 1, "")
	if err != nil {
		return "", err
	}
	if len(items) == 0 {
		return "", errors.New("站源入口可达，但没有解析到有效剧集")
	}
	return fmt.Sprintf("已解析 %d 部剧", len(items)), nil
}

func duanjuFirstCategory(source string) string {
	if static, found := duanjuStaticCategories[canonicalProviderSource(source)]; found && len(static) > 0 {
		return static[0].ID
	}
	return ""
}
