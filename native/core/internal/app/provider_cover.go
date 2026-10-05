package app

import (
	"context"
	"errors"
	"html"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var coverMetaTag = regexp.MustCompile(`(?is)<meta\b[^>]*>`)

func (d *Downloader) fetchDramaCoverAddress(ctx context.Context, drama Drama) (string, error) {
	source, id, ok := splitProviderDramaID(drama.ID)
	if !ok {
		return "", errors.New("无效的剧集 ID")
	}
	switch source {
	case sourceHongguo:
		if !hongguoNumericID.MatchString(id) {
			return "", errors.New("无效的红果剧集 ID")
		}
		result, err := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": id})
		if err != nil {
			return "", err
		}
		row := nestedMap(result, "data", "video_data")
		if mapString(row, "series_id_str", "series_id") != id {
			return "", errors.New("红果详情返回了其他剧集")
		}
		return hongguoCoverAddress(mapString(row, "series_cover", "cover")), nil
	case sourceHuangdou:
		if !rankingSourceID.MatchString(id) {
			return "", errors.New("无效的黄豆剧集 ID")
		}
		var decoded any
		if err := newHuangdouAPIClient(d).call(ctx, "/drama/detail", map[string]any{"id": id}, &decoded); err != nil {
			return "", err
		}
		row := huangdouDataMap(decoded)
		if strings.TrimPrefix(mapString(row, "id", "drama_id"), "rp_") != id {
			return "", errors.New("黄豆详情返回了其他剧集")
		}
		return providerCoverAddress(bestDramaCover(huangdouDramaFromMap(row)), ""), nil
	case sourceHuangguoAI, sourceHuangguoVideo:
		pageURL, err := huangguoSortDetailURL(source, id)
		if source == sourceHuangguoAI {
			pageURL = huangguoAIPlaybackPageURL(d.huangguoAIContentBaseURL(ctx), id, "1")
		}
		if err != nil {
			return "", err
		}
		body, effectiveURL, err := d.fetchHuangguoDetailText(ctx, pageURL, providerRefererForURL(pageURL, ""), source, id)
		if err != nil {
			return "", err
		}
		patch, err := parseHuangguoSortDetail(body, effectiveURL, Drama{ID: drama.ID, Source: source, SourceID: id})
		return bestDramaCover(patch), err
	}
	return "", errors.New("该站源暂无封面补齐接口")
}

func providerCoverAddress(value any, pageURL string) string {
	switch item := value.(type) {
	case []any:
		for _, value := range item {
			if address := providerCoverAddress(value, pageURL); address != "" {
				return address
			}
		}
	case map[string]any:
		for _, key := range []string{"url", "contentUrl", "thumbnailUrl"} {
			if address := providerCoverAddress(item[key], pageURL); address != "" {
				return address
			}
		}
	case string:
		if strings.TrimSpace(item) == "" {
			return ""
		}
		address, err := url.Parse(strings.TrimSpace(item))
		if err != nil {
			return ""
		}
		if base, err := url.Parse(pageURL); err == nil && base.IsAbs() {
			address = base.ResolveReference(address)
		} else if strings.HasPrefix(strings.TrimSpace(item), "//") {
			address.Scheme = "https"
		}
		// Some catalogs publish HTTP artwork on HTTPS-capable CDNs. Never
		// downgrade the image request or permit nonstandard ports.
		if address.Scheme == "http" && address.Port() == "" {
			address.Scheme = "https"
		}
		if validImageURL(address) {
			return address.String()
		}
	}
	return ""
}

func huangguoCDNBaseURL(rawHTML string) string {
	match := huangguoCDNDomain.FindStringSubmatch(rawHTML)
	if len(match) < 2 {
		return ""
	}
	raw := strings.TrimSpace(html.UnescapeString(strings.ReplaceAll(match[1], `\/`, `/`)))
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "//") {
		raw = "https:" + raw
	} else if !strings.Contains(raw, "://") {
		raw = "https://" + strings.TrimLeft(raw, "/")
	}
	address, err := url.Parse(raw)
	if err != nil || !validImageURL(address) {
		return ""
	}
	address.Path = ""
	address.RawQuery = ""
	address.Fragment = ""
	return strings.TrimRight(address.String(), "/") + "/"
}

func huangguoArtworkAddress(value any, pageURL, rawHTML string) string {
	switch item := value.(type) {
	case []any:
		for _, value := range item {
			if address := huangguoArtworkAddress(value, pageURL, rawHTML); address != "" {
				return address
			}
		}
	case map[string]any:
		for _, key := range []string{"url", "src", "path", "cover", "coverUrl", "cover_url", "image", "pic", "poster", "thumbnailUrl"} {
			if address := huangguoArtworkAddress(item[key], pageURL, rawHTML); address != "" {
				return address
			}
		}
	case string:
		raw := strings.TrimSpace(html.UnescapeString(strings.ReplaceAll(item, `\/`, `/`)))
		if raw == "" {
			return ""
		}
		address, err := url.Parse(raw)
		if err != nil {
			return ""
		}
		if address.IsAbs() || strings.HasPrefix(raw, "//") {
			return providerCoverAddress(raw, pageURL)
		}
		if base := huangguoCDNBaseURL(rawHTML); base != "" {
			if resolved := providerCoverAddress(raw, base); resolved != "" {
				return resolved
			}
		}
		return providerCoverAddress(raw, pageURL)
	}
	return ""
}

var huangguoCDNDomain = regexp.MustCompile(`(?is)(?:["']?cdnDomain["']?)\s*[:=]\s*["']([^"']+)["']`)
