package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strconv"
	"testing"
)

func hongguoWebsitePageFixture(page int, more bool, titles ...string) string {
	rows := make([]any, 0, len(titles))
	for _, title := range titles {
		rows = append(rows, map[string]any{"video_data": map[string]any{"series_id": "730000000000000000" + title[:1], "series_title": title[1:]}})
	}
	body, _ := json.Marshal(map[string]any{"pageNum": page, "hasMore": more, "totalCount": 3, "searchList": rows})
	return string(body)
}

func TestMobileHongguoWebsitePaginationAndReplay(t *testing.T) {
	var pages []int
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		body := `{"suggest_list":[]}`
		if r.URL.Path == "/api/search/result" {
			page, _ := strconv.Atoi(r.URL.Query().Get("page"))
			pages = append(pages, page)
			if page == 1 {
				body = hongguoWebsitePageFixture(1, true, "1大佬甲", "2大佬乙")
			} else {
				body = hongguoWebsitePageFixture(page, false, "2大佬乙", "3大佬丙")
			}
		}
		return rankingHTTPResponse(r, 200, body), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	first := callMobileSeasonPage(t, c, "大佬", 1, "")
	if len(first["items"].([]any)) != 2 || first["hasMore"] != true {
		t.Fatal("website next page was lost", first)
	}
	token := first["continuation"].(string)
	saved := c.seasonCursors[token].clone()
	second := callMobileSeasonPage(t, c, "大佬", 2, token)
	replay := callMobileSeasonPage(t, c, "大佬", 2, token)
	delete(second, "_diagnostic")
	delete(replay, "_diagnostic")
	if len(second["items"].([]any)) != 3 || second["hasMore"] != false || !reflect.DeepEqual(second, replay) || !reflect.DeepEqual(pages, []int{1, 2, 2}) {
		t.Fatal("real next page did not add unique results or replay changed it", second, replay, pages)
	}
	if !reflect.DeepEqual(c.seasonCursors[token], saved) {
		t.Fatal("website paging mutated a published cursor")
	}
}

func TestMobileHongguoWebsiteFailureRetriesSameUpstreamPage(t *testing.T) {
	for _, failedPage := range []int{1, 2} {
		t.Run(fmt.Sprint(failedPage), func(t *testing.T) {
			fail := true
			var pages []int
			d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
				body := `{"suggest_list":[{"name":"大佬甲","word_type":"short_play_name","video_data":{"series_id":"7300000000000000001","series_title":"大佬甲"}}]}`
				if r.URL.Path == "/api/search/result" {
					page, _ := strconv.Atoi(r.URL.Query().Get("page"))
					pages = append(pages, page)
					if fail && page == failedPage {
						body = `{}`
					} else {
						body = hongguoWebsitePageFixture(page, page < 2, "3大佬丙")
					}
				}
				return rankingHTTPResponse(r, 200, body), nil
			})
			c := &MobileClient{downloader: d}
			defer c.Close()
			first := callMobileSeasonPage(t, c, "大佬", 1, "")
			failed := first
			if failedPage == 2 {
				failed = callMobileSeasonPage(t, c, "大佬", 2, first["continuation"].(string))
			}
			if failed["warning"] == "" || failed["hasMore"] != true {
				t.Fatal("failed branch lost results or retry", failed)
			}
			fail = false
			result := callMobileSeasonPage(t, c, "大佬", failedPage+1, failed["continuation"].(string))
			if pages[len(pages)-1] != failedPage || result["warning"] != "" || len(result["items"].([]any)) != 2 {
				t.Fatal("failed website page was consumed or stale warning survived", pages, result)
			}
		})
	}
}

func TestMobileHongguoWebsiteAddsSeasonProbesWithinBudget(t *testing.T) {
	var queries []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		body := `{"suggest_list":[]}`
		if r.URL.Path == "/api/search/result" {
			if r.URL.Query().Get("page") == "1" {
				body = hongguoWebsitePageFixture(1, true, "1修仙第一季")
			} else {
				body = hongguoWebsitePageFixture(2, false, "4修仙第四季")
			}
		} else {
			queries = append(queries, r.URL.Query().Get("query"))
		}
		return rankingHTTPResponse(r, 200, body), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	first := callMobileSeasonPage(t, c, "修仙", 1, "")
	second := callMobileSeasonPage(t, c, "修仙", 2, first["continuation"].(string))
	if len(second["items"].([]any)) != 2 || second["hasMore"] != true || len(queries) > mobileSeasonPageQueries || queries[1] != "修仙第二季" {
		t.Fatal("website discovery lost season gaps or exceeded the shared request budget", queries, second)
	}
}

func TestMobileHongguoFailedNamesCanRecoverAfterLastWebsitePage(t *testing.T) {
	failed := true
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/api/search/result" {
			return rankingHTTPResponse(r, 200, hongguoWebsitePageFixture(1, false, "1大佬甲")), nil
		}
		if failed {
			return rankingHTTPResponse(r, 200, `{}`), nil
		}
		return rankingHTTPResponse(r, 200, `{"suggest_list":[{"name":"大佬乙","word_type":"short_play_name","video_data":{"series_id":"7300000000000000002","series_title":"大佬乙"}}]}`), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	first := callMobileSeasonPage(t, c, "大佬", 1, "")
	if first["hasMore"] != true || first["warning"] == "" {
		t.Fatal("failed names branch became unreachable", first)
	}
	failed = false
	second := callMobileSeasonPage(t, c, "大佬", 2, first["continuation"].(string))
	if len(second["items"].([]any)) != 2 || second["warning"] != "" || second["hasMore"] != false {
		t.Fatal("names recovery lost new results or retained a stale warning", second)
	}
}

func TestMobileHongguoCanceledWebsitePageLeavesCursorReplayable(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/api/search/result" {
			return rankingHTTPResponse(r, 200, hongguoWebsitePageFixture(1, true, "1大佬甲")), nil
		}
		return rankingHTTPResponse(r, 200, `{"suggest_list":[]}`), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	first := callMobileSeasonPage(t, c, "大佬", 1, "")
	token := first["continuation"].(string)
	saved := c.seasonCursors[token].clone()
	ctx, cancel := context.WithCancel(context.Background())
	d.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
		cancel()
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	_, err := c.searchHongguoPage(ctx, mobileRequest{Query: "大佬", Page: 2, Continuation: token}, nil)
	if err == nil || !reflect.DeepEqual(c.seasonCursors[token], saved) {
		t.Fatal("cancellation advanced the published cursor", err)
	}
}
