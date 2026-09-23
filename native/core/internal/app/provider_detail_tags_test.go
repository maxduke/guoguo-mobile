package app

import (
	"context"
	"net/http"
	"reflect"
	"testing"
)

func TestHuangguoDetailTagsExcludeOtherDramas(t *testing.T) {
	for _, tags := range []string{`<a class="hg-tag" href="/tag/adventure/">冒险<span class="sr-only">题材短剧 · 示例</span></a><a class="hg-tag">都市</a>`, ""} {
		body := `<script type="application/ld+json">{"@type":"TVSeries","url":"https://huangguoai.com/detail/453/","name":"示例"}</script>
  <aside><a class="hg-tag">公共搜索推荐</a></aside>
  <div class="hg-web-detail__tags">` + tags + `</div>
  <div class="hg-web-detail__related"><a class="hg-tag">其他剧标签</a></div>`
		d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) { return rankingHTTPResponse(r, 200, body), nil })
		patch, err := d.fetchDramaMetadata(context.Background(), Drama{ID: "huangguoai:453"})
		if err != nil {
			t.Fatal(err)
		}
		var want []string
		if tags != "" {
			want = []string{"冒险", "都市"}
		}
		if !reflect.DeepEqual(patch.Tags, want) {
			t.Fatalf("tags=%v want=%v", patch.Tags, want)
		}
	}
}
