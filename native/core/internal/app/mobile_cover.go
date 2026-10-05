package app

import (
	"context"
	"errors"
	"net/url"
	"strings"
)

// Repair old legacy artwork without rewriting another provider's CDN URLs.
func mobileCoverURL(dramaID, address string) string {
	if rankingSourceID.MatchString(dramaID) {
		parsed, err := url.Parse(address)
		media, _ := url.Parse(defaultCDNURL)
		if err == nil && parsed.User == nil && parsed.Port() == "" &&
			strings.EqualFold(parsed.Hostname(), media.Hostname()) && parsed.Scheme == "https" {
			parsed.Scheme, parsed.Host = "", ""
			address = parsed.String()
		}
	}
	if resolved, ok := buildImageURL(address); ok {
		return resolved
	}
	return address
}

func (d *Downloader) coverReferer(ctx context.Context, address string) string {
	source, _ := ctx.Value(coverSourceKey{}).(string)
	if source == "cloudfront" {
		if parsed, err := url.Parse(address); err == nil && isHuangguoImageHost(parsed.Hostname()) {
			return d.providerBaseURL(sourceHuangguoAI) + "/"
		}
	}
	if source == sourceHuangdou {
		if parsed, err := url.Parse(address); err == nil &&
			(strings.EqualFold(parsed.Hostname(), "tideember.cc") || strings.EqualFold(parsed.Hostname(), "xqjurgek.top")) {
			return parsed.Scheme + "://" + parsed.Host + "/home"
		}
		return strings.TrimRight(d.huangdouRequestBaseURL(), "/") + "/home"
	}
	if isHuangguoProviderSource(source) {
		return d.providerBaseURL(source) + "/"
	}
	return imageReferer(address)
}

// Resolve missing or expired artwork by identity, including old saved records.
func (d *Downloader) mobileCoverAddress(ctx context.Context, dramaID string) (string, error) {
	source, id, ok := splitProviderDramaID(dramaID)
	if !ok {
		// The original Huangguo API uses bare IDs, including saved favorites.
		if !rankingSourceID.MatchString(dramaID) {
			return "", errors.New("无效的剧集 ID")
		}
		var detail Drama
		if err := d.fetchAPI(ctx, "/api/app/playlet/detail/"+url.PathEscape(dramaID), nil, &detail); err != nil {
			return "", err
		}
		if detail.ID != "" && detail.ID != dramaID {
			return "", errors.New("详情与请求剧集不符")
		}
		address := bestDramaCover(detail)
		if address == "" {
			return "", errors.New("该剧暂未提供封面")
		}
		return address, nil
	}
	if adapter, found := d.mobileSource(source); found {
		row, _, err := adapter.detail(ctx, id)
		if err != nil {
			return "", err
		}
		address := bestDramaCover(row)
		if address == "" {
			return "", errors.New("该剧暂未提供封面")
		}
		return address, nil
	}
	var address string
	switch source {
	case sourceHuangdou:
		if !rankingSourceID.MatchString(id) {
			return "", errors.New("无效的剧集 ID")
		}
		var decoded any
		if err := newHuangdouAPIClient(d).call(ctx, "/drama/detail", map[string]any{"id": id}, &decoded); err != nil {
			return "", err
		}
		drama := huangdouDramaFromMap(huangdouDataMap(decoded))
		if drama.ID != dramaID {
			return "", errors.New("详情与请求剧集不符")
		}
		address = bestDramaCover(drama)
	case sourceHuangguoAI, sourceHuangguoVideo:
		base, path := d.huangguoAIContentBaseURL(ctx), "/video/"+url.PathEscape(id)+"/"
		if source == sourceHuangguoVideo {
			base = huangguoVideoBaseURL
			parts := strings.Split(id, "/")
			if len(parts) == 1 {
				parts = []string{"series", id}
			}
			if len(parts) != 2 || (parts[0] != "series" && parts[0] != "video") || !rankingSourceID.MatchString(parts[1]) {
				return "", errors.New("无效的剧集 ID")
			}
			path = "/" + parts[0] + "/" + url.PathEscape(parts[1])
		} else if !rankingSourceID.MatchString(id) {
			return "", errors.New("无效的剧集 ID")
		}
		body, effectiveURL, err := d.fetchHuangguoDetailText(ctx, base+path, base+"/", source, id)
		if err != nil {
			return "", err
		}
		if source == sourceHuangguoAI {
			if err := validateHuangguoAIDetailPage(body, effectiveURL, id); err != nil {
				return "", err
			}
			patch, err := parseHuangguoSortDetail(body, effectiveURL, Drama{ID: dramaID, Source: source, SourceID: id})
			if err == nil {
				address = bestDramaCover(patch)
			}
		}
		poster := huangguoClassBlock(body, "hg-web-detail__poster")
		if address == "" {
			address = huangguoArtworkAddress(extractAttr(poster, "data-src", "data-original", "src"), effectiveURL, body)
		}
		if address == "" {
			for _, tag := range huangguoHTMLTag.FindAllString(body, -1) {
				if strings.HasPrefix(strings.ToLower(tag), "<meta") && extractAttr(tag, "property") == "og:image" {
					address = resolveProviderURL(effectiveURL, extractAttr(tag, "content"))
					break
				}
			}
		}
	case sourceHongguo:
		patch, err := d.fetchDramaSortMetadata(ctx, Drama{ID: dramaID})
		address = bestDramaCover(patch)
		if address == "" && err != nil {
			return "", err
		}
	default:
		return "", errors.New("未知站源")
	}
	if address == "" {
		return "", errors.New("该剧暂未提供封面")
	}
	return address, nil
}
