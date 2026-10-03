package app

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/ulikunitz/xz"
)

func TestMobileLibraryLargeBatchUsesNormalizedFile(t *testing.T) {
	rows := make([]mobileLibraryEntry, 1001)
	for index := range rows {
		rows[index] = mobileLibraryEntry{ID: "hongguo:" + strconv.FormatInt(7300000000000000000+int64(index), 10), Title: "剧集"}
	}
	result, err := (&MobileClient{}).importLibrary(context.Background(), mobileRequest{Path: libraryFixture(t, rows)})
	if err != nil || result["accepted"] != len(rows) || result["items"] != nil {
		t.Fatal("large batch response", result, err)
	}
	path, ok := result["itemsPath"].(string)
	if !ok || path == "" {
		t.Fatal("missing normalized file", result)
	}
	defer os.Remove(path)
	data, err := os.ReadFile(path)
	var normalized []map[string]any
	if err != nil || json.Unmarshal(data, &normalized) != nil || len(normalized) != len(rows) || normalized[1000]["id"] != rows[1000].ID {
		t.Fatal("normalized batch", len(normalized), err)
	}
}

func libraryFixture(t *testing.T, rows []mobileLibraryEntry) string {
	t.Helper()
	data, err := json.Marshal(mobileLibraryDocument{Kind: "library", Version: 1, Count: len(rows), Dramas: rows})
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "library.json")
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	return file
}
func TestMobileLibraryJSONXZRoundtripAndSourceIdentity(t *testing.T) {
	payload := base64.RawURLEncoding.EncodeToString([]byte("介绍"))
	input := libraryFixture(t, []mobileLibraryEntry{
		{ID: "hongguo:7300000000000000001", Title: "甲"},
		{ID: "huangguoai:501", Title: "AI"},
		{ID: "cloudfront:legacy", Title: "旧目录"},
		{ID: "fanguo:22#one", Title: "饭果"},
		{ID: "xingguo:33~" + payload, Title: "星果", Description: "介绍更完整"},
		{ID: "hongguo:7300000000000000001", Title: "重复", Description: "补简介"},
		{ID: "wangguo:1", Title: "删除源"},
		{ID: "future:1", Title: "未知源"},
	})
	c := &MobileClient{}
	result, err := c.importLibrary(context.Background(), mobileRequest{Path: input})
	if err != nil || result["accepted"] != 5 || result["skipped"] != 2 || result["duplicates"] != 1 {
		t.Fatal("import", result, err)
	}
	rows := result["items"].([]map[string]any)
	if rows[1]["source"] != "huangguo" || rows[2]["id"] != "legacy" || rows[2]["source"] != "huangguo" || rows[4]["id"] != "xingguo:33@介绍更完整" {
		t.Fatal("mobile identity", rows)
	}
	for _, extension := range []string{".json", ".xz"} {
		target := filepath.Join(t.TempDir(), "export"+extension)
		_, err := c.exportLibrary(context.Background(), mobileRequest{Path: input, OutputPath: target})
		if err != nil {
			t.Fatal(err)
		}
		imported, err := c.importLibrary(context.Background(), mobileRequest{Path: target})
		if err != nil || imported["accepted"] != 5 || imported["duplicates"] != 0 {
			t.Fatal("roundtrip", imported, err)
		}
		decoded, err := readMobileLibrary(context.Background(), target)
		if err != nil || decoded.rows[3].ID != "fanguo:22#one" || decoded.rows[4].ID != "xingguo:33@介绍更完整" {
			t.Fatal("payload roundtrip", decoded, err)
		}
	}
}
func TestMobileLibraryRejectsIncompleteOrWrongFormatAtomically(t *testing.T) {
	for _, body := range []string{
		`{"kind":"library","version":1,"dramas":[{"id":"hongguo:7300000000000000001","title":"ok"}],`,
		`{"kind":"library","version":1,"count":2,"dramas":[]}`,
		`{"kind":"library","kind":"library","version":1,"dramas":[]}`,
		`{"kind":"library","version":2,"dramas":[]}`,
		`{"format":"guoguo.records","version":1,"favorites":[],"history":[]}`,
		`{"kind":"library","version":1,"dramas":[]} trailing`,
	} {
		batch, err := decodeMobileLibrary(context.Background(), []byte(body))
		if err == nil || len(batch.rows) != 0 {
			t.Fatal("accepted invalid batch", body, err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := readMobileLibrary(ctx, "/not-used"); err != context.Canceled {
		t.Fatal("cancellation lost", err)
	}
}
func TestMobileLibraryXZBoundsAndFailedExportPreserveTarget(t *testing.T) {
	var compressed bytes.Buffer
	writer, err := (xz.WriterConfig{DictCap: 1 << 20}).NewWriter(&compressed)
	if err != nil {
		t.Fatal(err)
	}
	// A tiny compressed file must not bypass the decompressed byte budget.
	chunk := bytes.Repeat([]byte(" "), 1<<20)
	for range 33 {
		if _, err := writer.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	input := filepath.Join(t.TempDir(), "bomb.xz")
	if err := os.WriteFile(input, compressed.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readMobileLibrary(context.Background(), input); err == nil || !strings.Contains(err.Error(), "32 MB") {
		t.Fatal("decompression bound", err)
	}
	if err := os.WriteFile(input, compressed.Bytes()[:12], 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readMobileLibrary(context.Background(), input); err == nil {
		t.Fatal("truncated XZ accepted")
	}
	target := filepath.Join(t.TempDir(), "unchanged.json")
	os.WriteFile(target, []byte("original"), 0600)
	c := &MobileClient{}
	if _, err := c.exportLibrary(context.Background(), mobileRequest{Path: input, OutputPath: target}); err == nil {
		t.Fatal("invalid export accepted")
	}
	body, _ := os.ReadFile(target)
	if string(body) != "original" {
		t.Fatal("failed export changed target")
	}
}

func TestMobileLibraryRejectsOversizedXZDictionaryBeforeAllocation(t *testing.T) {
	var encoded bytes.Buffer
	writer, err := (xz.WriterConfig{DictCap: 1 << 20}).NewWriter(&encoded)
	if err != nil {
		t.Fatal(err)
	}
	writer.Write([]byte(`{"kind":"library","version":1,"dramas":[]}`))
	writer.Close()
	raw := encoded.Bytes()
	size := (int(raw[12]) + 1) * 4
	header := raw[12 : 12+size]
	if header[1] != 0 || header[2] != 0x21 || header[3] != 1 {
		t.Fatal("unexpected synthetic block header")
	}
	header[4] = 40 // 4 GiB advertised dictionary; do not allocate it.
	binary.LittleEndian.PutUint32(header[size-4:], crc32.ChecksumIEEE(header[:size-4]))
	path := filepath.Join(t.TempDir(), "huge-dictionary.xz")
	os.WriteFile(path, raw, 0600)
	if _, err := readMobileLibrary(context.Background(), path); err == nil || !strings.Contains(err.Error(), "dictionary size exceeds max") {
		t.Fatal("dictionary bound missing", err)
	}
}
