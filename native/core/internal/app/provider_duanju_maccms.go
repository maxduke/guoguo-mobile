package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
)

var (
	maccmsPlayerData     = regexp.MustCompile(`(?s)player_aaaa\s*=\s*(\{.*?\})\s*</script>`)
	maccmsPlayerURLField = regexp.MustCompile(`(?i)"url"\s*:\s*"([^"]+)"`)
)

type maccmsSourceProfile struct {
	Source      string
	CategoryURL func(base, category string) string
	SearchURL   func(base, query string, page int) string
	PageURL     func(base, category string, page int) string
	Episodes    func(document *html.Node) []providerEpisode
}

var maccmsEpisodeLink = regexp.MustCompile(`(?i)/(?:vod/)?play/|/vodplay/|/drama-play|episode_id=`)

var maccmsDetailLink = regexp.MustCompile(`(?i)/(?:index\.php/vod/)?(?:voddetail|detail|vod|show|view|movie|drama|zywview|xzyxvd)/`)
var maccmsCategoryLink = regexp.MustCompile(`(?i)/(?:[a-z]*type|search|vodshow|label|gbook|rss|map|topic|actor)/`)

func maccmsIsCategoryLink(link string) bool {
	return maccmsCategoryLink.MatchString(link) || strings.Contains(link, "/show/") && strings.Contains(link, "---")
}

func maccmsEpisodeNodes(document *html.Node) []*html.Node {
	var nodes []*html.Node
	collect := func(match func(*html.Node) bool) {
		for _, list := range providerHTMLNodes(document, match) {
			nodes = append(nodes, providerHTMLNodes(list, func(node *html.Node) bool { return node.Data == "a" })...)
		}
	}
	for _, name := range []string{"content__playlist", "playlink", "pcDrama_catalogItem", "catalogItem", "playlist"} {
		collect(maccmsClassMatcher(name))
	}
	if len(nodes) == 0 {
		for _, name := range []string{"tab-pane", "playlist", "playList"} {
			collect(maccmsClassMatcher(name))
		}
	}
	if len(nodes) == 0 {
		nodes = providerHTMLNodes(document, func(node *html.Node) bool {
			return node.Data == "a" && maccmsEpisodeLink.MatchString(providerHTMLAttr(node, "href"))
		})
	}
	return nodes
}

func maccmsEpisodesFromDocument(document *html.Node) []providerEpisode {
	var episodes []providerEpisode
	seen := map[string]bool{}
	for index, anchor := range maccmsEpisodeNodes(document) {
		link := strings.TrimSpace(providerHTMLAttr(anchor, "href"))
		title := providerHTMLText(anchor)
		if link == "" {
			continue
		}
		if strings.Contains(title, "APP") || strings.Contains(title, "下载") {
			continue
		}
		key := link
		if seen[key] {
			continue
		}
		seen[key] = true
		episodes = append(episodes, providerEpisode{
			Key:   strconv.Itoa(index + 1),
			Title: title,
			URL:   link,
			Index: index + 1,
		})
	}
	return episodes
}

func maccmsCardCover(card *html.Node, pageURL string) string {
	for _, image := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "img" }) {
		for _, attribute := range []string{"data-original", "data-src", "src"} {
			if address := providerCoverAddress(providerHTMLAttr(image, attribute), pageURL); address != "" {
				return address
			}
		}
	}
	for _, anchor := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "a" }) {
		for _, attribute := range []string{"data-original", "data-src"} {
			if address := providerCoverAddress(providerHTMLAttr(anchor, attribute), pageURL); address != "" {
				return address
			}
		}
	}
	return ""
}

var maccmsAttributeTag = regexp.MustCompile(`<[^>]*>`)

func maccmsCleanAttribute(value string) string {
	cleaned := maccmsAttributeTag.ReplaceAllString(value, "")
	cleaned = html.UnescapeString(cleaned)
	return strings.Join(strings.Fields(cleaned), " ")
}

func maccmsCardTitle(card *html.Node) string {
	for _, attribute := range []string{"title", "alt"} {
		for _, node := range providerHTMLNodes(card, func(node *html.Node) bool {
			return node.Data == "a" || node.Data == "img"
		}) {
			if text := maccmsCleanAttribute(providerHTMLAttr(node, attribute)); text != "" {
				return text
			}
		}
	}
	for _, node := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "a" }) {
		if text := providerHTMLText(node); text != "" {
			return text
		}
	}
	return ""
}

func maccmsCardLink(card *html.Node, base string) string {
	for _, anchor := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "a" }) {
		link := providerHTMLAttr(anchor, "href")
		if link == "" || strings.Contains(link, "javascript:") || maccmsIsCategoryLink(link) || maccmsSourceIDFromURL(link) == "" {
			continue
		}
		if address := duanjuAbsolute(base, link); address != "" {
			return address
		}
	}
	return ""
}

func maccmsCardRemark(card *html.Node) string {
	for _, name := range []string{"meta-post-type2", "imagelabel", "module-item-note", "pic-text", "lastChapter", "SecondList_totalChapterNum", "SecondList_bookType"} {
		if node := providerHTMLFirstClass(card, name); node != nil {
			if text := providerHTMLText(node); text != "" {
				return text
			}
		}
	}
	return ""
}

func maccmsCards(document *html.Node, source, base string) []Drama {
	var cards []*html.Node
	seen := map[*html.Node]bool{}
	for _, name := range maccmsCardClasses {
		for _, node := range providerHTMLNodes(document, maccmsClassMatcher(name)) {
			if !seen[node] {
				seen[node] = true
				cards = append(cards, node)
			}
		}
	}
	if len(cards) == 0 {
		cards = maccmsAnchorCards(document)
	}
	var items []Drama
	ids := map[string]bool{}
	for _, card := range cards {
		link := maccmsCardLink(card, base)
		title := maccmsCardTitle(card)
		if link == "" || title == "" {
			continue
		}
		sourceID := maccmsSourceIDFromURL(link)
		if sourceID == "" || ids[sourceID] {
			continue
		}
		ids[sourceID] = true
		remark := maccmsCardRemark(card)
		items = append(items, Drama{
			ID:           providerDramaID(source, sourceID),
			Source:       source,
			SourceID:     sourceID,
			Title:        title,
			Cover:        maccmsCardCover(card, link),
			Remark:       remark,
			EpisodeCount: json.Number(strconv.Itoa(duanjuEpisodeNumber(remark, 0))),
			ChannelName:  duanjuSourceName(source),
		})
	}
	return items
}

func maccmsClassMatcher(name string) func(*html.Node) bool {
	return func(node *html.Node) bool {
		for _, value := range strings.Fields(providerHTMLAttr(node, "class")) {
			if value == name || strings.HasSuffix(value, "-"+name) {
				return true
			}
		}
		return false
	}
}

func maccmsAnchorCards(document *html.Node) []*html.Node {
	var cards []*html.Node
	seen := map[*html.Node]bool{}
	for _, anchor := range providerHTMLNodes(document, func(node *html.Node) bool {
		link := providerHTMLAttr(node, "href")
		return node.Data == "a" && maccmsDetailLink.MatchString(link) && !maccmsIsCategoryLink(link)
	}) {
		for parent := anchor.Parent; parent != nil && parent.Type == html.ElementNode; parent = parent.Parent {
			if seen[parent] {
				break
			}
			if parent.Data != "li" && parent.Data != "div" {
				continue
			}
			seen[parent] = true
			cards = append(cards, parent)
		}
	}
	return cards
}

var maccmsCardClasses = []string{
	"col-lg-2", "col-xl-2", "module-item", "module-poster-item", "public-list-box",
	"videoBox", "detail-list-item", "col-md-6", "col-6", "listItem", "FeaturedList_featuredItem",
	"BrowseList_listItem", "SecondList_secondListItem", "vodlist__item", "v_list",
	"entry-wrapper", "TagBookList_tagItem", "video-item", "vodlist_item", "myui-vodlist__box", "thumbnail",
}

var maccmsDetailPath = regexp.MustCompile(`(?i)/(?:voddetail|vodplay|detail|show|vod|drama|movie|tv|id|play|zywview|zywdetail|xzyxvd)/([0-9]+)(?:[-./]|$)`)

func maccmsSourceIDFromURL(link string) string {
	parsed, err := url.Parse(link)
	if err != nil {
		return ""
	}
	path := strings.TrimSuffix(parsed.Path, ".html")
	if matches := maccmsDetailPath.FindStringSubmatch(path + "/"); len(matches) > 1 {
		return matches[1]
	}
	cleaned := strings.Trim(path, "/")
	parts := strings.Split(cleaned, "/")
	for index := len(parts) - 1; index >= 0; index-- {
		candidate := strings.TrimSuffix(parts[index], ".html")
		if webProviderNumericID.MatchString(candidate) {
			return candidate
		}
		if _, tail, found := strings.Cut(candidate, "-"); found && webProviderNumericID.MatchString(tail) {
			return tail
		}
	}
	if id := parsed.Query().Get("id"); webProviderNumericID.MatchString(id) {
		return id
	}
	return ""
}

func (d *Downloader) fetchMaccmsCatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error) {
	base := d.duanjuBaseURL(source)
	address := ""
	switch source {
	case sourceHuaguo:
		if page <= 1 && strings.TrimSpace(category) == "" {
			address = base + "/"
		} else {
			class := strings.TrimSpace(category)
			if class == "" {
				class = "27"
			}
			address = fmt.Sprintf("%s/search.html?page=%d&searchtype=5&tid=%s&year=", base, page, url.QueryEscape(class))
		}
	case sourceWuguo:
		class := strings.TrimSpace(category)
		if class == "" {
			class = duanjuFirstCategory(sourceWuguo)
		}
		if !validDuanjuCategory(sourceWuguo, class) {
			return nil, false, errors.New("伍果分类已变化，请刷新分类")
		}
		if page < 1 {
			page = 1
		}
		address = fmt.Sprintf("%s/index.php/vod/search/class/%s/page/%d.html", base, url.PathEscape(class), page)
	case sourcePiguo:
		class := strings.TrimSpace(category)
		if class == "" {
			class = "67"
		}
		if page <= 1 {
			address = fmt.Sprintf("%s/p/66/c/%s", base, url.PathEscape(class))
		} else {
			address = fmt.Sprintf("%s/p/66/c/%s?year=&page=%d", base, url.PathEscape(class), page)
		}
	case sourceMiguo:
		if page > 1 {
			return []Drama{}, false, nil
		}
		class := firstNonEmpty(strings.TrimSpace(category), duanjuFirstCategory(sourceMiguo))
		if class == "netflix" {
			address = base + "/label/netflix.html"
		} else {
			address = fmt.Sprintf("%s/vodtype/%s.html", base, url.PathEscape(class))
		}
	case sourceShuangguo:
		class := strings.TrimSpace(category)
		path := "/show/26-----------.html"
		if class != "" && class != "all" {
			path = fmt.Sprintf("/show/26---%s--------.html", url.PathEscape(class))
		}
		if page > 1 {
			path = fmt.Sprintf("%s%d---.html", strings.TrimSuffix(path, "---.html"), page)
		}
		address = base + path
	default:
		return nil, false, errors.New("该站源没有网页目录")
	}
	document, finalURL, err := d.fetchProviderPage(ctx, address, base+"/", duanjuUserAgent)
	if err != nil {
		return nil, false, err
	}
	items := maccmsCards(document, source, finalURL)
	return items, source != sourceMiguo && maccmsHasMore(document, page, len(items)), nil
}

func (d *Downloader) fetchMaccmsDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error) {
	base := d.duanjuBaseURL(source)
	candidates := maccmsDetailCandidates(source, base, sourceID)
	var lastErr, contentErr error
	for _, address := range candidates {
		document, finalURL, err := d.fetchProviderPage(ctx, address, base+"/", duanjuUserAgent)
		if err != nil {
			lastErr = err
			continue
		}
		if actualID := maccmsSourceIDFromURL(finalURL); actualID != "" && actualID != sourceID {
			lastErr = errors.New("站源返回了其他剧集的详情页")
			continue
		}
		episodes := maccmsEpisodesFromDocument(document)
		if len(episodes) == 0 {
			contentErr = errors.New("当前详情未提供可播放分集，请稍后刷新")
			continue
		}
		drama := Drama{
			ID:          providerDramaID(source, sourceID),
			Source:      source,
			SourceID:    sourceID,
			Title:       maccmsDetailTitle(document),
			Intro:       maccmsDetailIntro(document),
			Cover:       maccmsDetailCover(document, finalURL),
			Category:    maccmsDetailCategory(document),
			ChannelName: duanjuSourceName(source),
		}
		var chapters []Chapter
		seen := map[int]bool{}
		for index, episode := range episodes {
			if id := maccmsSourceIDFromURL(episode.URL); id != "" && id != sourceID {
				continue
			}
			if maccmsDetailLink.MatchString(episode.URL) && !maccmsEpisodeLink.MatchString(episode.URL) {
				continue
			}
			number := duanjuEpisodeNumber(firstNonEmpty(episode.Title, episode.Key), index+1)
			if seen[number] {
				continue
			}
			link := duanjuAbsolute(finalURL, episode.URL)
			if link == "" {
				continue
			}
			seen[number] = true
			chapters = append(chapters, duanjuChapter(source, sourceID, number, episode.Title, link, link, base+"/"))
		}
		if len(chapters) == 0 {
			contentErr = errors.New("当前详情未提供本剧的可播放分集，请稍后刷新")
			continue
		}
		sortDuanjuChapters(chapters)
		drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
		return drama, chapters, nil
	}
	if contentErr != nil {
		lastErr = contentErr
	}
	if lastErr == nil {
		lastErr = errors.New("未找到该剧的详情页")
	}
	return Drama{}, nil, lastErr
}

func maccmsDetailCandidates(source, base, sourceID string) []string {
	switch source {
	case sourceWuguo:
		return []string{
			fmt.Sprintf("%s/index.php/vod/detail/id/%s.html", base, sourceID),
			fmt.Sprintf("%s/dramaDetail/%s.html", base, sourceID),
			fmt.Sprintf("%s/detail/%s.html", base, sourceID),
		}
	case sourcePiguo:
		return []string{
			fmt.Sprintf("%s/movie/%s", base, sourceID),
			fmt.Sprintf("%s/p/66/d/%s", base, sourceID),
		}
	case sourceHuaguo:
		return []string{
			fmt.Sprintf("%s/zywview/%s.html", base, sourceID),
			fmt.Sprintf("%s/zywdetail/%s.html", base, sourceID),
			fmt.Sprintf("%s/detail/%s.html", base, sourceID),
		}
	case sourceMiguo:
		return []string{fmt.Sprintf("%s/voddetail/%s.html", base, sourceID), fmt.Sprintf("%s/detail/%s.html", base, sourceID)}
	case sourceShuangguo:
		return []string{fmt.Sprintf("%s/vod/%s.html", base, sourceID), fmt.Sprintf("%s/detail/%s.html", base, sourceID)}
	default:
		return nil
	}
}

func maccmsDetailTitle(document *html.Node) string {
	return maccmsDetailTitleFor(document, "")
}

func maccmsDetailTitleFor(document *html.Node, source string) string {
	for _, name := range []string{"module-info-heading", "detail-title", "video-info-title", "page-title"} {
		if node := providerHTMLFirstClass(document, name); node != nil {
			if text := providerHTMLText(node); text != "" {
				return maccmsCleanTitle(text)
			}
		}
	}
	// 部分模板把集数、站名直接拼进 <title>，而正文标题元素是干净的。
	// 正文里也存在「猜你喜欢」这类栏目标题，必须跳过。
	for _, tag := range []string{"h1", "h2"} {
		for _, node := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == tag }) {
			text := maccmsCleanTitle(providerHTMLText(node))
			if text == "" || maccmsIsSectionHeading(text) {
				continue
			}
			return text
		}
	}
	if node := providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "title" }); len(node) > 0 {
		return maccmsCleanTitle(maccmsCleanAttribute(providerHTMLText(node[0])))
	}
	return ""
}

// 这些串一旦出现在标题中段，其后都是 SEO 拼接内容。
var maccmsTitleCutMarkers = []string{"详情介绍", "剧情介绍", "剧情简介", "在线播放", "在线观看", "免费观看"}

// 「剧名 2026 中国大陆 女频 / 甜宠 / ...」这类串由站点拼装，年份起就是说明文字。
// 要求年份前有空白，避免误伤「2001太空漫游」这类真实剧名。
var maccmsTitleYearMarker = regexp.MustCompile(`\s+20\d{2}(?:\s|$)`)

var maccmsTitleSuffixes = []string{"剧情介绍", "剧情简介", "在线观看", "免费观看", "高清完整版", "完整版", "全集", "在线播放", "已完结", "完结", "高清", "免费"}

// 更新状态常以「更新至第N集」这类形式贴在标题尾部。
var maccmsTitleUpdateTail = regexp.MustCompile(`\s*更新至(?:第)?\d+(?:集|话|期)?\s*$`)

// 章节序号用阿拉伯数字，中文数字（第二季）属于真实剧名，不能裁。
var maccmsTitlePartTail = regexp.MustCompile(`\s*第\s*\d+\s*[集话期]\s*$`)

// 画质标记以空格分隔贴在标题尾部，要求有分隔空白才不会切坏剧名本身。
var maccmsTitleQualityTail = regexp.MustCompile(`\s+(?:HD|HDR|4K|1080P|720P|蓝光|超清|高清|HD中字|中字|国语|粤语|日语)\s*$`)

func maccmsCleanTitle(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return ""
	}
	for _, marker := range maccmsTitleCutMarkers {
		at := strings.Index(text, marker)
		if at < 0 {
			continue
		}
		if at == 0 {
			text = strings.TrimSpace(text[len(marker):])
		} else {
			text = strings.TrimSpace(text[:at])
		}
		break
	}
	// 站点常在标题末尾追加「--站点名」。单连字符会用于「第二季」这类
	// 真实后缀，双连字符也可能出现在剧名的季数连接处，因此只在尾部不像
	// 季数/篇章标记时才裁掉。
	if at := strings.LastIndex(text, "--"); at > 0 {
		if tail := strings.TrimSpace(text[at+2:]); maccmsTitleTailIsSiteName(tail) {
			text = strings.TrimSpace(text[:at])
		}
	}
	if cut, _, found := strings.Cut(text, " - "); found {
		text = strings.TrimSpace(cut)
	}
	if cut, _, found := strings.Cut(text, " _ "); found {
		text = strings.TrimSpace(cut)
	}
	for _, separator := range []string{"-", "_", "|"} {
		for {
			cut, _, found := strings.Cut(text, separator)
			if !found {
				break
			}
			head := strings.TrimSpace(cut)
			if !maccmsTitleTailIsSeo(text[len(cut)+len(separator):]) {
				break
			}
			text = head
		}
	}
	if at := maccmsTitleYearMarker.FindStringIndex(text); at != nil && at[0] > 0 {
		text = strings.TrimSpace(text[:at[0]])
	}
	for changed := true; changed; {
		changed = false
		for _, tail := range []*regexp.Regexp{maccmsTitleUpdateTail, maccmsTitlePartTail, maccmsTitleQualityTail} {
			if trimmed := tail.ReplaceAllString(text, ""); trimmed != text && trimmed != "" {
				text = strings.TrimSpace(trimmed)
				changed = true
			}
		}
		for _, suffix := range maccmsTitleSuffixes {
			if strings.HasSuffix(text, suffix) && len(text) > len(suffix) {
				text = strings.TrimSpace(strings.TrimSuffix(text, suffix))
				changed = true
			}
		}
	}
	text = strings.Trim(text, "-_|·— ")
	if text == "" {
		return strings.TrimSpace(raw)
	}
	return text
}

var maccmsSectionHeadings = []string{
	"猜你喜欢", "猜你想看", "相关推荐", "播放列表", "热门推荐",
	"最新推荐", "热门视频", "为你推荐", "网友评论", "影片评论",
	"在线播放", "立即播放", "在线观看", "播放", "下载",
	"猜你喜歡", "猜你想看", "相關推薦", "播放列表", "熱門推薦",
	"最新推薦", "熱門視頻", "為你推薦", "網友評論", "影片評論",
	"在線播放", "立即播放", "在線觀看", "下集",
}

func maccmsIsSectionHeading(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	// 「同分類熱門推薦」「名字類似影片」这类栏目名随模板变化，按结尾判定更稳。
	for _, suffix := range []string{"推薦", "推荐", "類似影片", "类似影片", "相關影片", "相关影片"} {
		if strings.HasSuffix(trimmed, suffix) {
			return true
		}
	}
	for _, heading := range maccmsSectionHeadings {
		if trimmed == heading {
			return true
		}
	}
	return false
}

func maccmsTitleTailIsSiteName(tail string) bool {
	if tail == "" || utf8.RuneCountInString(tail) > 16 {
		return false
	}
	if strings.HasPrefix(tail, "第") {
		return false
	}
	for _, marker := range []string{"季", "部", "集", "篇", "卷", "话", "章"} {
		if strings.HasSuffix(tail, marker) {
			return false
		}
	}
	return true
}

func maccmsTitleTailIsSeo(tail string) bool {
	tail = strings.TrimSpace(tail)
	if tail == "" {
		return true
	}
	for _, marker := range []string{"短剧", "全集", "在线观看", "免费", "高清", "完整版", "视频", "剧场", "影院", "网"} {
		if strings.Contains(tail, marker) {
			return true
		}
	}
	return false
}

func maccmsDetailIntro(document *html.Node) string {
	for _, name := range []string{"module-info-introduction-content", "detail-content", "video-info-content", "introduction_introEllipsis"} {
		if node := providerHTMLFirstClass(document, name); node != nil {
			if text := providerHTMLText(node); text != "" {
				return truncate(text, 2000)
			}
		}
	}
	for _, meta := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "meta" }) {
		if strings.EqualFold(providerHTMLAttr(meta, "name"), "description") {
			if content := strings.TrimSpace(providerHTMLAttr(meta, "content")); content != "" {
				return truncate(content, 2000)
			}
		}
	}
	return ""
}

func maccmsDetailCover(document *html.Node, pageURL string) string {
	for _, name := range []string{"module-item-pic", "detail-pic", "video-info-pic", "pic"} {
		for _, node := range providerHTMLNodes(document, func(node *html.Node) bool { return providerHTMLClass(node, name) }) {
			if address := maccmsCardCover(node, pageURL); address != "" {
				return address
			}
		}
	}
	for _, image := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "img" }) {
		for _, attribute := range []string{"data-original", "data-src", "src"} {
			if address := providerCoverAddress(providerHTMLAttr(image, attribute), pageURL); address != "" {
				return address
			}
		}
	}
	return ""
}

func maccmsDetailCategory(document *html.Node) string {
	for _, name := range []string{"module-info-tag-link", "detail-tag", "video-info-actor"} {
		nodes := providerHTMLNodes(document, func(node *html.Node) bool { return providerHTMLClass(node, name) })
		if len(nodes) > 0 {
			var parts []string
			for _, anchor := range providerHTMLNodes(nodes[0], func(node *html.Node) bool { return node.Data == "a" }) {
				if text := providerHTMLText(anchor); text != "" {
					parts = append(parts, text)
				}
			}
			if len(parts) > 0 {
				return duanjuCSV(parts)
			}
		}
	}
	return ""
}

func (d *Downloader) searchMaccms(ctx context.Context, source, query string) ([]Drama, error) {
	items, _, err := d.searchMaccmsPage(ctx, source, query, 1)
	return items, err
}

func (d *Downloader) searchMaccmsPage(ctx context.Context, source, query string, page int) ([]Drama, bool, error) {
	base := d.duanjuBaseURL(source)
	var address string
	switch source {
	case sourceHuaguo:
		address = fmt.Sprintf("%s/search.html?searchword=%s&page=%d", base, url.QueryEscape(query), page)
	case sourceWuguo:
		address = fmt.Sprintf("%s/index.php/vod/search/page/%d/wd/%s.html", base, page, url.PathEscape(query))
	case sourcePiguo:
		address = fmt.Sprintf("%s/q/%s?page=%d", base, url.PathEscape(query), page)
	case sourceMiguo:
		address = fmt.Sprintf("%s/vodsearch/%s----------%d---.html", base, url.PathEscape(query), page)
	case sourceShuangguo:
		address = fmt.Sprintf("%s/search/%s----------%d---.html", base, url.PathEscape(query), page)
	default:
		return nil, false, errors.New("该站源不支持在线搜索")
	}
	document, finalURL, err := d.fetchProviderPage(ctx, address, base+"/", duanjuUserAgent)
	if err != nil {
		return nil, false, err
	}
	items := maccmsCards(document, source, finalURL)
	return items, maccmsHasMore(document, page, len(items)), nil
}

func maccmsPlayerURL(body string) string {
	if matches := maccmsPlayerData.FindStringSubmatch(body); len(matches) > 1 {
		if inner := maccmsPlayerURLField.FindStringSubmatch(matches[1]); len(inner) > 1 {
			return strings.ReplaceAll(inner[1], `\/`, `/`)
		}
	}
	for _, pattern := range []*regexp.Regexp{
		regexp.MustCompile(`(?i)\$\.url\s*=\s*"([^"]+)"`),
		// 部分站点的播放页把正片地址写成 const source = '...'，同一页面还会
		// 混入播放器自带的示例片地址（例如 artplayer 的 sample/test1.mp4），
		// 必须比通用兜底正则先匹配，否则会取到示例片而不是正片。
		regexp.MustCompile(`(?i)const\s+source\s*=\s*'([^']+)'`),
		regexp.MustCompile(`(?i)"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"`),
		regexp.MustCompile(`(?i)(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)`),
	} {
		for _, matches := range pattern.FindAllStringSubmatch(body, -1) {
			if len(matches) <= 1 {
				continue
			}
			candidate := strings.ReplaceAll(matches[1], `\/`, `/`)
			if maccmsIsPlaceholderAddress(candidate) {
				continue
			}
			return candidate
		}
	}
	return ""
}

// 站点会把未替换的模板串当地址输出（例如下载按钮写成
// https://mp4.#.mp4），这类串看着像媒体地址但不可播，必须剔除。
func maccmsIsPlaceholderAddress(address string) bool {
	trimmed := strings.TrimSpace(address)
	if !isProviderHTTPMediaURL(trimmed) {
		return true
	}
	if strings.ContainsAny(trimmed, "#{}") {
		return true
	}
	parsed, err := url.Parse(trimmed)
	if err != nil || parsed.Host == "" {
		return true
	}
	host := parsed.Hostname()
	if !strings.Contains(host, ".") {
		return true
	}
	parts := strings.Split(host, ".")
	return len(parts[len(parts)-1]) < 2
}

func maccmsNormalizePlaybackURL(raw string) string {
	raw = strings.TrimSpace(strings.ReplaceAll(raw, `\/`, `/`))
	raw = strings.Trim(raw, ",\\。，;；")
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.Contains(raw, "p.") || strings.Contains(raw, "c1.") {
		parts := strings.Split(raw, "/")
		if len(parts) >= 3 {
			base := strings.Join(parts[:len(parts)-2], "/")
			folder := parts[len(parts)-2]
			if decoded := maccmsDecodeUnicode(folder); decoded != folder {
				return base + "/" + url.PathEscape(decoded) + "/index.m3u8"
			}
		}
	}
	return raw
}

var maccmsUnicodeEscape = regexp.MustCompile(`\\?u([0-9a-fA-F]{4})`)

func maccmsDecodeUnicode(value string) string {
	return maccmsUnicodeEscape.ReplaceAllStringFunc(value, func(match string) string {
		hex := match[len(match)-4:]
		if number, err := strconv.ParseInt(hex, 16, 32); err == nil {
			return string(rune(number))
		}
		return match
	})
}
