package app

import (
	"context"
	"errors"
	"strings"
)

type mobileSourceAdapter struct {
	categories func(context.Context) ([]nativeCategory, error)
	catalog    func(context.Context, int, string, string) ([]Drama, bool, error)
	detail     func(context.Context, string) (Drama, []Chapter, error)
	resolve    func(context.Context, Task) (providerMedia, error)
}

func (d *Downloader) mobileSource(source string) (mobileSourceAdapter, bool) {
	source = canonicalProviderSource(source)
	if isDuanjuProviderSource(source) {
		return mobileSourceAdapter{
			categories: func(ctx context.Context) ([]nativeCategory, error) { return d.fetchDuanjuCategories(ctx, source) },
			catalog: func(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
				if query != "" {
					return d.searchDuanjuPage(ctx, source, query, page)
				}
				return d.fetchDuanjuCatalogPage(ctx, source, page, category)
			},
			detail: func(ctx context.Context, id string) (Drama, []Chapter, error) {
				return d.fetchDuanjuDetail(ctx, source, id)
			},
			resolve: d.resolveDuanjuMedia,
		}, true
	}
	sources := map[string]mobileSourceAdapter{
		sourceHuangju: {d.fetchHuangjuCategories, d.fetchHuangjuCatalogPage, d.fetchHuangjuDetail, d.resolveHuangjuMedia},
		sourceYeguo:   {d.fetchYeguoCategories, d.fetchYeguoCatalogPage, d.fetchYeguoDetail, d.resolveYeguoMedia},
		sourceDSD:     {func(ctx context.Context) ([]nativeCategory, error) { return d.fetchDSDCategories(ctx, false) }, d.fetchDSDCatalogPage, d.fetchDSDDetail, d.resolveDSDMedia},
	}
	adapter, ok := sources[canonicalProviderSource(source)]
	return adapter, ok
}

func (c *MobileClient) sourcePage(ctx context.Context, request mobileRequest, adapter mobileSourceAdapter) (map[string]any, error) {
	page := request.Page
	if page == 0 {
		page = 1
	}
	if page < 1 || page > 1000000 || !validNativeCategory(request.Source, request.Category) {
		return nil, errors.New("站源查询参数无效")
	}
	query := ""
	if request.Method == "search" {
		query = strings.TrimSpace(request.Query)
		if query == "" {
			return nil, errors.New("请输入搜索内容")
		}
	}
	rows, more, err := adapter.catalog(ctx, page, request.Category, query)
	warning := ""
	if err != nil {
		if len(rows) == 0 {
			return nil, publicError(err)
		}
		warning = publicError(err).Error()
	}
	return map[string]any{"items": mobileDramas(rows), "hasMore": more, "page": page, "warning": warning, "catalogScope": "page"}, nil
}
