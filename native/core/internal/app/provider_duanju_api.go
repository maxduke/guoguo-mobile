package app

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const duanjuMaoguoKey = "d3dGiJc651gSQ8w1"

var duanjuMaoguoCharMap = map[rune]rune{
	'+': 'P', '/': 'X', '0': 'M', '1': 'U', '2': 'l', '3': 'E', '4': 'r', '5': 'Y', '6': 'W', '7': 'b', '8': 'd', '9': 'J',
	'A': '9', 'B': 's', 'C': 'a', 'D': 'I', 'E': '0', 'F': 'o', 'G': 'y', 'H': '_', 'I': 'H', 'J': 'G', 'K': 'i', 'L': 't',
	'M': 'g', 'N': 'N', 'O': 'A', 'P': '8', 'Q': 'F', 'R': 'k', 'S': '3', 'T': 'h', 'U': 'f', 'V': 'R', 'W': 'q', 'X': 'C',
	'Y': '4', 'Z': 'p', 'a': 'm', 'b': 'B', 'c': 'O', 'd': 'u', 'e': 'c', 'f': '6', 'g': 'K', 'h': 'x', 'i': '5', 'j': 'T',
	'k': '-', 'l': '2', 'm': 'z', 'n': 'S', 'o': 'Z', 'p': '1', 'q': 'V', 'r': 'v', 's': 'j', 't': 'Q', 'u': '7', 'v': 'D',
	'w': 'w', 'x': 'n', 'y': 'L', 'z': 'e',
}

func duanjuMD5(value string) string {
	sum := md5.Sum([]byte(value))
	return hex.EncodeToString(sum[:])
}

func duanjuMaoguoHeaders() (map[string]string, error) {
	session := strconv.FormatInt(time.Now().UnixMilli(), 10)
	payload := map[string]any{
		"static_score":  "0.8",
		"uuid":          "00000000-7fc7-08dc-0000-000000000000",
		"device-id":     "20250220125449b9b8cac84c2dd3d035c9052a2572f7dd0122edde3cc42a70",
		"mac":           "",
		"sourceuid":     "aa7de295aad621a6",
		"refresh-type":  "0",
		"model":         "22021211RC",
		"wlb-imei":      "",
		"client-id":     "aa7de295aad621a6",
		"brand":         "Redmi",
		"oaid":          "",
		"oaid-no-cache": "",
		"sys-ver":       "12",
		"trusted-id":    "",
		"phone-level":   "H",
		"imei":          "",
		"wlb-uid":       "aa7de295aad621a6",
		"session-id":    session,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	base := base64.StdEncoding.EncodeToString(encoded)
	mapped := make([]rune, 0, len(base))
	for _, char := range base {
		if replacement, found := duanjuMaoguoCharMap[char]; found {
			mapped = append(mapped, replacement)
			continue
		}
		mapped = append(mapped, char)
	}
	qmParams := string(mapped)
	signature := duanjuMD5("AUTHORIZATION=" +
		"app-version=10001" +
		"application-id=com.duoduo.read" +
		"channel=unknown" +
		"is-white=" +
		"net-env=5" +
		"platform=android" +
		"qm-params=" + qmParams +
		"reg=" + duanjuMaoguoKey)
	return map[string]string{
		"net-env":          "5",
		"reg":              "",
		"channel":          "unknown",
		"is-white":         "",
		"platform":         "android",
		"application-id":   "com.duoduo.read",
		"authorization":    "",
		"app-version":      "10001",
		"user-agent":       "webviewversion/0",
		"qm-params":        qmParams,
		"sign":             signature,
		"Accept":           "application/json",
		"X-Requested-With": "com.duoduo.read",
	}, nil
}

func maoguoDramaFromNode(node map[string]any, base string) Drama {
	id := duanjuFindString(node, "playlet_id", "playletId", "id")
	if id == "" {
		return Drama{}
	}
	total := duanjuFindInt(node, "total_episode_num", "totalEpisodeNum", "total")
	tags := duanjuStringList(node["tags"])
	if len(tags) == 0 {
		tags = duanjuStringList(node["tag_list"])
	}
	return Drama{
		ID:           providerDramaID(sourceMaoguo, id),
		Source:       sourceMaoguo,
		SourceID:     id,
		Title:        duanjuPlainText(duanjuFindString(node, "title", "playlet_name", "name")),
		Intro:        duanjuPlainText(duanjuFindString(node, "intro", "description", "desc")),
		Cover:        duanjuCover(base, node, "image_link", "imageLink", "cover", "cover_url"),
		EpisodeCount: json.Number(strconv.Itoa(total)),
		Category:     duanjuCSV(tags),
		Tags:         tags,
		ChannelName:  duanjuSourceName(sourceMaoguo),
	}
}

// The mobile API uses page numbers; Maoguo uses opaque next_id cursors.
// Each downloader keeps bounded, expiring cursor chains isolated by endpoint and tag.
type maoguoCatalogCache struct {
	mu       sync.Mutex
	sessions map[string]*maoguoCatalogSession
}

type maoguoCatalogSession struct {
	gate    chan struct{}
	usedAt  time.Time      // protected by cache.mu
	cursors map[int]string // request cursor for each page; empty after page 1 means end
	seenIDs map[string]int
}

func (d *Downloader) maoguoSession(base, tagID string) *maoguoCatalogSession {
	cache := &d.maoguoCatalog
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.sessions == nil {
		cache.sessions = map[string]*maoguoCatalogSession{}
	}
	now := time.Now()
	for key, session := range cache.sessions {
		if now.Sub(session.usedAt) > 30*time.Minute {
			delete(cache.sessions, key)
		}
	}
	key := base + "|" + tagID
	if session := cache.sessions[key]; session != nil {
		session.usedAt = now
		return session
	}
	if len(cache.sessions) >= 8 {
		oldestKey := ""
		oldest := now
		for key, session := range cache.sessions {
			if session.usedAt.Before(oldest) {
				oldestKey, oldest = key, session.usedAt
			}
		}
		delete(cache.sessions, oldestKey)
	}
	session := &maoguoCatalogSession{gate: make(chan struct{}, 1), usedAt: now}
	cache.sessions[key] = session
	return session
}

func (d *Downloader) fetchMaoguoCatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	if page < 1 {
		page = 1
	}
	if page > 100 {
		return nil, false, errors.New("猫果页码超出范围，请刷新目录")
	}
	tagID := strings.TrimSpace(category)
	if tagID == "" {
		tagID = "0"
	}
	if !validMaoguoCategory(tagID) {
		return nil, false, errors.New("猫果分类无效")
	}
	base := d.duanjuBaseURL(sourceMaoguo)
	session := d.maoguoSession(base, tagID)
	select {
	case session.gate <- struct{}{}:
	case <-ctx.Done():
		return nil, false, ctx.Err()
	}
	defer func() { <-session.gate }()
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	cursor := ""
	if page > 1 {
		var found bool
		cursor, found = session.cursors[page]
		if !found {
			return nil, false, errors.New("猫果分页游标已失效，请从第一页刷新目录")
		}
		if cursor == "" {
			return nil, false, nil
		}
	}
	headers, err := duanjuMaoguoHeaders()
	if err != nil {
		return nil, false, err
	}
	values := url.Values{"tag_id": {tagID}, "playlet_privacy": {"1"}, "operation": {"1"}}
	signText := "operation=1playlet_privacy=1tag_id=" + tagID
	if cursor != "" {
		values.Set("next_id", cursor)
		signText = "next_id=" + cursor + signText
	}
	values.Set("sign", duanjuMD5(signText+duanjuMaoguoKey))
	response, err := d.maoguoIndexJSON(ctx, duanjuRequest{Source: sourceMaoguo, Address: base + "/api/v1/playlet/index?" + values.Encode(), Referer: base + "/", Headers: headers})
	if err != nil {
		return nil, false, err
	}
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	data := duanjuFindMap(response, "data")
	if data == nil {
		return nil, false, errors.New("猫果未返回目录资料")
	}
	next := duanjuFindString(data, "next_id")
	if next == "0" {
		next = ""
	}
	if len(next) > 128 || strings.ContainsAny(next, "\x00\r\n") {
		return nil, false, errors.New("猫果返回了无效分页游标")
	}
	if page > 1 && next != "" {
		for priorPage, priorCursor := range session.cursors {
			if priorPage <= page && priorCursor == next {
				return nil, false, errors.New("猫果分页游标重复，请刷新目录")
			}
		}
	}
	rows := maoguoCatalogItems(data, base)
	items := make([]Drama, 0, len(rows))
	seen := map[string]bool{}
	for _, drama := range rows {
		if seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		if page > 1 {
			if prior, found := session.seenIDs[drama.ID]; found && prior < page {
				continue
			}
		}
		items = append(items, drama)
	}
	if len(items) == 0 && (len(rows) > 0 || next != "") {
		return nil, false, errors.New("猫果返回重复或空的后续页，请刷新目录")
	}
	priorCount := 0
	for _, prior := range session.seenIDs {
		if prior < page {
			priorCount++
		}
	}
	if priorCount+len(items) > 8192 {
		return nil, false, errors.New("猫果目录加载已达上限，请刷新目录")
	}
	if page == 1 {
		session.cursors = map[int]string{1: ""}
		session.seenIDs = map[string]int{}
	}
	// A successfully refreshed page invalidates all later pages in its chain.
	for laterPage := range session.cursors {
		if laterPage > page+1 {
			delete(session.cursors, laterPage)
		}
	}
	for id, priorPage := range session.seenIDs {
		if priorPage >= page {
			delete(session.seenIDs, id)
		}
	}
	for _, drama := range items {
		session.seenIDs[drama.ID] = page
	}
	session.cursors[page+1] = next
	return items, next != "", nil
}

// Numeric cursors may exceed float64's integer precision; retain the exact JSON number.
func (d *Downloader) maoguoIndexJSON(ctx context.Context, request duanjuRequest) (map[string]any, error) {
	payload, err := d.duanjuDo(ctx, request)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	var response map[string]any
	if err := decoder.Decode(&response); err != nil {
		return nil, errors.New("猫果返回的数据格式无法识别")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, errors.New("猫果返回的数据格式无法识别")
	}
	return response, nil
}

func maoguoCatalogItems(data map[string]any, base string) []Drama {
	var items []Drama
	for _, entry := range duanjuFindList(data, "list") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if drama := maoguoDramaFromNode(node, base); drama.ID != "" {
			items = append(items, drama)
		}
	}
	return items
}

func (d *Downloader) fetchMaoguoDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	headers, err := duanjuMaoguoHeaders()
	if err != nil {
		return Drama{}, nil, err
	}
	base := d.duanjuBaseURL(sourceMaoguo)
	signature := duanjuMD5("playlet_id=" + sourceID + duanjuMaoguoKey)
	address := fmt.Sprintf("%s/player/api/v1/playlet/info?playlet_id=%s&sign=%s", strings.TrimRight(maoguoReadURL, "/"), url.QueryEscape(sourceID), signature)
	response, err := d.duanjuJSON(ctx, duanjuRequest{Source: sourceMaoguo, Address: address, Referer: base + "/", Headers: headers})
	if err != nil {
		return Drama{}, nil, err
	}
	data := duanjuFindMap(response, "data")
	if data == nil {
		return Drama{}, nil, errors.New("猫果未返回剧集资料")
	}
	drama := maoguoDramaFromNode(data, base)
	drama.ID, drama.Source, drama.SourceID = providerDramaID(sourceMaoguo, sourceID), sourceMaoguo, sourceID
	var chapters []Chapter
	for index, entry := range duanjuFindList(data, "play_list") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		videoURL := duanjuFindString(node, "video_url", "videoUrl", "url")
		if videoURL == "" {
			continue
		}
		number := duanjuFindInt(node, "sort", "episode", "index")
		if number <= 0 {
			number = index + 1
		}
		chapters = append(chapters, duanjuChapter(sourceMaoguo, sourceID, number,
			duanjuFindString(node, "title", "name"), videoURL, "", base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("猫果未返回可播放分集")
	}
	sortDuanjuChapters(chapters)
	return drama, chapters, nil
}

const duanjuMaoguoTrackID = "ec1280db127955061754851657967"

func (d *Downloader) searchMaoguo(ctx context.Context, query string) ([]Drama, error) {
	items, _, err := d.searchMaoguoPage(ctx, query, 1)
	return items, err
}

func (d *Downloader) searchMaoguoPage(ctx context.Context, query string, page int) ([]Drama, bool, error) {
	headers, err := duanjuMaoguoHeaders()
	if err != nil {
		return nil, false, err
	}
	base := d.duanjuBaseURL(sourceMaoguo)
	signature := duanjuMD5(fmt.Sprintf("extend=page=%dread_preference=0track_id=%swd=%s%s", page, duanjuMaoguoTrackID, query, duanjuMaoguoKey))
	address := fmt.Sprintf("%s/api/v1/playlet/search?extend=&page=%d&wd=%s&read_preference=0&track_id=%s&sign=%s", base, page, url.QueryEscape(query), duanjuMaoguoTrackID, signature)
	response, err := d.duanjuJSON(ctx, duanjuRequest{Source: sourceMaoguo, Address: address, Referer: base + "/", Headers: headers})
	if err != nil {
		return nil, false, err
	}
	data := duanjuFindMap(response, "data")
	items := maoguoCatalogItems(data, base)
	more, hasFlag := duanjuMoreFlagPresent(data)
	if !hasFlag {
		if pages := duanjuFindInt(data, "pages", "total_page", "totalPage"); pages > 0 {
			more = page < pages
		}
	}
	return items, more, nil
}

func (d *Downloader) fetchMaoguoCategories(ctx context.Context) ([]nativeCategory, error) {
	headers, err := duanjuMaoguoHeaders()
	if err != nil {
		return nil, err
	}
	base := d.duanjuBaseURL(sourceMaoguo)
	signature := duanjuMD5("operation=1playlet_privacy=1tag_id=0" + duanjuMaoguoKey)
	address := fmt.Sprintf("%s/api/v1/playlet/index?tag_id=0&playlet_privacy=1&operation=1&sign=%s", base, signature)
	response, err := d.maoguoIndexJSON(ctx, duanjuRequest{Source: sourceMaoguo, Address: address, Referer: base + "/", Headers: headers})
	if err != nil {
		return nil, err
	}
	categories := []nativeCategory{{ID: "0", Name: "推荐"}}
	seen := map[string]bool{}
	for _, entry := range duanjuFindList(duanjuFindMap(response, "data"), "tag_items") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		id := duanjuFindString(node, "tag_id", "id")
		name := duanjuFindString(node, "tag_name", "name", "title")
		if !validMaoguoCategory(id) || seen[id] || name == "" || len([]rune(name)) > 24 {
			continue
		}
		seen[id] = true
		if id == "0" {
			categories[0].Name = name
		} else {
			categories = append(categories, nativeCategory{ID: id, Name: name})
		}
	}
	if len(seen) == 0 {
		return nil, errors.New("猫果分类列表为空，请稍后刷新")
	}
	return categories, nil
}

func guanguoClientInfo() string {
	stamp := strconv.FormatInt(time.Now().UnixMilli(), 10)
	if len(stamp) > 10 {
		stamp = stamp[len(stamp)-10:]
	}
	return duanjuMD5(stamp)
}

func guanguoQuery(values url.Values) url.Values {
	query := url.Values{
		"version_code":       {"1500"},
		"version_name":       {"1.5.0"},
		"device_name":        {"Pixel 8 Pro"},
		"device_type":        {"phone"},
		"is_first_day":       {"true"},
		"is_first_24h":       {"true"},
		"app_launch_way":     {"icon"},
		"default_homepage":   {"homepage_interaction"},
		"device_owning_firm": {"Google"},
		"font_scale":         {"default"},
		"os_type":            {"1"},
		"clientInfo":         {guanguoClientInfo()},
	}
	for key, entries := range values {
		query[key] = entries
	}
	return query
}

func guanguoDramaFromNode(node map[string]any, base string) Drama {
	id := duanjuFindString(node, "oneId", "one_id", "id")
	if id == "" {
		return Drama{}
	}
	tags := duanjuStringList(node["shortPlayTag"])
	return Drama{
		ID:           providerDramaID(sourceGuanguo, id),
		Source:       sourceGuanguo,
		SourceID:     id,
		Title:        duanjuFindString(node, "title", "name"),
		Intro:        duanjuFindString(node, "description", "desc"),
		Cover:        duanjuCover(base, node, "horzPoster", "vertPoster", "cover"),
		EpisodeCount: json.Number(strconv.Itoa(duanjuFindInt(node, "episodeCount", "totalEpisodeCount"))),
		Category:     duanjuCSV(tags),
		Tags:         tags,
		Views:        duanjuViewsText(duanjuFindInt(node, "viewCount")),
		ChannelName:  duanjuSourceName(sourceGuanguo),
	}
}

func duanjuViewsText(count int) string {
	if count <= 0 {
		return ""
	}
	if count >= 10000 {
		return strconv.FormatFloat(float64(count)/10000, 'f', 1, 64) + "万次播放"
	}
	return strconv.Itoa(count) + "次播放"
}

func (d *Downloader) fetchGuanguoCatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	if page > 500 {
		return nil, false, nil
	}
	base := d.duanjuBaseURL(sourceGuanguo)
	address := base + "/drama/home/search?" + guanguoQuery(nil).Encode()
	payload, err := json.Marshal(map[string]any{
		"audience":   "全部",
		"order":      "最新",
		"page":       page,
		"pageSize":   30,
		"searchWord": "",
		"subject":    strings.TrimSpace(category),
	})
	if err != nil {
		return nil, false, err
	}
	response, err := d.duanjuJSON(ctx, duanjuRequest{
		Source:  sourceGuanguo,
		Method:  http.MethodPost,
		Address: address,
		Referer: base + "/",
		Agent:   "okhttp/5.1.0",
		Headers: map[string]string{"Content-Type": "application/json; charset=utf-8"},
		Body:    payload,
	})
	if err != nil {
		return nil, false, err
	}
	var items []Drama
	for _, entry := range duanjuFindList(response, "data") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if drama := guanguoDramaFromNode(node, base); drama.ID != "" {
			items = append(items, drama)
		}
	}
	more, hasFlag := duanjuMoreFlagPresent(response)
	if !hasFlag {
		more = len(items) >= 30
	}
	return items, more, nil
}

func (d *Downloader) fetchGuanguoDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	base := d.duanjuBaseURL(sourceGuanguo)
	query := guanguoQuery(url.Values{
		"oneId":    {sourceID},
		"page":     {"1"},
		"pageSize": {"1000"},
		"userId":   {"0"},
		"queryAll": {"true"},
	})
	address := base + "/drama/home/shortVideoDetail?" + query.Encode()
	response, err := d.duanjuJSON(ctx, duanjuRequest{
		Source:  sourceGuanguo,
		Address: address,
		Referer: base + "/",
		Agent:   "okhttp/5.1.0",
		Headers: map[string]string{"Content-Type": "application/json; charset=utf-8"},
	})
	if err != nil {
		return Drama{}, nil, err
	}
	title := duanjuFindString(response, "title")
	if title == "" && duanjuFindList(response, "data") == nil {
		return Drama{}, nil, errors.New("观果详情接口当前返回空数据，该源暂时无法查看分集，请稍后重试或改用其他站源")
	}
	drama := Drama{
		ID:          providerDramaID(sourceGuanguo, sourceID),
		Source:      sourceGuanguo,
		SourceID:    sourceID,
		Title:       title,
		Intro:       duanjuFindString(response, "description"),
		Cover:       duanjuCover(base, response, "vertPoster", "horzPoster"),
		Category:    duanjuCSV(duanjuStringList(response["shortPlayTag"])),
		Tags:        duanjuStringList(response["shortPlayTag"]),
		ChannelName: duanjuSourceName(sourceGuanguo),
		Views:       duanjuViewsText(duanjuFindInt(response, "viewedEpisodeNumber")),
	}
	var chapters []Chapter
	for index, entry := range duanjuFindList(response, "data") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		videoURL := guanguoEpisodeURL(node)
		if videoURL == "" {
			continue
		}
		number := duanjuFindInt(node, "playOrder", "episodeOrder", "index", "episode")
		if number <= 0 {
			number = index + 1
		}
		chapters = append(chapters, duanjuChapter(sourceGuanguo, sourceID, number,
			duanjuFindString(node, "title", "name"), videoURL, "", base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("观果未返回可播放分集")
	}
	sortDuanjuChapters(chapters)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	if total := duanjuFindInt(response, "totalEpisodeCount"); total > len(chapters) {
		drama.EpisodeCount = json.Number(strconv.Itoa(total))
	}
	return drama, chapters, nil
}

func guanguoEpisodeURL(node map[string]any) string {
	if direct := duanjuFindString(node, "playUrl", "videoUrl", "play_url"); direct != "" {
		return direct
	}
	clarities := duanjuFindList(node, "videoClarityList")
	best := ""
	bestQuality := -1
	for _, entry := range clarities {
		clarity, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		address := duanjuFindString(clarity, "playUrl", "videoUrl", "url")
		if address == "" {
			continue
		}
		quality := duanjuFindInt(clarity, "clarity", "quality", "definition")
		if quality > bestQuality {
			best, bestQuality = address, quality
		}
	}
	return best
}

func (d *Downloader) searchGuanguo(ctx context.Context, query string) ([]Drama, error) {
	items, _, err := d.searchGuanguoPage(ctx, query, 1)
	return items, err
}

func (d *Downloader) searchGuanguoPage(ctx context.Context, query string, page int) ([]Drama, bool, error) {
	base := d.duanjuBaseURL(sourceGuanguo)
	address := base + "/drama/home/search?" + guanguoQuery(nil).Encode()
	payload, err := json.Marshal(map[string]any{
		"audience":   "全部",
		"order":      "最新",
		"page":       page,
		"pageSize":   30,
		"searchWord": query,
		"subject":    "",
	})
	if err != nil {
		return nil, false, err
	}
	response, err := d.duanjuJSON(ctx, duanjuRequest{
		Source:  sourceGuanguo,
		Method:  http.MethodPost,
		Address: address,
		Referer: base + "/",
		Agent:   "okhttp/5.1.0",
		Headers: map[string]string{"Content-Type": "application/json; charset=utf-8"},
		Body:    payload,
	})
	if err != nil {
		return nil, false, err
	}
	var items []Drama
	for _, entry := range duanjuFindList(response, "data") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if drama := guanguoDramaFromNode(node, base); drama.ID != "" {
			items = append(items, drama)
		}
	}
	return items, len(items) >= 30, nil
}
