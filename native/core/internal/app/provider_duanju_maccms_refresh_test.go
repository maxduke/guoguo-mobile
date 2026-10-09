package app

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"golang.org/x/net/html"
)

func TestNewMaccmsSourcesRouteCatalogSearchAndOwnedEpisodes(t *testing.T) {
	for _, source := range []string{sourceMiguo, sourceShuangguo} {
		t.Run(source, func(t *testing.T) {
			var paths []string
			d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
				paths = append(paths, r.URL.RequestURI())
				if strings.Contains(r.URL.Path, "/voddetail/") || r.URL.Path == "/vod/88.html" {
					fmt.Fprint(w, `<h1>本剧第二季</h1><ul class="playlist"><a href="/vodplay/88-1-1.html">第1集</a><a href="/vodplay/88-2-1.html">第1集</a><a href="/vodplay/88-1-2.html">第2集</a><a href="/vodplay/77-1-1.html">相关推荐第1集</a></ul>`)
					return
				}
				fmt.Fprint(w, `<div class="module-item"><a href="/vodtype/36.html">短剧</a><a href="/voddetail/88.html" title="高亮&lt;em&gt;剧&lt;/em&gt;名"></a></div><div class="pagination"><span>末页</span></div>`)
			})
			d.providerHosts[source] = server.URL
			items, more, err := d.fetchDuanjuCatalogPage(context.Background(), source, 1, "")
			if err != nil || len(items) != 1 || items[0].SourceID != "88" || items[0].Title != "高亮剧名" || more {
				t.Fatalf("catalog: %+v more=%t err=%v", items, more, err)
			}
			if source == sourceMiguo {
				if paths[0] != "/vodtype/36.html" {
					t.Fatal("wrong Miguo catalog route", paths)
				}
				before := len(paths)
				rows, more, err := d.fetchDuanjuCatalogPage(context.Background(), source, 2, "")
				if err != nil || len(rows) != 0 || more || len(paths) != before {
					t.Fatal("Miguo fetched its single-page catalog again")
				}
			} else {
				if paths[0] != "/show/26-----------.html" {
					t.Fatal("wrong Shuangguo catalog route", paths)
				}
				_, _, err := d.fetchDuanjuCatalogPage(context.Background(), source, 2, "现代都市")
				if err != nil || !strings.HasPrefix(paths[len(paths)-1], "/show/26---") || !strings.HasSuffix(paths[len(paths)-1], "-----2---.html") {
					t.Fatal("Shuangguo category/page lost", paths, err)
				}
			}
			rows, more, err := d.searchDuanjuPage(context.Background(), source, "样本", 2)
			if err != nil || len(rows) != 1 || more || !strings.Contains(paths[len(paths)-1], "----------2---.html") {
				t.Fatal("search paging lost", paths, err)
			}
			drama, chapters, err := d.fetchDuanjuDetail(context.Background(), source, "88")
			if err != nil || drama.Title != "本剧第二季" || len(chapters) != 2 || !strings.Contains(chapters[1].PageURL, "88-1-2") {
				t.Fatalf("owned chapters: %+v err=%v", chapters, err)
			}
		})
	}
}

func TestMaccmsPlaybackUsesDeclaredSourceAndBoundedWrapper(t *testing.T) {
	if got := maccmsPlayerURL(`<script>const demo="https://demo.example/test1.mp4";const source = 'https://media.example/real.m3u8';</script>`); got != "https://media.example/real.m3u8" {
		t.Fatal("sample media replaced the declared source", got)
	}
	if got := maccmsPlayerURL(`<a href="https://mp4.#.mp4"></a>`); got != "" {
		t.Fatal("template placeholder became playable media", got)
	}
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/play":
			fmt.Fprintf(w, `<script>var player_aaaa={"url":"http://%s/share"}</script>`, r.Host)
		case "/share":
			fmt.Fprint(w, `<script>const source = 'https://media.example/real.m3u8';</script>`)
		case "/loop":
			fmt.Fprintf(w, `<script>var player_aaaa={"url":"http://%s/loop"}</script>`, r.Host)
		case "/hls-play":
			fmt.Fprintf(w, `<script>var player_aaaa={"url":"http://%s/hls-share"}</script>`, r.Host)
		case "/hls-share":
			fmt.Fprintf(w, `<script>var player_aaaa={"url":"http://%s/stream"}</script>`, r.Host)
		case "/stream":
			if r.Referer() != "http://"+r.Host+"/hls-share" {
				t.Error("opaque HLS lost the immediate player Referer", r.Referer())
			}
			fmt.Fprint(w, "\ufeff#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n")
		default:
			t.Errorf("unexpected media/image request: %s", r.URL.Path)
		}
	})
	media, err := d.resolveDuanjuWebPage(context.Background(), sourceMiguo, server.URL+"/play", server.URL+"/")
	if err != nil || media.URL != "https://media.example/real.m3u8" || media.Referer != server.URL+"/share" {
		t.Fatal("wrapper did not resolve with its own Referer", media, err)
	}
	if _, err := d.resolveDuanjuWebPage(context.Background(), sourceMiguo, server.URL+"/loop", server.URL+"/"); err == nil {
		t.Fatal("a cyclic player shell became a media address")
	}
	media, err = d.resolveDuanjuWebPage(context.Background(), sourceMiguo, server.URL+"/hls-play", server.URL+"/")
	if err != nil || media.URL != server.URL+"/stream" || media.Referer != server.URL+"/hls-share" || !strings.Contains(media.Playlist, "#EXTM3U") {
		t.Fatal("opaque HLS lost its playlist or immediate Referer", media, err)
	}
}

func TestMaccmsPaginationStopsAtTheLastNonemptyPage(t *testing.T) {
	for _, fixture := range []struct {
		body string
		more bool
	}{
		{`<div class="pagination"><a href="/search/q----------2---.html">2</a></div>`, true},
		{`<div class="pagination"><a href="/search/q----------1---.html">1</a><span>末页</span></div>`, false},
		{`<div class="pagination"><a href="javascript:;">下一页</a></div>`, false},
	} {
		document, _ := html.Parse(strings.NewReader(fixture.body))
		if more := maccmsHasMore(document, 1, 10); more != fixture.more {
			t.Fatalf("pagination=%s more=%t", fixture.body, more)
		}
	}
}

func TestMaccmsTitlesKeepActualSeasonsAndParts(t *testing.T) {
	for _, title := range []string{"本剧第2季", "本剧第2部", "2001太空漫游"} {
		if got := maccmsCleanTitle(title); got != title {
			t.Fatalf("real title changed: %s => %s", title, got)
		}
	}
}
