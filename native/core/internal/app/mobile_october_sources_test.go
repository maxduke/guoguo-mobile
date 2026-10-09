package app

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestOctoberSourcesMobileCatalogDetailAndPlaybackContracts(t *testing.T) {
	for _, source := range []string{sourceChaoguo, sourceMiguo, sourceShuangguo} {
		t.Run(source, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.URL.Path == "/stream.m3u8":
					fmt.Fprint(w, "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n")
				case strings.Contains(r.URL.Path, "/play/"):
					fmt.Fprintf(w, `<script>var player_aaaa={"url":"http://%s/stream.m3u8"}</script>`, r.Host)
				case strings.Contains(r.URL.Path, "/drama/"):
					body := strings.ReplaceAll(chaoguoDetailFixture, "https://stream.example.cn/m/aaa/playlist.m3u8", "http://"+r.Host+"/stream.m3u8")
					body = strings.ReplaceAll(body, "https://stream.example.cn/m/bbb/playlist.m3u8", "http://"+r.Host+"/stream.m3u8")
					fmt.Fprint(w, body)
				case strings.Contains(r.URL.Path, "/voddetail/") || r.URL.Path == "/vod/88.html":
					fmt.Fprint(w, `<h1>样本剧</h1><ul class="playlist"><a href="/play/88-1-1.html">第1集</a><a href="/play/88-1-2.html">第2集</a></ul>`)
				case source == sourceChaoguo:
					fmt.Fprint(w, chaoguoCatalogFixture)
				case strings.HasPrefix(r.URL.Path, "/vodtype/") || strings.HasPrefix(r.URL.Path, "/show/") || strings.HasPrefix(r.URL.Path, "/search/") || strings.HasPrefix(r.URL.Path, "/vodsearch/"):
					fmt.Fprint(w, `<div class="module-item"><a href="/voddetail/88.html" title="样本剧"></a></div>`)
				default:
					t.Errorf("unexpected resource request: %s", r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			c := newSourceMobileClient(t)
			c.downloader.client = server.Client()
			c.downloader.limiter = newRequestLimiter(4, time.Nanosecond)
			c.downloader.providerHosts[source] = server.URL
			categories := callNewMobileSource(t, c, map[string]any{"method": "categories", "source": source})
			if len(newMobileSourceRows(t, categories, "items")) == 0 {
				t.Fatal("source categories were not exposed")
			}
			catalog := callNewMobileSource(t, c, map[string]any{"method": "catalog", "source": source})
			rows := newMobileSourceRows(t, catalog, "items")
			if len(rows) == 0 || rows[0]["source"] != source || catalog["page"] != float64(1) {
				t.Fatal("catalog lost source identity", catalog)
			}
			id := rows[0]["id"].(string)
			item := callNewMobileSource(t, c, map[string]any{"method": "detail", "id": id})["item"].(map[string]any)
			if item["id"] != id || item["source"] != source {
				t.Fatal("detail lost source identity", item)
			}
			chapters := newMobileSourceRows(t, callNewMobileSource(t, c, map[string]any{"method": "chapters", "id": id}), "chapters")
			if len(chapters) != 2 {
				t.Fatal("unexpected chapter count", len(chapters))
			}
			resolved := callNewMobileSource(t, c, map[string]any{"method": "resolve", "id": id, "chapter": chapters[0]})
			if resolved["remoteUrl"] != server.URL+"/stream.m3u8" || resolved["routeCount"] != float64(1) {
				t.Fatal("mobile playback did not retain the resolved media", resolved)
			}
			callNewMobileSource(t, c, map[string]any{"method": "release", "id": resolved["session"]})
		})
	}
}
