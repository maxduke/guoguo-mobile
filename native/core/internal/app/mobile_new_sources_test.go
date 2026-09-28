package app

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newSourceMobileClient(t *testing.T) *MobileClient {
	t.Helper()
	client, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client
}

func callNewMobileSource(t *testing.T, client *MobileClient, request map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Call(string(raw))
	if err != nil {
		t.Fatalf("mobile %v: %v", request, err)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(response), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func newMobileSourceRows(t *testing.T, response map[string]any, key string) []map[string]any {
	t.Helper()
	entries, ok := response[key].([]any)
	if !ok {
		t.Fatalf("%s missing from response: %+v", key, response)
	}
	rows := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		row, ok := entry.(map[string]any)
		if !ok {
			t.Fatalf("invalid %s entry: %T", key, entry)
		}
		rows = append(rows, row)
	}
	return rows
}

func assertNewSourcePage(t *testing.T, response map[string]any, source, id string, more bool) {
	t.Helper()
	rows := newMobileSourceRows(t, response, "items")
	if response["catalogScope"] != "page" || response["page"] != float64(2) || response["hasMore"] != more || len(rows) != 1 || rows[0]["id"] != id || rows[0]["source"] != source {
		t.Fatalf("unexpected %s page: %+v", source, response)
	}
}

func assertNewSourceInvalidCategory(t *testing.T, client *MobileClient, source string) {
	t.Helper()
	for _, method := range []string{"catalog", "search"} {
		request := map[string]any{"method": method, "source": source, "category": "../invalid", "page": 2, "query": "样本"}
		raw, _ := json.Marshal(request)
		if _, err := client.Call(string(raw)); err == nil {
			t.Fatalf("%s %s accepted an invalid category", source, method)
		}
	}
}

func TestMobileHuangjuSourceContracts(t *testing.T) {
	var server *httptest.Server
	var catalog, search, detail, play int
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/auth/guest":
			if r.Method != http.MethodPost {
				t.Errorf("guest method: %s", r.Method)
			}
			fmt.Fprint(w, `{"token":"fixture-token"}`)
		case "/categories":
			fmt.Fprint(w, `[{"slug":"hot","name":"热门"},{"slug":"romance","name":"甜宠"}]`)
		case "/dramas":
			if r.URL.Query().Get("page") != "2" {
				t.Errorf("huangju page: %s", r.URL.RawQuery)
			}
			if r.URL.Query().Get("q") != "" {
				search++
				if r.URL.Query().Get("q") != "样本" || r.URL.Query().Get("category") != "" {
					t.Errorf("huangju search query: %s", r.URL.RawQuery)
				}
			} else {
				catalog++
				if r.URL.Query().Get("category") != "romance" {
					t.Errorf("huangju catalog category: %s", r.URL.RawQuery)
				}
			}
			fmt.Fprint(w, `{"items":[{"id":"77","slug":"sample","title":"剧果样本","totalEpisodes":2}],"page":2,"pageSize":1,"total":3}`)
		case "/dramas/sample-77":
			detail++
			fmt.Fprint(w, `{"id":"77","slug":"sample","title":"剧果样本","totalEpisodes":2,"episodes":[{"id":"ep-1","epNo":1},{"id":"ep-2","epNo":2}]}`)
		case "/play/ep-1":
			play++
			for _, cookie := range []string{"CloudFront-Policy=p", "CloudFront-Signature=s", "CloudFront-Key-Pair-Id=k"} {
				w.Header().Add("Set-Cookie", cookie+"; Max-Age=60")
			}
			fmt.Fprintf(w, `{"url":%q}`, server.URL+"/media.mp4")
		default:
			t.Errorf("unexpected huangju route %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := newSourceMobileClient(t)
	client.downloader.cfg.HuangjuAPIURL = server.URL
	client.downloader.cfg.HuangjuURL = server.URL

	categories := newMobileSourceRows(t, callNewMobileSource(t, client, map[string]any{"method": "categories", "source": "huangju"}), "items")
	if len(categories) != 3 || categories[0]["id"] != "" || categories[1]["id"] != "@new" || categories[2]["id"] != "romance" {
		t.Fatalf("huangju categories: %+v", categories)
	}
	assertNewSourcePage(t, callNewMobileSource(t, client, map[string]any{"method": "catalog", "source": "huangju", "category": "romance", "page": 2}), "huangju", "huangju:sample-77", true)
	assertNewSourcePage(t, callNewMobileSource(t, client, map[string]any{"method": "search", "source": "huangju", "category": "romance", "query": " 样本 ", "page": 2}), "huangju", "huangju:sample-77", true)
	assertNewSourceInvalidCategory(t, client, "huangju")
	item := callNewMobileSource(t, client, map[string]any{"method": "detail", "id": "huangju:sample-77"})["item"].(map[string]any)
	if item["id"] != "huangju:sample-77" || item["source"] != "huangju" || item["episodes"] != float64(2) {
		t.Fatalf("huangju detail: %+v", item)
	}
	chapters := newMobileSourceRows(t, callNewMobileSource(t, client, map[string]any{"method": "chapters", "id": "huangju:sample-77"}), "chapters")
	if len(chapters) != 2 || chapters[0]["id"] != "huangju:sample-77:ep-1" || chapters[1]["id"] != "huangju:sample-77:ep-2" {
		t.Fatalf("huangju chapters: %+v", chapters)
	}
	resolved := callNewMobileSource(t, client, map[string]any{"method": "resolve", "id": "huangju:sample-77", "chapter": chapters[0]})
	if resolved["remoteUrl"] != server.URL+"/media.mp4" || resolved["castDirect"] != false || resolved["routeCount"] != float64(1) {
		t.Fatalf("huangju resolve: %+v", resolved)
	}
	callNewMobileSource(t, client, map[string]any{"method": "release", "id": resolved["session"]})
	if catalog != 1 || search != 1 || detail != 2 || play != 1 {
		t.Fatalf("huangju route counts: catalog=%d search=%d detail=%d play=%d", catalog, search, detail, play)
	}
}

func TestMobileYeguoSourceContracts(t *testing.T) {
	var server *httptest.Server
	var catalog, search, detail, play int
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/home/contentOptions":
			if r.Method != http.MethodGet {
				t.Errorf("yeguo categories method: %s", r.Method)
			}
			fmt.Fprint(w, `{"status":"1","data":{"video_filter":{"theme":{"list":[{"value":"0","name":"全部"},{"value":"7","name":"甜宠"}]}}}}`)
		case "/api/theater/exploreList":
			catalog++
			if r.Method != http.MethodPost || r.URL.RawQuery != "" || r.Form.Get("page") != "2" || r.Form.Get("theme") != "7" || r.Form.Get("keyword") != "" {
				t.Errorf("yeguo catalog form: %s %s", r.Method, r.Form.Encode())
			}
			fmt.Fprint(w, `{"status":"1","data":{"page":2,"list":[{"video_id":"123","title":"野果样本","episode_count":2}],"has_more":true}}`)
		case "/api/search/result":
			search++
			if r.Method != http.MethodPost || r.URL.RawQuery != "" || r.Form.Get("page") != "2" || r.Form.Get("keyword") != "样本" || r.Form.Get("theme") != "" {
				t.Errorf("yeguo search form: %s %s", r.Method, r.Form.Encode())
			}
			fmt.Fprint(w, `{"status":"1","data":{"page":2,"list":[{"video_id":"123","title":"野果样本","episode_count":2}],"has_more":true}}`)
		case "/api/playlet/detail":
			detail++
			if r.Form.Get("video_id") != "123" || r.Form.Get("id") != "123" {
				t.Errorf("yeguo detail form: %s", r.Form.Encode())
			}
			fmt.Fprint(w, `{"status":"1","data":{"video_id":"123","title":"野果样本","episode_count":2,"episodes":[{"id":"456","sort":1},{"id":"457","sort":2}]}}`)
		case "/api/playlet/play":
			play++
			if r.Form.Get("playlet_id") != "123" || r.Form.Get("episode_id") != "456" {
				t.Errorf("yeguo play form: %s", r.Form.Encode())
			}
			fmt.Fprintf(w, `{"status":"1","data":{"playlet_id":"123","id":"456","episode_sort":1,"video_url":%q,"video_url_h265":%q}}`, server.URL+"/a.mp4", server.URL+"/b.mp4")
		default:
			t.Errorf("unexpected yeguo route %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := newSourceMobileClient(t)
	client.downloader.cfg.YeguoURL = server.URL
	yeguo := client.downloader.yeguoClient()
	yeguo.access = &yeguoAccess{base: server.URL, site: server.URL, identifier: "fixture-trace", loadedAt: time.Now()}

	categories := newMobileSourceRows(t, callNewMobileSource(t, client, map[string]any{"method": "categories", "source": "yeguo"}), "items")
	if len(categories) != 2 || categories[0]["id"] != "" || categories[1]["id"] != "theme:7" {
		t.Fatalf("yeguo categories: %+v", categories)
	}
	assertNewSourcePage(t, callNewMobileSource(t, client, map[string]any{"method": "catalog", "source": "yeguo", "category": "theme:7", "page": 2}), "yeguo", "yeguo:123", true)
	assertNewSourcePage(t, callNewMobileSource(t, client, map[string]any{"method": "search", "source": "yeguo", "category": "theme:7", "query": " 样本 ", "page": 2}), "yeguo", "yeguo:123", true)
	assertNewSourceInvalidCategory(t, client, "yeguo")
	item := callNewMobileSource(t, client, map[string]any{"method": "detail", "id": "yeguo:123"})["item"].(map[string]any)
	if item["id"] != "yeguo:123" || item["source"] != "yeguo" || item["episodes"] != float64(2) {
		t.Fatalf("yeguo detail: %+v", item)
	}
	chapters := newMobileSourceRows(t, callNewMobileSource(t, client, map[string]any{"method": "chapters", "id": "yeguo:123"}), "chapters")
	if len(chapters) != 2 || chapters[0]["id"] != "yeguo:123:456" || chapters[1]["id"] != "yeguo:123:457" {
		t.Fatalf("yeguo chapters: %+v", chapters)
	}
	resolved := callNewMobileSource(t, client, map[string]any{"method": "resolve", "id": "yeguo:123", "chapter": chapters[0]})
	secureMedia := "https" + strings.TrimPrefix(server.URL, "http")
	if resolved["remoteUrl"] != secureMedia+"/a.mp4" || resolved["routeCount"] != float64(2) || resolved["castDirect"] != true {
		t.Fatalf("yeguo resolve: %+v", resolved)
	}
	fallback := callNewMobileSource(t, client, map[string]any{"method": "fallback", "id": resolved["session"]})
	if fallback["remoteUrl"] != secureMedia+"/b.mp4" || fallback["routeIndex"] != float64(1) {
		t.Fatalf("yeguo fallback: %+v", fallback)
	}
	callNewMobileSource(t, client, map[string]any{"method": "release", "id": resolved["session"]})
	callNewMobileSource(t, client, map[string]any{"method": "release", "id": fallback["session"]})
	if catalog != 1 || search != 1 || detail != 2 || play != 1 {
		t.Fatalf("yeguo route counts: catalog=%d search=%d detail=%d play=%d", catalog, search, detail, play)
	}
}

func TestMobileDSDSourceContracts(t *testing.T) {
	var server *httptest.Server
	var catalog, search, detail, play int
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		switch {
		case r.URL.Path == "/":
			fmt.Fprint(w, `<a href="/index.php/vod/type/id/9/page/1.html">短剧</a>`)
		case strings.HasPrefix(r.URL.Path, "/index.php/vod/type/id/9/page/"):
			page := "1"
			if strings.Contains(r.URL.Path, "/page/2.html") {
				page = "2"
				catalog++
			}
			fmt.Fprintf(w, `<div class="video-contaner"><a class="video-item" href="/index.php/vod/play/id/321/sid/1/nid/1.html"><span class="video-desc">帝果样本</span></a></div><div class="pagination"><span class="active number">%s</span><a href="/index.php/vod/type/id/9/page/3.html">3</a></div>`, page)
		case r.URL.Path == "/index.php/vod/search.html":
			search++
			if r.URL.Query().Get("wd") != "样本" || r.URL.Query().Get("page") != "2" {
				t.Errorf("dsd search query: %s", r.URL.RawQuery)
			}
			io.WriteString(w, `<div class="search-page"><a class="video-item" href="/index.php/vod/play/id/321/sid/1/nid/1.html"><span class="video-desc">帝果样本</span></a></div><div class="pagination"><span class="active number">2</span><a href="/index.php/vod/search.html?wd=%E6%A0%B7%E6%9C%AC&amp;page=3">3</a></div>`)
		case r.URL.Path == "/index.php/vod/play/id/321/sid/1/nid/1.html":
			detail++
			if detail == 3 {
				play++
			}
			fmt.Fprintf(w, `<div class="video-info"><h1>帝果样本</h1></div><a href="/index.php/vod/play/id/321/sid/1/nid/2.html">第 2 集</a><script>var player_fixture = {"id":"321","sid":1,"nid":1,"url":%q,"vod_data":{"vod_name":"帝果样本"}};</script>`, server.URL+"/media.mp4?sign=fixture")
		default:
			t.Errorf("unexpected dsd route %s", r.URL.String())
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := newSourceMobileClient(t)
	client.downloader.cfg.DSDURL = server.URL

	categories := newMobileSourceRows(t, callNewMobileSource(t, client, map[string]any{"method": "categories", "source": "dsd"}), "items")
	if len(categories) != 2 || categories[0]["id"] != "" || categories[1]["id"] != "9" {
		t.Fatalf("dsd categories: %+v", categories)
	}
	assertNewSourcePage(t, callNewMobileSource(t, client, map[string]any{"method": "catalog", "source": "dsd", "category": "9", "page": 2}), "dsd", "dsd:321", true)
	assertNewSourcePage(t, callNewMobileSource(t, client, map[string]any{"method": "search", "source": "dsd", "query": " 样本 ", "page": 2}), "dsd", "dsd:321", true)
	assertNewSourceInvalidCategory(t, client, "dsd")
	item := callNewMobileSource(t, client, map[string]any{"method": "detail", "id": "dsd:321"})["item"].(map[string]any)
	if item["id"] != "dsd:321" || item["source"] != "dsd" || item["episodes"] != float64(2) {
		t.Fatalf("dsd detail: %+v", item)
	}
	chapters := newMobileSourceRows(t, callNewMobileSource(t, client, map[string]any{"method": "chapters", "id": "dsd:321"}), "chapters")
	if len(chapters) != 2 || chapters[0]["id"] != "dsd:321:1-1" || chapters[1]["id"] != "dsd:321:1-2" {
		t.Fatalf("dsd chapters: %+v", chapters)
	}
	resolved := callNewMobileSource(t, client, map[string]any{"method": "resolve", "id": "dsd:321", "chapter": chapters[0]})
	secureMedia := "https" + strings.TrimPrefix(server.URL, "http")
	if resolved["remoteUrl"] != secureMedia+"/media.mp4?sign=fixture" || resolved["routeCount"] != float64(1) || resolved["castDirect"] != false {
		t.Fatalf("dsd resolve: %+v", resolved)
	}
	callNewMobileSource(t, client, map[string]any{"method": "release", "id": resolved["session"]})
	if catalog != 1 || search != 1 || detail != 3 || play != 1 {
		t.Fatalf("dsd route counts: catalog=%d search=%d detail=%d play=%d", catalog, search, detail, play)
	}
}
