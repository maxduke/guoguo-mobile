package app

import (
	"context"
	"errors"
	"net/url"
	"strings"
)

// Resolve missing or expired artwork by identity, including old saved records.
func (d *Downloader) mobileCoverAddress(ctx context.Context, dramaID string) (string, error) {
	source, id, ok := splitProviderDramaID(dramaID)
	if !ok {
		return "", errors.New("无效的剧集 ID")
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
		base, path := huangguoAIBaseURL, "/detail/"+url.PathEscape(id)+"/"
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
		body, err := d.fetchProviderText(ctx, base+path, base+"/")
		if err != nil {
			return "", err
		}
		poster := huangguoClassBlock(body, "hg-web-detail__poster")
		address = resolveProviderURL(base+path, extractAttr(poster, "data-src", "data-original", "src"))
		if address == "" {
			for _, tag := range huangguoHTMLTag.FindAllString(body, -1) {
				if strings.HasPrefix(strings.ToLower(tag), "<meta") && extractAttr(tag, "property") == "og:image" {
					address = resolveProviderURL(base+path, extractAttr(tag, "content"))
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
