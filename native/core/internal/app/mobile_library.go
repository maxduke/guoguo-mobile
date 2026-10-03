package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/ulikunitz/xz"
	boundedxz "github.com/xi2/xz"
)

const (
	mobileLibraryMaxBytes   = 32 << 20
	mobileLibraryMaxEntries = 200000
	// Upstream's xz -9 exports use a 64 MiB dictionary. Never trust a file's
	// advertised dictionary size; xi2/xz rejects it before allocation.
	// ulikunitz ReaderConfig.DictCap is a minimum, not a memory limit.
	mobileLibraryXZDictionary = 64 << 20
)

var mobileLibraryXZMagic = []byte{0xfd, '7', 'z', 'X', 'Z', 0}

type mobileLibraryEntry struct {
	ID            string   `json:"id"`
	Source        string   `json:"source,omitempty"`
	SourceID      string   `json:"sourceId,omitempty"`
	Title         string   `json:"title,omitempty"`
	Description   string   `json:"description,omitempty"`
	Cover         string   `json:"cover,omitempty"`
	Episodes      int      `json:"episodes,omitempty"`
	Category      string   `json:"category,omitempty"`
	VIP           *bool    `json:"vip,omitempty"`
	Heat          string   `json:"heat,omitempty"`
	Views         string   `json:"views,omitempty"`
	OnlineDate    string   `json:"onlineDate,omitempty"`
	Tags          []string `json:"tags,omitempty"`
	ReleaseStatus string   `json:"releaseStatus,omitempty"`
}

type mobileLibraryDocument struct {
	App        string               `json:"app"`
	Kind       string               `json:"kind"`
	Version    int                  `json:"version"`
	ExportedAt time.Time            `json:"exportedAt"`
	Count      int                  `json:"count"`
	Dramas     []mobileLibraryEntry `json:"dramas"`
}

type mobileLibraryBatch struct {
	rows       []mobileLibraryEntry
	rejected   int
	skipped    int
	duplicates int
}

type mobileLibraryReader struct {
	ctx    context.Context
	reader io.Reader
	count  int64
}

func (r *mobileLibraryReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	n, err := r.reader.Read(p)
	r.count += int64(n)
	if r.count > mobileLibraryMaxBytes {
		return n, errors.New("剧库文件超过 32 MB")
	}
	return n, err
}

func readMobileLibrary(ctx context.Context, path string) (mobileLibraryBatch, error) {
	if err := ctx.Err(); err != nil {
		return mobileLibraryBatch{}, err
	}
	if !filepath.IsAbs(path) {
		return mobileLibraryBatch{}, errors.New("剧库文件路径无效")
	}
	file, err := os.Open(path)
	if err != nil {
		return mobileLibraryBatch{}, fmt.Errorf("无法读取剧库文件: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return mobileLibraryBatch{}, err
	}
	if !info.Mode().IsRegular() || info.Size() > mobileLibraryMaxBytes {
		return mobileLibraryBatch{}, errors.New("剧库文件超过 32 MB 或不是普通文件")
	}
	compressed := &mobileLibraryReader{ctx: ctx, reader: io.LimitReader(file, mobileLibraryMaxBytes+1)}
	buffered := bufio.NewReader(compressed)
	magic, _ := buffered.Peek(len(mobileLibraryXZMagic))
	var reader io.Reader = buffered
	if bytes.Equal(magic, mobileLibraryXZMagic) {
		reader, err = boundedxz.NewReader(buffered, mobileLibraryXZDictionary)
		if err != nil {
			return mobileLibraryBatch{}, fmt.Errorf("剧库 XZ 文件无法解压: %w", err)
		}
	}
	decoded := &mobileLibraryReader{ctx: ctx, reader: io.LimitReader(reader, mobileLibraryMaxBytes+1)}
	payload, err := io.ReadAll(decoded)
	if err != nil {
		return mobileLibraryBatch{}, fmt.Errorf("剧库文件读取或解压失败: %w", err)
	}
	if !utf8.Valid(payload) {
		return mobileLibraryBatch{}, errors.New("剧库 JSON 不是有效的 UTF-8")
	}
	return decodeMobileLibrary(ctx, payload)
}

// Parse the entries incrementally so the entry limit applies before allocating
// an unbounded slice. No state is changed until every field and the EOF validate.
func decodeMobileLibrary(ctx context.Context, payload []byte) (mobileLibraryBatch, error) {
	var batch mobileLibraryBatch
	if len(payload) > mobileLibraryMaxBytes {
		return batch, errors.New("剧库文件超过 32 MB")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	first, err := decoder.Token()
	if err != nil || first != json.Delim('{') {
		return batch, errors.New("剧库文件必须是 JSON 对象")
	}
	seenFields := map[string]bool{}
	positions := map[string]int{}
	kind, version, declaredCount, count := "", 0, -1, 0
	for decoder.More() {
		if err := ctx.Err(); err != nil {
			return mobileLibraryBatch{}, err
		}
		token, err := decoder.Token()
		if err != nil {
			return mobileLibraryBatch{}, errors.New("剧库文件不完整")
		}
		name, ok := token.(string)
		if !ok || seenFields[name] {
			return mobileLibraryBatch{}, errors.New("剧库字段重复或无效")
		}
		seenFields[name] = true
		switch name {
		case "kind":
			err = decoder.Decode(&kind)
		case "version":
			err = decoder.Decode(&version)
		case "count":
			err = decoder.Decode(&declaredCount)
		case "format", "favorites", "history":
			return mobileLibraryBatch{}, errors.New("这是记录备份或其他格式，不能作为剧库导入")
		case "dramas":
			token, err = decoder.Token()
			if err != nil || token != json.Delim('[') {
				return mobileLibraryBatch{}, errors.New("剧库文件缺少剧集列表")
			}
			for decoder.More() {
				if err := ctx.Err(); err != nil {
					return mobileLibraryBatch{}, err
				}
				count++
				if count > mobileLibraryMaxEntries {
					return mobileLibraryBatch{}, errors.New("剧库条目超过 20 万条")
				}
				var entry mobileLibraryEntry
				if err = decoder.Decode(&entry); err != nil {
					return mobileLibraryBatch{}, errors.New("剧库条目格式无效或文件不完整")
				}
				normalized, disposition := normalizeMobileLibraryEntry(entry)
				switch disposition {
				case "skipped":
					batch.skipped++
				case "rejected":
					batch.rejected++
				default:
					if index, exists := positions[normalized.ID]; exists {
						batch.rows[index] = completeMobileLibraryEntry(batch.rows[index], normalized)
						batch.duplicates++
					} else {
						positions[normalized.ID] = len(batch.rows)
						batch.rows = append(batch.rows, normalized)
					}
				}
			}
			token, err = decoder.Token()
			if err != nil || token != json.Delim(']') {
				return mobileLibraryBatch{}, errors.New("剧库文件不完整")
			}
		default:
			var ignored json.RawMessage
			err = decoder.Decode(&ignored)
		}
		if err != nil {
			return mobileLibraryBatch{}, errors.New("剧库文件字段格式无效")
		}
	}
	last, err := decoder.Token()
	if err != nil || last != json.Delim('}') {
		return mobileLibraryBatch{}, errors.New("剧库文件不完整")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return mobileLibraryBatch{}, errors.New("剧库文件包含额外或不完整的内容")
	}
	if kind != "library" {
		return mobileLibraryBatch{}, errors.New("这不是剧库文件，请选择 kind=library 的剧库")
	}
	if version != 1 {
		return mobileLibraryBatch{}, errors.New("剧库文件版本不兼容")
	}
	if !seenFields["dramas"] {
		return mobileLibraryBatch{}, errors.New("剧库文件缺少剧集列表")
	}
	if seenFields["count"] && (declaredCount < 0 || declaredCount != count) {
		return mobileLibraryBatch{}, errors.New("剧库条目计数不一致，文件可能不完整")
	}
	if batch.rows == nil {
		batch.rows = []mobileLibraryEntry{}
	}
	return batch, nil
}

func mobileLibraryText(value string, limit int) string {
	value = strings.TrimSpace(value)
	if len(value) <= limit {
		return value
	}
	value = value[:limit]
	for !utf8.ValidString(value) {
		value = value[:len(value)-1]
	}
	return value
}

func normalizeMobileLibraryEntry(entry mobileLibraryEntry) (mobileLibraryEntry, string) {
	rawSource, sourceID, found := strings.Cut(strings.TrimSpace(entry.ID), ":")
	if !found && rankingSourceID.MatchString(strings.TrimSpace(entry.ID)) && (entry.Source == "huangguo" || entry.Source == "cloudfront") {
		rawSource, sourceID, found = "cloudfront", strings.TrimSpace(entry.ID), true
	}
	if !found || rawSource == "" || sourceID == "" {
		return entry, "rejected"
	}
	source := canonicalProviderSource(rawSource)
	if !isHuangguoProviderSource(source) && source != "cloudfront" {
		return entry, "skipped"
	}
	if source == "cloudfront" && !rankingSourceID.MatchString(sourceID) {
		return entry, "rejected"
	}
	if entry.Source != "" && canonicalProviderSource(entry.Source) != source && !(entry.Source == "huangguo" && matchesSourceFilter(source, "huangguo")) {
		return entry, "rejected"
	}
	if entry.SourceID != "" && strings.TrimSpace(entry.SourceID) != sourceID {
		return entry, "rejected"
	}
	if len(sourceID) > 32768 || strings.ContainsRune(sourceID, 0) || source == sourceHongguo && !hongguoNumericID.MatchString(sourceID) {
		return entry, "rejected"
	}
	// Translate the new exchange payload format at the boundary, retaining the
	// mobile business keys used by favorites, history, episodes and downloads.
	if source == sourceFanguo || source == sourceXingguo {
		if id, encoded, exists := strings.Cut(sourceID, "~"); exists {
			value, err := base64.RawURLEncoding.DecodeString(encoded)
			if err != nil || !utf8.Valid(value) || id == "" {
				return entry, "rejected"
			}
			if source == sourceFanguo {
				sourceID = id
				if len(value) > 0 {
					sourceID += "#" + string(value)
				}
			} else {
				intro := string(value)
				if intro != "" && strings.HasPrefix(entry.Description, intro) {
					intro = entry.Description
				}
				sourceID = id
				if intro != "" {
					sourceID += "@" + intro
				}
			}
		}
	}
	entry.ID, entry.Source, entry.SourceID = providerDramaID(source, sourceID), source, sourceID
	entry.Title = mobileLibraryText(entry.Title, 4096)
	if entry.Title == "" {
		return entry, "rejected"
	}
	entry.Description = mobileLibraryText(entry.Description, 20000)
	entry.Cover = mobileLibraryText(entry.Cover, 4096)
	entry.Category = mobileLibraryText(entry.Category, 512)
	entry.Heat = mobileLibraryText(entry.Heat, 256)
	entry.Views = mobileLibraryText(entry.Views, 256)
	entry.OnlineDate = mobileLibraryText(entry.OnlineDate, 256)
	entry.ReleaseStatus = mobileLibraryText(entry.ReleaseStatus, 64)
	if entry.Episodes < 0 || entry.Episodes > 100000 {
		entry.Episodes = 0
	}
	tags, seen := []string{}, map[string]bool{}
	for _, raw := range entry.Tags {
		tag := mobileLibraryText(raw, 128)
		if tag != "" && !seen[tag] {
			tags = append(tags, tag)
			seen[tag] = true
		}
		if len(tags) >= 64 {
			break
		}
	}
	entry.Tags = tags
	return entry, ""
}

func completeMobileLibraryEntry(current, extra mobileLibraryEntry) mobileLibraryEntry {
	if current.Title == "" {
		current.Title = extra.Title
	}
	if current.Description == "" {
		current.Description = extra.Description
	}
	if current.Cover == "" {
		current.Cover = extra.Cover
	}
	if current.Category == "" {
		current.Category = extra.Category
	}
	if current.Episodes == 0 {
		current.Episodes = extra.Episodes
	}
	if current.VIP == nil {
		current.VIP = extra.VIP
	}
	if current.Heat == "" {
		current.Heat = extra.Heat
	}
	if current.Views == "" {
		current.Views = extra.Views
	}
	if current.OnlineDate == "" {
		current.OnlineDate = extra.OnlineDate
	}
	if current.ReleaseStatus == "" {
		current.ReleaseStatus = extra.ReleaseStatus
	}
	if len(current.Tags) == 0 {
		current.Tags = extra.Tags
	}
	return current
}

func (c *MobileClient) importLibrary(ctx context.Context, request mobileRequest) (map[string]any, error) {
	batch, err := readMobileLibrary(ctx, request.Path)
	if err != nil {
		return nil, err
	}
	dramas := make([]Drama, 0, len(batch.rows))
	sources := map[string]int{}
	for _, row := range batch.rows {
		if row.Source == "cloudfront" {
			row.ID = row.SourceID
		}
		dramas = append(dramas, Drama{ID: row.ID, Source: row.Source, SourceID: row.SourceID, Title: row.Title, Intro: row.Description, Cover: row.Cover, EpisodeCount: json.Number(fmt.Sprint(row.Episodes)), Category: row.Category, VIP: row.VIP, Heat: row.Heat, Views: row.Views, OnlineDate: row.OnlineDate, Tags: row.Tags, ReleaseStatus: row.ReleaseStatus})
		source := row.Source
		if matchesSourceFilter(source, "huangguo") {
			source = "huangguo"
		}
		sources[source]++
	}
	result := map[string]any{"accepted": len(dramas), "rejected": batch.rejected, "skipped": batch.skipped, "duplicates": batch.duplicates, "sources": sources}
	rows := mobileDramas(dramas)
	if len(rows) <= 1000 {
		result["items"] = rows
		return result, nil
	}
	// Large batches travel as files, not multi-megabyte MethodChannel JSON strings.
	directory := os.TempDir()
	if c.downloader != nil {
		directory = c.downloader.cfg.dataDirectory()
	}
	file, err := os.CreateTemp(directory, ".guoguo-library-items-*.json")
	if err != nil {
		return nil, err
	}
	path := file.Name()
	succeeded := false
	defer func() {
		file.Close()
		if !succeeded {
			os.Remove(path)
		}
	}()
	writer := &mobileLibraryWriter{ctx: ctx, writer: file}
	if _, err := writer.Write([]byte("[")); err != nil {
		return nil, err
	}
	encoder := json.NewEncoder(writer)
	for index, row := range rows {
		if index > 0 {
			if _, err := writer.Write([]byte(",")); err != nil {
				return nil, err
			}
		}
		if err := encoder.Encode(row); err != nil {
			return nil, err
		}
	}
	if _, err := writer.Write([]byte("]")); err != nil {
		return nil, err
	}
	if err := file.Close(); err != nil {
		return nil, err
	}
	succeeded = true
	result["itemsPath"] = path
	return result, nil
}

type mobileLibraryWriter struct {
	ctx    context.Context
	writer io.Writer
	count  int64
}

func (w *mobileLibraryWriter) Write(p []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	if w.count+int64(len(p)) > mobileLibraryMaxBytes {
		return 0, errors.New("导出的剧库超过 32 MB")
	}
	n, err := w.writer.Write(p)
	w.count += int64(n)
	return n, err
}

func (c *MobileClient) exportLibrary(ctx context.Context, request mobileRequest) (map[string]any, error) {
	batch, err := readMobileLibrary(ctx, request.Path)
	if err != nil {
		return nil, err
	}
	target := request.OutputPath
	if !filepath.IsAbs(target) || filepath.Clean(target) == filepath.Clean(request.Path) {
		return nil, errors.New("剧库导出路径无效或与输入文件相同")
	}
	extension := strings.ToLower(filepath.Ext(target))
	if extension != ".json" && extension != ".xz" {
		return nil, errors.New("剧库只能导出为 JSON 或 XZ 文件")
	}
	file, err := os.CreateTemp(filepath.Dir(target), ".guoguo-library-*")
	if err != nil {
		return nil, fmt.Errorf("无法创建剧库导出文件: %w", err)
	}
	defer os.Remove(file.Name())
	defer file.Close()
	bounded := &mobileLibraryWriter{ctx: ctx, writer: file}
	var writer io.Writer = bounded
	var compressor *xz.Writer
	if extension == ".xz" {
		compressor, err = (xz.WriterConfig{DictCap: 1 << 20, BlockSize: 4 << 20}).NewWriter(bounded)
		if err != nil {
			return nil, err
		}
		writer = compressor
	}
	uncompressed := &mobileLibraryWriter{ctx: ctx, writer: writer}
	exportRows := make([]mobileLibraryEntry, len(batch.rows))
	for index, row := range batch.rows {
		exportRows[index] = mobileLibraryExportEntry(row)
	}
	document := mobileLibraryDocument{App: "guoguo", Kind: "library", Version: 1, ExportedAt: time.Now().UTC().Truncate(time.Second), Count: len(batch.rows), Dramas: exportRows}
	err = json.NewEncoder(uncompressed).Encode(document)
	if compressor != nil {
		if closeErr := compressor.Close(); err == nil {
			err = closeErr
		}
	}
	if err != nil {
		return nil, fmt.Errorf("剧库导出失败: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := file.Sync(); err != nil {
		return nil, fmt.Errorf("剧库写入失败: %w", err)
	}
	if err := file.Close(); err != nil {
		return nil, err
	}
	if err := os.Rename(file.Name(), target); err != nil {
		return nil, fmt.Errorf("剧库保存失败: %w", err)
	}
	return map[string]any{"path": target, "count": len(batch.rows), "skipped": batch.skipped + batch.rejected, "duplicates": batch.duplicates}, nil
}

func mobileLibraryExportEntry(row mobileLibraryEntry) mobileLibraryEntry {
	var base, payload string
	var found bool
	switch row.Source {
	case sourceFanguo:
		base, payload, found = strings.Cut(row.SourceID, "#")
	case sourceXingguo:
		base, payload, found = strings.Cut(row.SourceID, "@")
		runes := []rune(payload)
		if len(runes) > 80 {
			payload = string(runes[:80])
		}
	}
	if found {
		row.SourceID = base + "~" + base64.RawURLEncoding.EncodeToString([]byte(payload))
		row.ID = providerDramaID(row.Source, row.SourceID)
	}
	return row
}
