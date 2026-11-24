package app

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestHPPColdCatalogSurvivesScriptHostFailureAndRestart(t *testing.T) {
	const script = `
export const meta = { id: 'fixture.catalog', protocol: 1 };
export default hg => ({ catalog: {
  async getCategories() { return [{id: 'movies', label: '电影'}]; },
  async list() {
    const response = await hg.http.fetch({url: 'https://catalog.example.org/movies', responseType: 'json'});
    return {items: response.data};
  }
}});`
	spec := hppSource{file: "fixture.catalog", home: "https://catalog.example.org/", hash: fmt.Sprintf("%x", sha256.Sum256([]byte(script)))}
	t.Cleanup(func() { hppPrograms.Delete(spec.file) })
	directory := t.TempDir()
	var scriptHosts []string
	for _, restarted := range []bool{false, true} {
		client, err := NewMobileClient(directory)
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
			host := request.URL.Hostname()
			if host == "catalog.example.org" && request.URL.Path == "/movies" {
				return rankingHTTPResponse(request, 200, `[{"id":"m1","title":"目录样本"}]`), nil
			}
			scriptHosts = append(scriptHosts, host)
			if restarted || host != "cdn.jsdelivr.net" {
				return nil, errors.New("script host unreachable")
			}
			wantPath := "/gh/poisonhs/HGhub-Plugin@" + hppRevision + "/plugins/" + spec.file + ".js"
			if request.URL.Path != wantPath {
				t.Errorf("alternate script host requested %s, want %s", request.URL.Path, wantPath)
			}
			return rankingHTTPResponse(request, 200, script), nil
		})
		rows, _, err := client.downloader.hppPage(context.Background(), "fixture", spec, 1, "", "")
		if err != nil || len(rows) != 1 || rows[0].Title != "目录样本" {
			t.Fatalf("restarted=%v, rows=%+v, hosts=%v: %v", restarted, rows, scriptHosts, err)
		}
		hppPrograms.Delete(spec.file)
	}
	if want := "raw.githubusercontent.com,cdn.jsdelivr.net"; strings.Join(scriptHosts, ",") != want {
		t.Fatalf("script hosts=%v, want %s", scriptHosts, want)
	}
}

func TestHPPRejectsUnverifiedCachedAndDownloadedScripts(t *testing.T) {
	client := newSourceMobileClient(t)
	spec := hppSources["yingxi"]
	t.Cleanup(func() { hppPrograms.Delete(spec.file) })
	const changedScript = `export const meta = {id: 'yingxi.source', protocol: 1}; export default hg => ({});`
	if err := os.WriteFile(filepath.Join(client.downloader.cfg.dataDirectory(), "hpp-"+spec.file+".js"), []byte(changedScript), 0600); err != nil {
		t.Fatal(err)
	}
	var networkCalls int
	client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		networkCalls++
		return rankingHTTPResponse(request, 200, changedScript), nil
	})
	trace := &mobileTrace{value: mobileDiagnostic{At: time.Now()}}
	ctx := context.WithValue(context.Background(), mobileTraceKey{}, trace)
	err := client.downloader.useHPP(ctx, spec, func(*hppInvocation) error {
		t.Fatal("unverified script reached the runtime")
		return nil
	})
	if networkCalls != 2 || err == nil || !strings.Contains(err.Error(), "校验失败") || trace.snapshot(err, nil, true).SourceStage != "plugin_script" {
		t.Fatalf("calls=%d, error=%v, trace=%+v", networkCalls, err, trace.value)
	}
}

func TestHPPBFZYCatalogUsesOfficialPrimaryAPI(t *testing.T) {
	client := newSourceMobileClient(t)
	spec := hppSources["bfzy"]
	program, err := compileHPP(spec.file, `
export const meta = {id: 'bfzy.source', protocol: 1};
export default hg => ({catalog: {async list() {
  const response = await hg.http.fetch({url:'https://bfzyapi.com/api.php/provide/vod/?ac=detail', query:{t:'20', pg:2}, responseType:'json'});
  return {items: response.data};
}}});`)
	if err != nil {
		t.Fatal(err)
	}
	client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		if request.URL.Host != "apibfzy.com" || request.URL.Path != "/api.php/provide/vod/" ||
			request.URL.Query().Get("ac") != "detail" || request.URL.Query().Get("t") != "20" || request.URL.Query().Get("pg") != "2" {
			t.Errorf("unexpected BFZY request %s", request.URL)
		}
		return rankingHTTPResponse(request, 200, `[{"id":"1","title":"样本"}]`), nil
	})
	var result struct{ Items []hppItem }
	err = client.downloader.useHPPProgram(context.Background(), spec, program, func(p *hppInvocation) error {
		return p.call("catalog", "list", nil, &result)
	})
	if err != nil || len(result.Items) != 1 || result.Items[0].ID != "1" {
		t.Fatalf("items=%+v err=%v", result.Items, err)
	}
}

func TestHPPCatalogSupportsChunkedIndexRequestsWithinLimits(t *testing.T) {
	client := newSourceMobileClient(t)
	spec := hppSource{file: "fixture.index"}
	program, err := compileHPP(spec.file, `
export const meta = {id: 'fixture.index', protocol: 1};
export default hg => ({catalog: {async list() {
  let queued = false;
  const yieldBetweenChunks = new Promise(resolve => setTimeout(() => resolve(queued), 0));
  queued = true;
  if (!await yieldBetweenChunks) throw new Error('callback did not yield');
  const reply = await hg.http.fetch({url: 'https://catalog.example.org/index', maxBytes: 6 * 1024 * 1024, timeoutMs: 25000});
  return {size: reply.data.length};
}}});`)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 32*time.Second)
	defer cancel()
	for _, size := range []int{5 << 20, (6 << 20) + 1} {
		client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
			deadline, ok := request.Context().Deadline()
			if !ok || time.Until(deadline) < 22*time.Second || time.Until(deadline) > 25*time.Second {
				t.Fatalf("unexpected index timeout: %v", time.Until(deadline))
			}
			return rankingHTTPResponse(request, 200, strings.Repeat("x", size)), nil
		})
		var result struct{ Size int }
		err = client.downloader.useHPPProgram(ctx, spec, program, func(p *hppInvocation) error {
			return p.call("catalog", "list", nil, &result)
		})
		if size <= 6<<20 && (err != nil || result.Size != size) {
			t.Fatalf("index size=%d, received=%d: %v", size, result.Size, err)
		}
		if size > 6<<20 && (err == nil || !strings.Contains(err.Error(), "内容过大")) {
			t.Fatalf("oversized index was not rejected: %v", err)
		}
	}
}

func TestHPPStaleHL365EpisodeNeverFallsBackToFirst(t *testing.T) {
	client := newSourceMobileClient(t)
	spec := hppSources["hl365"]
	program, err := compileHPP(spec.file, `
export const meta = {id: 'hl365.source', protocol: 1};
export default hg => ({media: {
  async getDetail(params) {
    return {id: params.id, title: '测试剧', playlists: [{id: 'main', episodes: [{id: 'e0', label: '首集'}]}]};
  },
  async resolvePlayback() {
    return {streams: [{url: 'https://media.example.org/first.mp4', format: 'progressive'}]};
  }
}});`)
	if err != nil {
		t.Fatal(err)
	}
	hppPrograms.Store(spec.file, &hppProgram{lock: make(chan struct{}, 1), code: program})
	t.Cleanup(func() { hppPrograms.Delete(spec.file) })
	ctx := context.Background()
	id := hppKey("12")
	for _, episode := range []string{"e0", "e4"} {
		media, err := client.downloader.hppResolve(ctx, "hl365", spec, Task{
			DramaID: providerDramaID("hl365", id),
			Chapter: Chapter{ID: providerChapterID("hl365", id, hppKey("main")+"."+hppKey(episode)), Source: "hl365"},
		})
		if episode == "e0" && (err != nil || media.URL != "https://media.example.org/first.mp4") {
			t.Fatalf("valid episode did not resolve: %+v, %v", media, err)
		}
		if episode == "e4" && (err == nil || !strings.Contains(err.Error(), "分集已更新") || media.URL != "") {
			t.Fatalf("stale episode substituted another stream: %+v, %v", media, err)
		}
	}
}

func TestHPPDiscoveryExposesCatalogBoardForEveryPlugin(t *testing.T) {
	client := newSourceMobileClient(t)
	for source := range hppSources {
		t.Run(source, func(t *testing.T) {
			data := callNewMobileSource(t, client, map[string]any{"method": "boards", "source": source})
			items := data["items"].([]any)
			if len(items) != 1 {
				t.Fatalf("boards=%+v, want one catalog board", items)
			}
			item := items[0].(map[string]any)
			if item["source"] != source || item["kind"] != "catalog" || item["id"] != source+"-catalog" {
				t.Fatalf("wrong catalog board: %+v", item)
			}
		})
	}
	for _, source := range []string{"juzong", "chengguo", "dhvideo", "hhkan"} {
		data := callNewMobileSource(t, client, map[string]any{"method": "boards", "source": source})
		if items := data["items"].([]any); len(items) != 0 {
			t.Fatalf("browser-only source %s has boards: %+v", source, items)
		}
	}
}

func TestHPPMobileSourceFromDiscoveryThroughProxyRelease(t *testing.T) {
	client := newSourceMobileClient(t)
	spec := hppSources["pianku"]
	program, err := compileHPP(spec.file, `
export const meta = { id: 'pianku.source', protocol: 1 };
export default hg => ({
  catalog: {
    async getCategories() { return [{id: 'group', label: '影视', children: [{id: 'series/latest', label: '剧集'}]}]; },
    async list(params) {
      if (params.categoryId !== 'series/latest') throw new Error('bad category');
      await hg.storage.set('seen', true).catch(() => {});
      if (!await hg.storage.get('seen').catch(() => false)) throw new Error('bad storage');
      const res = await hg.http.fetch({url: 'https://catalog.example.org/list', query: {page: params.cursor}});
      const doc = hg.html.parse(res.data);
      return {items: doc.select('a.drama').map(a => ({id: a.attr('data-id'), title: a.text()})), next: String(Number(params.cursor) + 1)};
    }
  },
  search: {async search(params) { return {items: [{id: 'item:42', title: params.query}]}; }},
  media: {
    async getDetail(params) {
      return {id: params.id, title: '测试剧', playlists: [{id: 'route.a', kind: 'main', episodes: [{id: 'e:1', label: '首集', episodeNumber: 3}]}]};
    },
    async resolvePlayback(params) {
      if (params.mediaId !== 'item:42' || params.playlistId !== 'route.a' || params.episodeId !== 'e:1') throw new Error('bad identity');
      return {streams: [{url: 'https://media.example.org/manifest', format: 'hls'}]};
    }
  }
});`)
	if err != nil {
		t.Fatal(err)
	}
	hppPrograms.Store(spec.file, &hppProgram{lock: make(chan struct{}, 1), code: program})
	t.Cleanup(func() { hppPrograms.Delete(spec.file) })
	expectedPage := "2"
	client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		if request.Context().Value(hppPublicRequestKey{}) != true {
			t.Error("plugin request did not use the public-only transport")
		}
		switch request.URL.Path {
		case "/list":
			if request.URL.Query().Get("page") != expectedPage {
				t.Errorf("catalog did not pass pagination: %s", request.URL)
			}
			return rankingHTTPResponse(request, 200, `<a class="drama" data-id="item:42">测试剧</a>`), nil
		case "/manifest":
			if _, present := request.Header["Referer"]; present {
				t.Error("unexpected default media Referer")
			}
			return rankingHTTPResponse(request, 200, "#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n"), nil
		case "/segment.ts":
			return rankingHTTPResponse(request, 200, "segment fixture"), nil
		}
		t.Errorf("unexpected request %s", request.URL)
		return rankingHTTPResponse(request, 404, ""), nil
	})
	adapter, ok := client.downloader.mobileSource("pianku")
	if !ok {
		t.Fatal("missing source adapter")
	}
	ctx := context.Background()
	categories, err := adapter.categories(ctx)
	if err != nil || len(categories) != 1 || categories[0].Name != "影视 · 剧集" || !validNativeCategory("pianku", categories[0].ID) {
		t.Fatalf("categories=%+v err=%v", categories, err)
	}
	data := callNewMobileSource(t, client, map[string]any{"method": "catalog", "source": "pianku", "page": 2})
	id := providerDramaID("pianku", hppKey("item:42"))
	assertNewSourcePage(t, data, "pianku", id, true)
	for _, page := range []int{1, 2} {
		expectedPage = fmt.Sprint(page)
		column := callNewMobileSource(t, client, map[string]any{"method": "ranking", "board": "pianku-catalog", "page": page})
		rows := column["items"].([]any)
		if len(rows) != 1 || column["kind"] != "catalog" || column["hasMore"] != true {
			t.Fatalf("column page %d: %+v", page, column)
		}
		row := rows[0].(map[string]any)
		drama := row["drama"].(map[string]any)
		if row["rank"] != float64(0) || drama["source"] != "pianku" || drama["id"] != id {
			t.Fatalf("wrong catalog card identity or rank: %+v", row)
		}
	}
	search := callNewMobileSource(t, client, map[string]any{"method": "search", "source": "pianku", "query": "测试剧", "page": 2})
	assertNewSourcePage(t, search, "pianku", id, false)
	detail := callNewMobileSource(t, client, map[string]any{"method": "detail", "id": id})
	if item := detail["item"].(map[string]any); item["id"] != id || item["source"] != "pianku" {
		t.Fatalf("incorrect detail identity: %+v", item)
	}
	chapterResponse := callNewMobileSource(t, client, map[string]any{"method": "chapters", "id": id})
	chapters := chapterResponse["chapters"].([]any)
	if len(chapters) != 1 {
		t.Fatalf("chapters=%+v", chapters)
	}
	chapter := chapters[0].(map[string]any)
	if chapter["id"] != providerChapterID("pianku", hppKey("item:42"), hppKey("route.a")+"."+hppKey("e:1")) {
		t.Fatalf("wrong chapter identity: %+v", chapter)
	}
	media := callNewMobileSource(t, client, map[string]any{"method": "resolve", "id": id, "chapter": chapter})
	session, _ := media["session"].(string)
	proxy, err := url.Parse(media["url"].(string))
	if err != nil || proxy.Hostname() != "127.0.0.1" || media["hls"] != true || session == "" {
		t.Fatalf("incorrect playback session: %+v, %v", media, err)
	}
	loopback := &http.Client{Timeout: 2 * time.Second}
	read := func(address string) string {
		t.Helper()
		response, err := loopback.Get(address)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		body, err := io.ReadAll(io.LimitReader(response.Body, 4096))
		if err != nil || response.StatusCode != http.StatusOK {
			t.Fatalf("media proxy status=%d read=%v", response.StatusCode, err)
		}
		return string(body)
	}
	manifest := read(proxy.String())
	_, segment, ok := strings.Cut(manifest, "#EXTINF:1,\n")
	line, _, _ := strings.Cut(segment, "\n")
	asset, err := proxy.Parse(line)
	if !ok || err != nil || asset.Host != proxy.Host || read(asset.String()) != "segment fixture" {
		t.Fatalf("invalid proxy manifest: %q", manifest)
	}
	callNewMobileSource(t, client, map[string]any{"method": "release", "id": session})
	if len(client.proxies) != 0 || len(client.playbacks) != 0 {
		t.Fatal("playback resources remain after release")
	}
	wrong, _ := json.Marshal(map[string]any{"method": "resolve", "id": providerDramaID("pianku", hppKey("other")), "chapter": chapter})
	if _, err := client.Call(string(wrong)); err == nil {
		t.Fatal("accepted a chapter belonging to another item")
	}
}

func TestHPPStopsAfterARefusal(t *testing.T) {
	client := newSourceMobileClient(t)
	var calls atomic.Int32
	client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		return rankingHTTPResponse(request, 403, ""), nil
	})
	spec := hppSource{file: "fixture.source"}
	program, err := compileHPP(spec.file, `
export const meta = {id: 'fixture.source', protocol: 1};
export default hg => ({catalog: {async list() {
  try { await hg.http.fetch({url: 'https://first.example.org/'}); } catch (_) {}
  try { await hg.http.fetch({url: 'https://second.example.org/'}); } catch (_) {}
  return {items: []};
}}});`)
	if err != nil {
		t.Fatal(err)
	}
	err = client.downloader.useHPPProgram(context.Background(), spec, program, func(p *hppInvocation) error {
		var result json.RawMessage
		return p.call("catalog", "list", nil, &result)
	})
	if err == nil || calls.Load() != 1 {
		t.Fatalf("calls=%d err=%v", calls.Load(), err)
	}
}
