package app

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/url"
	"testing"
)

func TestDbkuCatalogSearchAndEpisodes(t *testing.T) {
	ctx := context.Background()
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		const card = `<div class="myui-vodlist__box"><a href="/voddetail/88.html" title="示例剧"></a></div>`
		switch r.URL.Path {
		case "/vodshow/21-----------.html":
			fmt.Fprint(w, card, `<ul class="myui-page"><li><a href="/vodshow/21--------2---.html">2</a></li></ul>`)
		case "/vodshow/21--------2---.html":
			fmt.Fprint(w, card, `<ul class="myui-page"><li><a href="/vodshow/21-----------.html">1</a></li></ul>`)
		case "/vodsearch/-------------.html":
			if r.URL.Query().Get("wd") != "示例剧" {
				t.Errorf("search query = %q", r.URL.Query().Get("wd"))
			}
			fmt.Fprint(w, card)
		case "/voddetail/88.html":
			fmt.Fprint(w, `<h1>示例剧</h1><ul class="playlist">
<li><a href="/vodplay/88-1-3.html">第三集</a></li>
<li><a href="/vodplay/99-1-1.html">推荐</a></li>
<li><a href="https://other.example/vodplay/88-1-2.html">站外</a></li>
<li><a href="/vodplay/88-1-1.html">第一集</a></li>
<li><a href="/vodplay/88-2-1.html">备用</a></li></ul>`)
		default:
			t.Errorf("unexpected request: %s", r.URL)
			w.WriteHeader(http.StatusNotFound)
		}
	})
	d.providerHosts[sourceDbku] = server.URL
	for _, page := range []int{1, 2} {
		items, more, err := d.fetchDuanjuCatalogPage(ctx, sourceDbku, page, "")
		if err != nil || len(items) != 1 || items[0].ID != "dbku:88" || more != (page == 1) {
			t.Fatalf("catalog page %d: %+v more=%t err=%v", page, items, more, err)
		}
	}
	if items, more, err := d.searchDuanjuPage(ctx, sourceDbku, "示例剧", 1); err != nil || len(items) != 1 || more {
		t.Fatalf("search: %+v more=%t err=%v", items, more, err)
	}
	_, chapters, err := d.fetchDuanjuDetail(ctx, sourceDbku, "88")
	if err != nil || len(chapters) != 2 || chapters[0].ID != "dbku:88:1" || chapters[1].ID != "dbku:88:3" {
		t.Fatalf("detail: %+v err=%v", chapters, err)
	}
	if _, err := d.resolveDbkuMedia(ctx, "88", chapters[0].ID, chapters[1].PageURL, server.URL); err == nil {
		t.Fatal("accepted a playback page from a different episode")
	}
}

func TestDbkuMediaReadsOnlyTheDeclaredPlayer(t *testing.T) {
	want := "https://vid.dbokutv.com/sample/index.m3u8?x=a+b"
	encoded := base64.RawURLEncoding.EncodeToString([]byte(url.QueryEscape(want)))
	body := fmt.Sprintf(`<script>var sample="https://vid.dbokutv.com/demo.mp4";var player_data={"url":%q,"encrypt":2,"meta":{"note":"}"}};</script>`, encoded)
	if got := dbkuMediaAddress(body); got != want {
		t.Fatalf("decoded address = %q", got)
	}
	for _, body := range []string{
		`<script>var player_data={"url":"https://other.example/index.m3u8","encrypt":0};</script>`,
		`<script>var player_data={"url":"https://vid.dbokutv.com/page.html","encrypt":0};</script>`,
		`<script>var player_data={"url":"https://vid.dbokutv.com/index.m3u8","encrypt":3};</script>`,
		`<script>var sample="https://vid.dbokutv.com/demo.mp4";</script>`,
	} {
		if got := dbkuMediaAddress(body); got != "" {
			t.Fatalf("unexpected address = %q", got)
		}
	}
}
