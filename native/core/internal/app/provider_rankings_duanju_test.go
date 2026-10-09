package app

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestDuanjuRankingDefinitionsAndKinds(t *testing.T) {
	count, sources := 0, map[string]bool{}
	for _, board := range rankingBoards {
		if board.Kind == "" || board.Description == "" {
			t.Fatalf("board missing semantics: %+v", board)
		}
		if !isDuanjuProviderSource(board.Source) {
			continue
		}
		count++
		sources[board.Source] = true
		if board.ID != "yaguo-rank" && board.ID != "chaoguo-hot" && (board.Kind == rankingKindRanking || !strings.Contains(board.Description, "不代表官方排名")) {
			t.Fatalf("directory disguised as official ranks: %+v", board)
		}
	}
	if count != 47 || len(sources) != 13 {
		t.Fatalf("want 47 boards across 13 sources: %d %d", count, len(sources))
	}
	for _, id := range []string{"huangju-hot", "huangju-new", "yeguo-recommend", "dsd-catalog"} {
		board, ok := findRankingBoard(id)
		if !ok || board.Kind != rankingKindCatalog {
			t.Fatalf("missing catalog board: %s", id)
		}
	}
}

func TestDuanjuRankingDispatchPreservesProviderAndOrder(t *testing.T) {
	for _, board := range rankingBoards {
		if !isDuanjuProviderSource(board.Source) {
			continue
		}
		t.Run(board.ID, func(t *testing.T) {
			d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
				body := ""
				switch board.Source {
				case sourceYaguo:
					if strings.HasSuffix(r.URL.Path, "/login") {
						body = `{"data":{"token":"fixture-token"}}`
						break
					}
					if board.path == "9" {
						if r.URL.Path != "/cloud/v1/first_level_ranking/detail" {
							t.Errorf("wrong official rank route: %s", r.URL)
						}
					} else if r.URL.Query().Get("theater_class_id") != board.path {
						t.Errorf("wrong theater category: %s", r.URL)
					}
					body = `{"data":{"is_end":true,"list":[{"theater":{"id":88,"title":"乙"}},{"theater":{"id":77,"title":"甲"}}]}}`
				case sourceMaoguo:
					if r.URL.Query().Get("tag_id") != board.path {
						t.Errorf("wrong recommendation category: %s", r.URL)
					}
					body = `{"data":{"next_id":0,"list":[{"id":"88","title":"乙"},{"id":"77","title":"甲"}]}}`
				case sourceFanguo:
					if r.URL.Query().Get("keyword") != board.path || r.URL.Query().Get("pageIndex") != "1" {
						t.Errorf("wrong fanguo category: %s", r.URL)
					}
					body = `{"result":{"hasMore":false,"elements":[{"contents":[{"duanjuVo":{"duanjuId":"88","title":"乙"}},{"duanjuVo":{"duanjuId":"77","title":"甲"}}]}]}}`
				case sourceGuanguo:
					if r.URL.Path != "/drama/home/search" || r.Method != http.MethodPost {
						t.Errorf("wrong guanguo catalog: %s %s", r.Method, r.URL)
					}
					body = `{"data":[{"oneId":"88","title":"乙"},{"oneId":"77","title":"甲"}]}`
				case sourceHeguo:
					if r.URL.Path != "/browse/"+board.path+"/1" {
						t.Errorf("wrong heguo category: %s", r.URL)
					}
					body = `<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"pages":1,"page":1,"bookList":[{"bookId":"88","bookName":"乙"},{"bookId":"77","bookName":"甲"}]}}}</script>`
				case sourceXingguo:
					if r.URL.Query().Get("resourceId") != board.path || r.URL.Query().Get("pageSize") != "50" {
						t.Errorf("wrong xingguo recommendation: %s", r.URL)
					}
					body = `{"data":{"datalist":[{"id":"88","name":"乙"},{"id":"77","name":"甲"}]}}`
				case sourceNiuguo:
					if r.URL.Query().Get("type_id") != board.path || r.URL.Query().Get("class") != "" {
						t.Errorf("wrong niuguo category: %s", r.URL)
					}
					body = `{"data":[{"vod_id":"88","vod_name":"乙"},{"vod_id":"77","vod_name":"甲"}]}`
				case sourceChaoguo:
					if board.path == "" {
						body = `<li class="rank-item"><span class="rank-no">1</span><a class="rank-title" href="/drama/000088">乙</a></li><li class="rank-item"><span class="rank-no">2</span><a class="rank-title" href="/drama/000077">甲</a></li>`
					} else {
						body = `<a class="card" href="/drama/000088" title="乙"></a><a class="card" href="/drama/000077" title="甲"></a>`
					}
				case sourceHuaguo, sourcePiguo, sourceWuguo, sourceMiguo, sourceShuangguo:
					switch board.Source {
					case sourceHuaguo:
						if r.URL.Query().Get("tid") != board.path {
							t.Errorf("wrong huaguo category: %s", r.URL)
						}
					case sourcePiguo:
						if r.URL.Path != "/p/66/c/"+board.path {
							t.Errorf("wrong piguo category: %s", r.URL)
						}
					case sourceWuguo:
						if r.URL.Path != "/index.php/vod/search/class/"+board.path+"/page/1.html" {
							t.Errorf("wrong wuguo category: %s", r.URL)
						}
					}
					body = `<div class="BrowseList_listItem"><a href="/detail/88.html" title="乙"></a></div><div class="BrowseList_listItem"><a href="/detail/77.html" title="甲"></a></div>`
				}
				if board.Source == sourceNiuguo {
					writeNiuguoFixture(t, w, r, body)
				} else {
					_, _ = w.Write([]byte(body))
				}
			})
			d.providerHosts[board.Source] = server.URL
			result, err := d.loadRankingPage(context.Background(), board, 1, false)
			if err != nil || len(result.Items) != 2 || result.Kind != board.Kind || result.Description != board.Description {
				t.Fatalf("ranking dispatch: %+v err=%v", result, err)
			}
			for i, item := range result.Items {
				id := []string{"88", "77"}[i]
				if board.Source == sourceChaoguo {
					id = "0000" + id
				}
				if item.Drama.Source != board.Source || item.Drama.SourceID != id {
					t.Fatalf("source/order changed: %+v", item)
				}
				if board.Kind == rankingKindRanking {
					if item.Rank != i+1 || item.Position != 0 {
						t.Fatalf("official rank lost: %+v", item)
					}
				} else if item.Rank != 0 || item.Position != i+1 {
					t.Fatalf("catalog sequence presented as rank: %+v", item)
				}
			}
			raw, _ := json.Marshal(result)
			if board.Kind != rankingKindRanking && strings.Contains(string(raw), `"rank":`) {
				t.Fatalf("directory serialized official ranks: %s", raw)
			}
		})
	}
}

func TestDuanjuRankingPaginationUsesDirectoryPosition(t *testing.T) {
	board, _ := findRankingBoard("fanguo-urban")
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		page := r.URL.Query().Get("pageIndex")
		if page == "1" {
			_, _ = w.Write([]byte(`{"result":{"hasMore":true,"elements":[{"contents":[{"duanjuVo":{"duanjuId":"77","title":"第一页"}}]}]}}`))
			return
		}
		if page != "2" {
			t.Errorf("wrong page: %s", page)
		}
		_, _ = w.Write([]byte(`{"result":{"hasMore":false,"elements":[{"contents":[{"duanjuVo":{"duanjuId":"88","title":"第二页"}}]}]}}`))
	})
	d.providerHosts[sourceFanguo] = server.URL
	for page := 1; page <= 2; page++ {
		result, err := d.loadRankingPage(context.Background(), board, page, false)
		if err != nil || len(result.Items) != 1 || result.HasMore != (page == 1) || result.Items[0].Rank != 0 || result.Items[0].Position != 1 {
			t.Fatalf("page=%d result=%+v err=%v", page, result, err)
		}
	}
}

func TestHuangguoRankingAcceptsNewVideoDetailURL(t *testing.T) {
	board, _ := findRankingBoard("huangguo-hot")
	body := `<script type="application/ld+json">{"@graph":[{"@type":"ItemList","@id":"https://example.test/ranks/hot/#itemlist","itemListElement":[{"position":1,"name":"新入口","url":"https://example.test/video/117/"}]}]}</script>`
	result, err := parseHuangguoRanking(body, board)
	if err != nil || len(result.Items) != 1 || result.Items[0].Drama.SourceID != "117" {
		t.Fatalf("new detail URL: %+v %v", result, err)
	}
}
