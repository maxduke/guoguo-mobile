package app

// Protocol reference: Minireel/HGhub 8665ffc. The Go transport, validation and
// existing mobile identities remain local; see UPSTREAM.md.
import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var errHuangguoAPIUnavailable = errors.New("黄果当前线路未提供新接口")
var errHuangguoAPIRejected = errors.New("黄果接口拒绝了请求")
var errHuangguoAPIInvalid = errors.New("黄果接口数据无效")

type huangguoAPIReply struct {
	data   json.RawMessage
	status int
	base   string
}

type huangguoAPIRequestKey struct{}

// Only anonymous reads use this envelope. Account cookies, tokens and redirect
// destinations cannot become part of the provider or media session.
func (d *Downloader) requestHuangguoAPI(ctx context.Context, base, path string, force bool, methods ...string) (huangguoAPIReply, error) {
	reply := huangguoAPIReply{base: base}
	if err := ctx.Err(); err != nil {
		return reply, err
	}
	d.providerMu.Lock()
	unavailable := !force && d.huangguoAIUnsupported == base && time.Now().Before(d.huangguoAIUnsupportedUntil)
	d.providerMu.Unlock()
	if unavailable {
		return reply, errHuangguoAPIUnavailable
	}
	requestEnvelope := map[string]string{"method": "GET", "path": path, "body": "", "content_type": ""}
	if len(methods) > 0 && methods[0] == http.MethodPost {
		requestEnvelope["method"], requestEnvelope["body"], requestEnvelope["content_type"] = http.MethodPost, "e30=", "application/json"
	}
	body, _ := json.Marshal(requestEnvelope)
	ctx = context.WithValue(ctx, coverRequestKey{}, true)
	ctx = context.WithValue(ctx, coverSourceKey{}, sourceHuangguoAI)
	ctx = context.WithValue(ctx, huangguoAPIRequestKey{}, true)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/api/edge/request", bytes.NewReader(body))
	if err != nil {
		return reply, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Referer", base+"/")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	if noCache, _ := ctx.Value(providerTextNoCacheKey{}).(bool); noCache {
		req.Header.Set("Cache-Control", "no-cache")
	}
	client := *d.client
	client.Jar = nil
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := d.doPreparedCatalogRequestWithClient(req, 8*time.Second, nil, &client)
	if err != nil {
		return reply, err
	}
	defer response.Body.Close()
	reply.status = response.StatusCode
	raw, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024+1))
	if err != nil {
		return reply, err
	}
	if len(raw) > 2*1024*1024 {
		return reply, errors.New("黄果接口响应过大")
	}
	if response.StatusCode == 404 || response.StatusCode == 405 || response.StatusCode == 501 {
		return reply, d.rememberHuangguoAPIUnavailable(base)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 || catalogResponseBlockReason(response, raw) != "" {
		err := d.catalogResponseError(req, response, raw)
		if response.StatusCode == 401 || response.StatusCode == 403 || response.StatusCode == 429 || catalogResponseBlockReason(response, raw) != "" {
			return reply, fmt.Errorf("%w: %w", errHuangguoAPIRejected, err)
		}
		return reply, err
	}
	var envelope struct {
		Status *int            `json:"status"`
		Data   json.RawMessage `json:"data"`
	}
	if json.Unmarshal(raw, &envelope) != nil || envelope.Status == nil {
		return reply, d.rememberHuangguoAPIUnavailable(base)
	}
	if *envelope.Status != 1 {
		return reply, errHuangguoAPIRejected
	}
	if len(envelope.Data) == 0 || bytes.Equal(envelope.Data, []byte("null")) {
		return reply, errors.New("黄果接口缺少数据")
	}
	reply.data = envelope.Data
	if err := ctx.Err(); err != nil {
		return reply, err
	}
	d.providerMu.Lock()
	if d.huangguoAIUnsupported == base {
		d.huangguoAIUnsupported, d.huangguoAIUnsupportedUntil = "", time.Time{}
	}
	d.providerMu.Unlock()
	return reply, nil
}

func (d *Downloader) rememberHuangguoAPIUnavailable(base string) error {
	d.providerMu.Lock()
	d.huangguoAIUnsupported, d.huangguoAIUnsupportedUntil = base, time.Now().Add(5*time.Minute)
	d.providerMu.Unlock()
	return errHuangguoAPIUnavailable
}

func huangguoAPICanFallback(ctx context.Context, err error) bool {
	var backoff *requestBackoff
	return ctx.Err() == nil && !errors.Is(err, errHuangguoAPIRejected) && !errors.Is(err, errHuangguoAPIInvalid) && !errors.As(err, &backoff)
}

func huangguoAPIID(id string) bool {
	return len(id) > 0 && len(id) <= 20 && webProviderNumericID.MatchString(id)
}

func decodeHuangguoAPIMap(raw []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var data map[string]any
	if err := decoder.Decode(&data); err != nil || data == nil {
		return nil, errors.New("黄果接口数据格式不正确")
	}
	return data, nil
}

func huangguoAPIDrama(data map[string]any, base, category string) (Drama, bool) {
	if !huangguoAPIID(mapString(data, "id")) {
		return Drama{}, false
	}
	drama, ok := dramaFromAIMap(data, base+"/", category)
	if ok {
		// A hostname is not a genre. Leave unknown categories empty so a detail
		// refresh cannot replace the category already attached by the catalog.
		drama.ChannelName = ""
		drama.Heat = firstNonEmpty(mapString(data, "hot"), mapString(nestedMap(data, "counts"), "hot"))
		drama.OnlineDate = providerReleaseDate(mapString(data, "created_at"))
		if mapString(data, "is_finished") == "true" || mapString(data, "is_finished") == "1" {
			drama.ReleaseStatus = "finished"
		}
	}
	return drama, ok
}

func parseHuangguoAPIPage(raw []byte, base, category string, page int) ([]Drama, bool, error) {
	var data struct {
		Items      *[]json.RawMessage `json:"items"`
		Pagination struct {
			Page  int  `json:"page"`
			Pages *int `json:"pages"`
		} `json:"pagination"`
	}
	if json.Unmarshal(raw, &data) != nil || data.Items == nil || len(*data.Items) > 100 || data.Pagination.Page != page || data.Pagination.Pages == nil || *data.Pagination.Pages < 0 {
		return nil, false, errors.New("黄果接口未返回有效分页数据")
	}
	rows := make([]Drama, 0, len(*data.Items))
	seen := map[string]bool{}
	for _, raw := range *data.Items {
		item, err := decodeHuangguoAPIMap(raw)
		drama, ok := huangguoAPIDrama(item, base, category)
		if err != nil || !ok {
			return nil, false, errors.New("黄果接口目录资料不完整")
		}
		if !seen[drama.ID] {
			rows = append(rows, drama)
			seen[drama.ID] = true
		}
	}
	more := page < *data.Pagination.Pages
	if len(rows) == 0 && more {
		return nil, false, errors.New("黄果接口返回了空的中间页")
	}
	return rows, more, nil
}

func (d *Downloader) searchHuangguoAI(ctx context.Context, query string, page int) ([]Drama, bool, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, false, errors.New("搜索关键词不能为空")
	}
	page = max(1, page)
	path := "/api/search?" + url.Values{"q": {query}, "page": {strconv.Itoa(page)}, "size": {"24"}}.Encode()
	var rows []Drama
	var more bool
	_, err := d.readHuangguoAPI(ctx, path, func(data []byte, base string) error {
		var err error
		rows, more, err = parseHuangguoAPIPage(data, base, "", page)
		return err
	})
	if err == nil {
		return rows, more, nil
	}
	if !huangguoAPICanFallback(ctx, err) {
		return nil, false, err
	}
	return d.searchHuangguoAIHTML(ctx, query, page)
}

func (d *Downloader) fetchHuangguoAIDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if !huangguoAPIID(sourceID) {
		return d.fetchHuangguoAIHTMLDetail(ctx, sourceID)
	}
	drama, raw, err := d.fetchHuangguoAPIMetadata(ctx, sourceID)
	if err != nil {
		if huangguoAPICanFallback(ctx, err) {
			return d.fetchHuangguoAIHTMLDetail(ctx, sourceID)
		}
		return Drama{}, nil, err
	}
	base := d.huangguoAIContentBaseURL(ctx)
	var episodes struct {
		Episodes []struct {
			Number int    `json:"ep_num"`
			Title  string `json:"title"`
		} `json:"episodes"`
	}
	if json.Unmarshal(raw, &episodes) != nil || len(episodes.Episodes) > 10000 {
		return Drama{}, nil, errors.New("黄果接口分集格式不正确")
	}
	chapters := make([]Chapter, 0, len(episodes.Episodes))
	seen := map[int]bool{}
	for _, episode := range episodes.Episodes {
		if episode.Number <= 0 || seen[episode.Number] {
			return Drama{}, nil, errors.New("黄果接口分集身份不正确")
		}
		seen[episode.Number] = true
		number := strconv.Itoa(episode.Number)
		key := "ep-" + number
		if episode.Number == 1 {
			key = "1"
		}
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceHuangguoAI, sourceID, key), Source: sourceHuangguoAI,
			Title: firstNonEmpty(episode.Title, "第"+number+"集"), CurrentEpisode: rawEpisode(episode.Number), PageURL: huangguoAIPlaybackPageURL(base, sourceID, number)})
	}
	if len(chapters) == 0 && !valueEmpty(drama.EpisodeCount) {
		return Drama{}, nil, errors.New("黄果接口未返回分集列表")
	}
	sortProviderChapters(chapters)
	return drama, chapters, nil
}

func (d *Downloader) fetchHuangguoAPIMetadata(ctx context.Context, sourceID string) (Drama, json.RawMessage, error) {
	if !huangguoAPIID(sourceID) {
		return Drama{}, nil, errHuangguoAPIUnavailable
	}
	var drama Drama
	reply, err := d.readHuangguoAPI(ctx, "/api/videos/"+sourceID, func(raw []byte, base string) error {
		data, err := decodeHuangguoAPIMap(raw)
		if err != nil {
			return err
		}
		if mapString(data, "id") != sourceID {
			return fmt.Errorf("%w：作品身份不符", errHuangguoAPIInvalid)
		}
		var ok bool
		drama, ok = huangguoAPIDrama(data, base, "")
		if !ok {
			return fmt.Errorf("%w：详情资料不完整", errHuangguoAPIInvalid)
		}
		return nil
	})
	if err != nil {
		return Drama{}, nil, err
	}
	return drama, reply.data, nil
}

func (d *Downloader) huangguoAPIPlayback(ctx context.Context, sourceID, episode string) (providerMedia, string, error) {
	var media providerMedia
	reply, err := d.readHuangguoAPI(ctx, "/api/videos/"+sourceID+"/episodes/"+episode+"/playback", func(raw []byte, base string) error {
		data, err := decodeHuangguoAPIMap(raw)
		if err != nil {
			return err
		}
		if mapString(data, "id") != sourceID || mapString(data, "ep") != episode {
			return fmt.Errorf("%w：作品或分集身份不符", errHuangguoAPIInvalid)
		}
		if mapString(data, "manifest_method") != http.MethodGet {
			return fmt.Errorf("%w：播放请求方式不受支持", errHuangguoAPIInvalid)
		}
		media.URL = normalizeProviderMediaURL(base+"/", mapString(nestedMap(data, "streams"), "main"))
		if media.URL == "" {
			return fmt.Errorf("%w：缺少有效播放地址", errHuangguoAPIInvalid)
		}
		media.Referer = base + "/"
		credentials, err := huangguoPlaybackCredentials(media, nestedMap(data, "cdn"))
		if err != nil {
			return fmt.Errorf("%w：播放凭证无效", errHuangguoAPIInvalid)
		}
		media.credentials = credentials
		return nil
	}, http.MethodPost)
	return media, reply.base, err
}
