package app

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"testing"
	"time"
)

const searchSortFixture = `<script>window._ROUTER_DATA={"loaderData":{"search_layout":null,"search_(keyword)/page":{"query":"测试","isSuccess":true,"totalCount":30,"searchList":[
{"video_data":{"series_id":"7000000000000000001","series_title":"测试甲","create_time":"1787626382","hot_score_data":{"score":20019,"text":"2万热度"}}},
{"video_data":{"series_id":"7000000000000000002","series_title":"测试乙","create_time":"1786502463","hot_score_data":{"score":0,"text":"0热度"}}},
{"video_data":{"series_id":"7000000000000000003","series_title":"测试丙","create_time":"1788610261","score":"9.9"}}
]}}}</script>`

func TestHongguoSearchSortMetadata(t *testing.T) {
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Host != "hongguoduanju.com" || request.URL.Path != "/search/测试" {
			t.Fatalf("unexpected request: %s", request.URL.Path)
		}
		return rankingHTTPResponse(request, http.StatusOK, searchSortFixture), nil
	})
	result, err := d.fetchHongguoSearchPage(context.Background(), "测试")
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Dramas) != 3 || result.Total != 30 {
		t.Fatalf("wrong search result size: %d / %d", len(result.Dramas), result.Total)
	}
	for index, want := range []string{"20019", "0", ""} {
		drama := result.Dramas[index]
		if drama.Heat != want {
			t.Errorf("result %d heat = %q, want %q", index, drama.Heat, want)
		}
		if drama.Views != "" || drama.OnlineDate != "" {
			t.Errorf("heat and create_time must not be relabeled as plays or a release date")
		}
	}
}

func TestHongguoHeatTextFallback(t *testing.T) {
	for _, test := range []struct {
		name string
		hot  map[string]any
		want string
	}{
		{"precise numeric heat", map[string]any{"score": json.Number("47093735"), "text": "4709万热度"}, "47093735"},
		{"zero is valid", map[string]any{"score": 0, "text": "未知"}, "0"},
		{"text only", map[string]any{"text": "1.2亿热度"}, "1.2亿热度"},
		{"invalid numeric heat", map[string]any{"score": "-1", "text": "5万热度"}, "5万热度"},
		{"missing heat", nil, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			row := map[string]any{"series_id": "7000000000000000001", "score": "9.8", "hot_score_data": test.hot}
			if got := hongguoDramaFromAny(row, "短剧").Heat; got != test.want {
				t.Fatalf("heat = %q, want %q", got, test.want)
			}
		})
	}
}

func TestLiveHongguoSearchSortMetadata(t *testing.T) {
	if os.Getenv("JUKU_LIVE_SEARCH") != "1" {
		t.Skip("set JUKU_LIVE_SEARCH=1 for a metadata-only search request")
	}
	cfg := defaultConfig()
	cfg.dataDir, cfg.OutputDir, cfg.Retries = t.TempDir(), t.TempDir(), 1
	d := NewDownloader(cfg)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	result, err := d.searchHongguoDramas(ctx, "重生")
	if err != nil || len(result.Dramas) == 0 {
		t.Fatalf("live search returned no entries: %v", err)
	}
	heat, dates, views := 0, 0, 0
	for _, drama := range result.Dramas {
		if drama.Heat != "" {
			heat++
		}
		if drama.OnlineDate != "" {
			dates++
		}
		if drama.Views != "" {
			views++
		}
	}
	if heat == 0 {
		t.Fatal("live search heat was not retained")
	}
	t.Logf("entries=%d, total=%d, with heat=%d, release date=%d, plays=%d", len(result.Dramas), result.Total, heat, dates, views)
}
