package app

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

type mobileAsset struct {
	Identity string `json:"identity,omitempty"`
	Name     string `json:"name"`
	URL      string `json:"url,omitempty"`
	Body     string `json:"body,omitempty"`
}
type mobileDownloadPlan struct {
	RefreshOnResume bool              `json:"refreshOnResume,omitempty"`
	Input           string            `json:"input"`
	Assets          []mobileAsset     `json:"assets"`
	Inline          []mobileAsset     `json:"inline"`
	Headers         map[string]string `json:"headers"`
	ContentKey      string            `json:"contentKey"`
	Process         bool              `json:"process"`
}

// Build a durable offline resource graph. URLs point at upstream resources, not
// an ephemeral loopback server, so native background transfers can outlive Dart.
func (c *MobileClient) downloadPlan(ctx context.Context, request mobileRequest) (mobileDownloadPlan, error) {
	media, key, err := c.downloader.resolvePlaybackMedia(ctx, Task{DramaID: request.ID, Chapter: request.Chapter})
	if err != nil {
		return mobileDownloadPlan{}, publicError(err)
	}
	plan, err := c.planMobileMedia(providerMediaContext(ctx, media.credentials), media, key)
	if err != nil {
		return plan, err
	}
	if media.credentials != nil {
		plan.RefreshOnResume = media.credentials.cookie != ""
		headerRequest, _ := http.NewRequest(http.MethodGet, media.URL, nil)
		if err := media.credentials.apply(headerRequest); err != nil {
			return plan, publicError(err)
		}
		for _, name := range []string{"Referer", "Origin", "User-Agent"} {
			if value := headerRequest.Header.Get(name); value != "" {
				plan.Headers[name] = value
			}
		}
	}
	for i := range plan.Assets {
		asset := &plan.Assets[i]
		asset.Identity = asset.URL
		asset.URL, err = media.credentials.downloadURL(asset.URL)
		if err != nil {
			return plan, publicError(err)
		}
	}
	return plan, nil
}

func (c *MobileClient) planMobileMedia(ctx context.Context, media providerMedia, key []byte) (mobileDownloadPlan, error) {
	plan := mobileDownloadPlan{Input: "source.mp4", Assets: []mobileAsset{}, Inline: []mobileAsset{},
		Headers: map[string]string{"Referer": media.Referer, "User-Agent": userAgent}, ContentKey: hex.EncodeToString(media.CENCKey), Process: len(media.CENCKey) > 0}
	if media.Playlist == "" && !strings.HasSuffix(strings.ToLower(strings.Split(media.URL, "?")[0]), ".m3u8") {
		plan.Assets = append(plan.Assets, mobileAsset{Name: plan.Input, URL: media.URL})
		return plan, nil
	}
	plan.Input, plan.Process = "index.m3u8", true
	seen := map[string]string{media.URL: plan.Input}
	var playlist func(string, string, string, int) error
	playlist = func(remote, raw, name string, depth int) error {
		if depth > 4 {
			return errors.New("播放列表嵌套过深")
		}
		if raw == "" {
			var err error
			if media.credentials != nil {
				raw, remote, err = c.downloader.fetchMediaPlaylist(ctx, remote, media.Referer)
			} else {
				raw, remote, err = c.downloader.fetchProviderTextURL(ctx, remote, media.Referer)
			}
			if err != nil {
				return err
			}
		}
		if !strings.HasPrefix(strings.TrimSpace(raw), "#EXTM3U") {
			return errors.New("无效的播放列表")
		}
		if strings.Contains(raw, "#EXT-X-STREAM-INF") {
			// Resolve one rendition rather than downloading every video quality.
			if strings.Contains(raw, "TYPE=AUDIO") {
				return errors.New("独立音轨下载尚未支持，请选择其他清晰度")
			}
			lines := strings.Split(raw, "\n")
			for i, line := range lines {
				if strings.HasPrefix(line, "#EXT-X-STREAM-INF") {
					for _, next := range lines[i+1:] {
						if strings.TrimSpace(next) == "" || strings.HasPrefix(next, "#") {
							continue
						}
						base, _ := url.Parse(remote)
						child, err := url.Parse(strings.TrimSpace(next))
						if err != nil {
							return err
						}
						return playlist(base.ResolveReference(child).String(), "", name, depth+1)
					}
				}
			}
			return errors.New("主播放列表没有分集媒体")
		}
		if !strings.Contains(raw, "#EXT-X-ENDLIST") {
			return errors.New("未完成的直播列表不能离线下载")
		}
		base, err := url.Parse(remote)
		if err != nil {
			return err
		}
		register := func(reference string, isKey bool) (string, error) {
			parsed, err := url.Parse(reference)
			if err != nil {
				return "", err
			}
			address := base.ResolveReference(parsed).String()
			if !isProviderHTTPMediaURL(address) {
				return "", errors.New("播放列表包含非网络资源")
			}
			if existing, ok := seen[address]; ok {
				return existing, nil
			}
			if len(seen) >= 1500 {
				return "", errors.New("单集资源过多")
			}
			filename := fmt.Sprintf("asset_%04d.bin", len(seen))
			seen[address] = filename
			data := []byte(nil)
			if isKey {
				if len(media.HLSKey) > 0 {
					data = media.HLSKey
				}
				if len(key) > 0 && strings.Contains(parsed.Path, "/api/app/vid/sec") {
					data = key
				}
			}
			if len(data) > 0 {
				plan.Inline = append(plan.Inline, mobileAsset{Name: filename, Body: base64.StdEncoding.EncodeToString(data)})
			} else {
				plan.Assets = append(plan.Assets, mobileAsset{Name: filename, URL: address})
			}
			return filename, nil
		}
		lines := strings.Split(raw, "\n")
		for i, line := range lines {
			if strings.TrimSpace(line) == "" {
				continue
			}
			if !strings.HasPrefix(line, "#") {
				lines[i], err = register(strings.TrimSpace(line), false)
			} else {
				var replaceErr error
				lines[i] = hlsURIAttribute.ReplaceAllStringFunc(line, func(match string) string {
					parts := hlsURIAttribute.FindStringSubmatch(match)
					local, e := register(parts[1], strings.HasPrefix(line, "#EXT-X-KEY"))
					if e != nil {
						replaceErr = e
					}
					return `URI="` + local + `"`
				})
				err = replaceErr
			}
			if err != nil {
				return err
			}
		}
		plan.Inline = append(plan.Inline, mobileAsset{Name: name, Body: base64.StdEncoding.EncodeToString([]byte(strings.Join(lines, "\n")))})
		return nil
	}
	if err := playlist(media.URL, media.Playlist, plan.Input, 0); err != nil {
		return plan, publicError(err)
	}
	return plan, nil
}
