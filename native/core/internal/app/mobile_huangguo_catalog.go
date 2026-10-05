package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/html"
)

type mobileCatalogPage struct {
	items []Drama
	more  bool
	err   error
}

type mobileHuangguoCursor struct {
	Next int  `json:"next"`
	Done bool `json:"done"`
}

// Keep the three Huangguo identities, but fetch only one page of each. A slow
// provider must not consume the whole bridge deadline or discard other results.
func (d *Downloader) mobileHuangguoCatalog(ctx context.Context, page int, cursors map[string]mobileHuangguoCursor) ([]Drama, bool, error) {
	if cursors == nil {
		cursors = map[string]mobileHuangguoCursor{}
	}
	jobs := []struct {
		name string
		load func(context.Context, int) ([]Drama, bool, error)
	}{
		{"cloudfront", d.mobileLegacyCatalogPage},
		{sourceHuangguoAI, d.mobileAICatalogPage},
		{sourceHuangguoVideo, d.mobileVideoCatalogPage},
	}
	results := make([]mobileCatalogPage, len(jobs))
	var group sync.WaitGroup
	for index, job := range jobs {
		cursor := cursors[job.name]
		if cursor.Next < 1 || cursor.Next > 201 {
			cursor = mobileHuangguoCursor{Next: page}
			cursors[job.name] = cursor
		}
		if cursor.Done {
			continue
		}
		group.Go(func() {
			work, cancel := context.WithTimeout(ctx, 25*time.Second)
			defer cancel()
			rows, more, err := job.load(work, cursor.Next)
			results[index] = mobileCatalogPage{rows, more, err}
		})
	}
	group.Wait()
	var rows []Drama
	more := false
	failures := map[string]error{}
	for index, result := range results {
		name := jobs[index].name
		cursor := cursors[name]
		if cursor.Done {
			continue
		}
		rows = mergeSourceDramas(rows, result.items, nil, "huangguo")
		if result.err != nil {
			// Retry this provider's page while healthy providers can advance.
			failures[name] = result.err
		} else {
			cursor.Next++
			cursor.Done = !result.more || cursor.Next > 200
			cursors[name] = cursor
		}
		more = more || !cursor.Done
	}
	if len(failures) > 0 {
		return rows, more, &libraryLoadError{failures: failures}
	}
	return rows, more, nil
}

func (d *Downloader) mobileLegacyCatalogPage(ctx context.Context, page int) ([]Drama, bool, error) {
	var tabs legacyTabList
	if err := d.fetchAPI(ctx, "/api/app/playlet-tab/all", nil, &tabs); err != nil {
		return nil, false, err
	}
	if len(tabs) == 0 {
		return nil, false, errors.New("黄果 API 未返回可用分类")
	}
	var rows []Drama
	var failures []error
	more := false
	pageSize := max(1, d.cfg.PageSize)
	for _, tab := range tabs {
		if err := ctx.Err(); err != nil {
			return rows, more, err
		}
		if tab.ID == "" {
			continue
		}
		var result listResponse
		err := d.fetchAPI(ctx, "/api/app/playlet/home/tab/"+url.PathEscape(tab.ID), map[string]string{
			"pageNumber": strconv.Itoa(page), "pageSize": strconv.Itoa(pageSize), "tabSortType": "1",
		}, &result)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", tab.Name, err))
			continue
		}
		more = more || len(result.List) >= pageSize
		for _, row := range result.List {
			if row.ID == "" {
				continue
			}
			row.Source, row.ChannelName = "cloudfront", tab.Name
			row.CategoryName = firstNonEmpty(row.CategoryName, row.CategoryNameSnake, row.Category, tab.Name)
			rows = append(rows, row)
		}
	}
	return rows, more, errors.Join(failures...)
}

func (d *Downloader) mobileAICatalogPage(ctx context.Context, page int) ([]Drama, bool, error) {
	base := d.huangguoAIContentBaseURL(ctx)
	categories := []string{"ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai"}
	results := make([]mobileCatalogPage, len(categories))
	slots := make(chan struct{}, 2)
	var group sync.WaitGroup
	for index, category := range categories {
		group.Go(func() {
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				results[index].err = ctx.Err()
				return
			}
			address := fmt.Sprintf("%s/api/videos/category/%s?sort=hot&page=%d&size=24", base, category, page)
			work := context.WithValue(ctx, providerTextValidatorKey{}, providerTextValidator(func(body, effectiveURL string) error {
				_, _, err := parseMobileAIPage(body, effectiveURL, category, page)
				return err
			}))
			body, effective, err := d.fetchProviderTextURL(work, address, base+"/"+category+"/")
			if err != nil {
				results[index].err = err
				return
			}
			rows, more, err := parseMobileAIPage(body, effective, category, page)
			results[index] = mobileCatalogPage{rows, more, err}
		})
	}
	group.Wait()
	var rows []Drama
	var failures []error
	more := false
	for index, result := range results {
		rows = append(rows, result.items...)
		more = more || result.more
		if result.err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", huangguoAITypeName(categories[index]), result.err))
		}
	}
	return rows, more, errors.Join(failures...)
}

func parseMobileAIPage(body, address, category string, page int) ([]Drama, bool, error) {
	var payload struct {
		Data struct {
			Items      *[]json.RawMessage `json:"items"`
			Pagination struct {
				Page  int  `json:"page"`
				Pages *int `json:"pages"`
			} `json:"pagination"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &payload); err != nil || payload.Data.Items == nil {
		return nil, false, errors.New("黄果分类未返回有效目录数据")
	}
	pagination := payload.Data.Pagination
	if pagination.Page != 0 && pagination.Page != page {
		return nil, false, errors.New("黄果分类返回了其他页")
	}
	rows := parseHuangguoAIJSONCards([]byte(body), address, huangguoAITypeName(category))
	more := len(*payload.Data.Items) >= 24
	if pagination.Pages != nil {
		more = page < *pagination.Pages
	}
	if len(rows) == 0 && (len(*payload.Data.Items) > 0 || more) {
		return nil, false, errors.New("黄果分类未解析到有效剧集")
	}
	return rows, more, nil
}

func (d *Downloader) mobileVideoCatalogPage(ctx context.Context, page int) ([]Drama, bool, error) {
	base := d.providerBaseURL(sourceHuangguoVideo)
	address := fmt.Sprintf("%s/videos?page=%d", base, page)
	body, effective, err := d.fetchProviderTextURL(ctx, address, base+"/")
	if err != nil {
		return nil, false, err
	}
	actual, err := url.Parse(effective)
	if err != nil || page > 1 && actual.Query().Get("page") != strconv.Itoa(page) {
		return nil, false, errors.New("黄果视频返回了其他页")
	}
	rows := parseHuangguoVideoCards(body, effective)
	if len(rows) == 0 {
		return nil, false, errors.New("黄果视频页面没有可识别的剧集内容")
	}
	document, err := html.Parse(strings.NewReader(body))
	if err != nil {
		return rows, false, err
	}
	more := false
	for _, node := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "a" }) {
		link, err := url.Parse(providerHTMLAttr(node, "href"))
		if err != nil {
			continue
		}
		link = actual.ResolveReference(link)
		next, _ := strconv.Atoi(link.Query().Get("page"))
		if link.Host == actual.Host && link.Path == actual.Path && next == page+1 && link.Query().Get("category") == "" {
			more = true
		}
	}
	return rows, more, nil
}
