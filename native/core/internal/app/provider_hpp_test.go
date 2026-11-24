package app

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
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
  const response = await hg.http.fetch({url:'https://bfzyapi.com/api.php/provide/vod/?ac=detail', query:{t:'20'}, responseType:'json'});
  return {items: response.data};
}}});`)
	if err != nil {
		t.Fatal(err)
	}
	client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		if request.URL.Host != "apibfzy.com" || request.URL.Path != "/api.php/provide/vod/" ||
			request.URL.Query().Get("ac") != "detail" || request.URL.Query().Get("t") != "20" {
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

func TestHPPMobileSourceUsesCatalogAndEpisodeIdentity(t *testing.T) {
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
      return {items: doc.select('a.drama').map(a => ({id: a.attr('data-id'), title: a.text()})), next: '3'};
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
	client.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		if request.Context().Value(hppPublicRequestKey{}) != true {
			t.Error("plugin request did not use the public-only transport")
		}
		switch request.URL.Path {
		case "/list":
			if request.URL.Query().Get("page") != "2" {
				t.Errorf("catalog did not pass pagination: %s", request.URL)
			}
			return rankingHTTPResponse(request, 200, `<a class="drama" data-id="item:42">测试剧</a>`), nil
		case "/manifest":
			if _, present := request.Header["Referer"]; present {
				t.Error("unexpected default media Referer")
			}
			return rankingHTTPResponse(request, 200, "#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n"), nil
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
	search := callNewMobileSource(t, client, map[string]any{"method": "search", "source": "pianku", "query": "测试剧", "page": 2})
	assertNewSourcePage(t, search, "pianku", id, false)
	_, chapters, err := adapter.detail(ctx, hppKey("item:42"))
	if err != nil || len(chapters) != 1 || chapters[0].EpisodeString(0) != "3" {
		t.Fatalf("detail=%+v err=%v", chapters, err)
	}
	media, err := adapter.resolve(ctx, Task{DramaID: id, Chapter: chapters[0]})
	if err != nil || !strings.HasPrefix(media.Playlist, "#EXTM3U") || !media.credentials.publicOnly {
		t.Fatalf("media=%+v err=%v", media, err)
	}
	if _, err := adapter.resolve(ctx, Task{DramaID: providerDramaID("pianku", hppKey("other")), Chapter: chapters[0]}); err == nil {
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
