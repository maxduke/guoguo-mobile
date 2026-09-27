package app

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func semanticRankingFixture() string {
	return `<link rel="canonical" href="https://www.hongguoduanju.com/rank/hot-drama">
 <ol aria-label="热播榜"><li><article aria-labelledby="rank-title-123">
 <a href="/detail?series_id=123" aria-label="查看短剧">1</a>
 <a href="/detail?series_id=123"><h2 id="rank-title-123">合成短剧</h2></a>
 <p>合成简介</p><span>1.2万热度</span>
 </article></li></ol><nav aria-label="榜单分页"><span aria-current="page">1</span></nav>`
}

func TestHongguoRankingSemanticFallback(t *testing.T) {
	board, _ := findRankingBoard("hongguo-hot")
	body := semanticRankingFixture()
	result, err := parseHongguoRanking(body, board, 1)
	if err != nil || len(result.Items) != 1 || result.Items[0].Drama.SourceID != "123" || result.Items[0].Rank != 1 || result.Items[0].Drama.Heat != "1.2万热度" || result.HasMore {
		t.Fatalf("semantic result: %+v, %v", result, err)
	}
	for _, invalid := range []string{
		strings.ReplaceAll(body, "hot-drama", "wrong-board"),
		strings.ReplaceAll(body, `series_id=123`, `series_id=456`),
		strings.ReplaceAll(body, `aria-current="page">1`, `aria-current="page">2`),
		strings.ReplaceAll(body, `>1</a>`, `>21</a>`),
		strings.ReplaceAll(body, `</nav>`, `<a rel="next" href="/rank/hot-drama?page=2">2</a></nav>`),
	} {
		if _, err := parseHongguoRanking(invalid, board, 1); err == nil {
			t.Fatal("accepted invalid ranking identity, rank or incomplete page")
		}
	}
}

func TestHongguoRankingJSONLDFallback(t *testing.T) {
	board, _ := findRankingBoard("hongguo-hot")
	body := semanticRankingFixture() + `<script type="application/ld+json">{"@type":"ItemList","url":"/rank/hot-drama","itemListElement":[{"position":2,"name":"结构化榜单","url":"/detail?series_id=456"}]}</script>`
	result, err := parseHongguoRanking(body, board, 1)
	if err != nil || len(result.Items) != 1 || result.Items[0].Rank != 2 || result.Items[0].Drama.SourceID != "456" {
		t.Fatalf("JSON-LD: %+v %v", result, err)
	}
}

func TestHongguoRankingRetriesIncompleteOnly(t *testing.T) {
	board, _ := findRankingBoard("hongguo-hot")
	for _, scenario := range []string{"eventual", "incomplete", "wrong board", "network"} {
		t.Run(scenario, func(t *testing.T) {
			calls := 0
			d := rankingTestDownloader(t, func(req *http.Request) (*http.Response, error) {
				calls++
				if req.URL.RawQuery != "" {
					t.Error("first page should use canonical URL")
				}
				if calls > 1 && req.Header.Get("Cache-Control") != "no-cache" {
					t.Error("retry must revalidate cache")
				}
				switch scenario {
				case "eventual":
					if calls == 2 {
						return rankingHTTPResponse(req, 200, semanticRankingFixture()), nil
					}
				case "wrong board":
					return rankingHTTPResponse(req, 200, strings.ReplaceAll(semanticRankingFixture(), "hot-drama", "wrong")), nil
				case "network":
					return nil, errors.New("synthetic transport failure")
				}
				return rankingHTTPResponse(req, 200, "<html>loading</html>"), nil
			})
			d.cfg.Retries = 5
			_, err := d.fetchRankingPage(context.Background(), board, 1)
			expected := 1
			if scenario == "eventual" {
				expected = 2
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil {
				t.Fatal("expected failure")
			}
			if scenario == "incomplete" {
				expected = 3
			}
			if calls != expected {
				t.Fatalf("requests=%d want=%d", calls, expected)
			}
		})
	}
}

func TestHongguoRankingRetryHonorsCancellation(t *testing.T) {
	board, _ := findRankingBoard("hongguo-hot")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	d := rankingTestDownloader(t, func(req *http.Request) (*http.Response, error) {
		calls++
		cancel()
		return rankingHTTPResponse(req, 200, "<html>loading</html>"), nil
	})
	start := time.Now()
	_, err := d.fetchRankingPage(ctx, board, 1)
	if !errors.Is(err, context.Canceled) || calls != 1 || time.Since(start) > time.Second {
		t.Fatalf("cancellation: %d %v", calls, err)
	}
}
