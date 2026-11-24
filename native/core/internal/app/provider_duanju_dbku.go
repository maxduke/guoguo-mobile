package app

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

var (
	dbkuEpisodeLink = regexp.MustCompile(`^/vodplay/([0-9]+)-[0-9]+-([0-9]+)\.html$`)
	dbkuPlayerData  = regexp.MustCompile(`\bplayer_data\s*=\s*\{`)
)

func dbkuEpisodeNumber(base, address, sourceID string) int {
	origin, _ := url.Parse(base)
	page, err := url.Parse(address)
	if err != nil || origin == nil || page.User != nil || providerMediaOrigin(page) != providerMediaOrigin(origin) {
		return 0
	}
	match := dbkuEpisodeLink.FindStringSubmatch(page.Path)
	if len(match) == 0 || match[1] != sourceID {
		return 0
	}
	number, err := strconv.Atoi(match[2])
	if err != nil {
		return 0
	}
	return number
}

func dbkuEpisodes(document *html.Node, base, sourceID string) []providerEpisode {
	var episodes []providerEpisode
	for _, anchor := range maccmsEpisodeNodes(document) {
		address := duanjuAbsolute(base, providerHTMLAttr(anchor, "href"))
		if number := dbkuEpisodeNumber(base, address, sourceID); number > 0 {
			episodes = append(episodes, providerEpisode{
				Title: providerHTMLText(anchor),
				URL:   address,
				Index: number,
			})
		}
	}
	return episodes
}

func dbkuMediaAddress(body string) string {
	match := dbkuPlayerData.FindStringIndex(body)
	if match == nil {
		return ""
	}
	var player struct {
		URL     string      `json:"url"`
		Encrypt json.Number `json:"encrypt"`
	}
	if err := json.NewDecoder(strings.NewReader(body[match[1]-1:])).Decode(&player); err != nil {
		return ""
	}

	address := player.URL
	switch player.Encrypt.String() {
	case "2":
		encoded := strings.NewReplacer("-", "+", "_", "/").Replace(address)
		decoded, err := base64.RawStdEncoding.DecodeString(strings.TrimRight(encoded, "="))
		if err != nil {
			return ""
		}
		address = string(decoded)
		fallthrough
	case "1":
		var err error
		address, err = url.PathUnescape(address)
		if err != nil {
			return ""
		}
	case "", "0":
	default:
		return ""
	}
	parsed, err := url.Parse(strings.TrimSpace(address))
	if err != nil || parsed.User != nil || providerMediaOrigin(parsed) != "https://vid.dbokutv.com" {
		return ""
	}
	path := strings.ToLower(parsed.Path)
	if !strings.HasSuffix(path, ".m3u8") && !strings.HasSuffix(path, ".mp4") {
		return ""
	}
	return parsed.String()
}

func (d *Downloader) resolveDbkuMedia(ctx context.Context, sourceID, chapterID, pageURL, base string) (providerMedia, error) {
	number := dbkuEpisodeNumber(base, pageURL, sourceID)
	if number == 0 || chapterID != providerChapterID(sourceDbku, sourceID, duanjuChapterKey(number)) {
		return providerMedia{}, errors.New("独播库分集与播放页不匹配，请刷新详情")
	}
	body, finalURL, err := d.fetchProviderTextURL(ctx, pageURL, base+"/")
	if err != nil {
		return providerMedia{}, err
	}
	if dbkuEpisodeNumber(base, finalURL, sourceID) != number {
		return providerMedia{}, errors.New("独播库返回了其他分集的播放页")
	}
	address := dbkuMediaAddress(body)
	if address == "" {
		return providerMedia{}, errors.New("独播库未返回有效播放地址，请刷新详情后重试")
	}
	return d.prepareWebProviderMedia(ctx, providerMedia{URL: address, Referer: base + "/"}, duanjuSourceName(sourceDbku))
}
