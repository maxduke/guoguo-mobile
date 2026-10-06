package app

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func sortDetailFixture(id, stamp string) string {
	return `<script>window._ROUTER_DATA={"loaderData":{"detail_page":{"seriesDetail":{"series_id":"` + id + `","series_name":"测试剧","first_visible_time":"` + stamp + `","create_time":"1745906791"}}}}</script>`
}

func TestSortDetailDatesAndIdentity(t *testing.T) {
	id := "7615465407347952664"
	drama, err := parseHongguoSortDetail(sortDetailFixture(id, "1773662280"), id)
	if err != nil || drama.OnlineDate != "2026-03-16" {
		t.Fatalf("first-visible date: %q, %v", drama.OnlineDate, err)
	}
	if _, err = parseHongguoSortDetail(sortDetailFixture("7498612570866076734", "1773662280"), id); err == nil {
		t.Fatal("accepted another drama's time")
	}
	drama, err = parseHongguoSortDetail(sortDetailFixture(id, "0"), id)
	if err != nil || drama.OnlineDate != "" {
		t.Fatal("creation time must not replace missing first-visible time")
	}
	for _, value := range []string{"", "0", "0001-01-01", "1970-01-01", "2101-01-01", "2026-02-31", "not a date"} {
		if got := providerReleaseDate(value); got != "" {
			t.Errorf("accepted date %q", value)
		}
	}
	body := `<script type="application/ld+json">{"@graph":[{"@type":"VideoObject","@id":"https://huangguoai.com/detail/999/#video","name":"推荐剧","uploadDate":"2026-12-30"},{"@type":"WebPage","@id":"https://huangguoai.com/detail/453/#webpage","name":"当前剧","datePublished":"2026-08-11T10:27:20+08:00","dateModified":"2026-09-13"}]}</script><div class="hg-web-detail__meta"><span>已发布 · 10001次播放 · 2026-08-11 上线</span></div><div>评论 2026-09-13</div>`
	drama, err = parseHuangguoSortDetail(body, "https://huangguoai.com/detail/453/", Drama{ID: "huangguoai:453", Source: sourceHuangguoAI})
	if err != nil || drama.OnlineDate != "2026-08-11" || drama.Views != "10001次播放" {
		t.Fatalf("wrong detail fields: date=%q views=%q err=%v", drama.OnlineDate, drama.Views, err)
	}
	if _, err = parseHuangguoSortDetail(body, "https://huangguoai.com/detail/100/", Drama{}); err == nil {
		t.Fatal("accepted recommendations as the detail")
	}
	if normalizeViews("10019") != "10019次播放" {
		t.Fatal("play counts must retain precision")
	}
}

func TestSortMetadataSelectionAndResume(t *testing.T) {
	now := time.Now()
	var rows []Drama
	for index := 0; index < 60; index++ {
		rows = append(rows, Drama{ID: fmt.Sprintf("hongguo:%019d", index+1), Source: sourceHongguo})
	}
	rows[1].SortMetadata = &sortMetadataState{Version: sortMetadataVersion, CheckedAt: now, CoverChecked: true}
	rows[2].SortMetadata = &sortMetadataState{CheckedAt: now}
	rows = append(rows, Drama{ID: "huangdou:other", Source: sourceHuangdou})
	batch := selectSortMetadataBatch(rows, sourceHongguo, []string{rows[59].ID, rows[59].ID, rows[2].ID, "huangdou:other"}, now)
	if len(batch) != sortMetadataBatchSize || batch[0].ID != rows[59].ID {
		t.Fatal("did not prioritize filtered entries within the batch limit")
	}
	for _, row := range batch {
		if row.ID == rows[1].ID || row.ID == rows[2].ID || row.Source != sourceHongguo {
			t.Fatal("selected completed, cooling-down or other-source entries")
		}
	}
	if got := selectSortMetadataBatch(rows, sourceHuangdou, nil, now); len(got) != 1 {
		t.Fatal("source filter was not respected")
	}
	if remaining := sortMetadataRemaining(rows); remaining["hongguo"] != 59 || remaining["huangdou"] != 1 || remaining[""] != 60 {
		t.Fatal(remaining)
	}
}

func TestHuangdouHistoricalFieldsUseMatchingListItem(t *testing.T) {
	var listCalls atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/api/drama/detail":
			return rankingHTTPResponse(request, 200, `{"data":{"id":"target","name":"测试剧","issue_date":"2026-08-11","click":0}}`), nil
		case "/api/drama/list":
			listCalls.Add(1)
			body, _ := io.ReadAll(request.Body)
			key, _ := huangdouKey(request.Header.Get("requestId"))
			decoded, err := huangdouDecode(body, key)
			if err != nil || mapString(nestedMap(decoded, "data"), "keywords") != "测试剧" {
				t.Error("did not use the site's keyword lookup")
			}
			return rankingHTTPResponse(request, 200, `{"data":{"list":[{"id":"other","hot_rate":"999999"},{"id":"rp_target","hot_rate":"20019"}]}}`), nil
		default:
			t.Errorf("unexpected path: %s", request.URL.Path)
			return rankingHTTPResponse(request, 404, ""), nil
		}
	})
	patch, err := d.fetchDramaSortMetadata(context.Background(), Drama{ID: "huangdou:target", Source: sourceHuangdou})
	if err != nil || patch.OnlineDate != "2026-08-11" || patch.Heat != "20019" || patch.Views != "0" || listCalls.Load() != 1 {
		t.Fatalf("wrong matched metadata: date=%q heat=%q views=%q err=%v", patch.OnlineDate, patch.Heat, patch.Views, err)
	}
	if patch.Cover != nil || patch.CoverURL != nil {
		t.Fatal("historical metadata must not collect images")
	}
}
