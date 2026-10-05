package app

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

func TestMobileHuangguoRetriesFailedProviderAndStopsExhaustedProviders(t *testing.T) {
	var failAI atomic.Bool
	var videoCalls atomic.Int32
	var expectedAI atomic.Int32
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		if strings.HasPrefix(r.URL.Path, "/api/videos/category/") {
			if page != int(expectedAI.Load()) {
				t.Errorf("skipped failed AI page: got %d want %d", page, expectedAI.Load())
			}
			if failAI.Load() {
				return rankingHTTPResponse(r, 404, "temporarily unavailable"), nil
			}
			return rankingHTTPResponse(r, 200, fmt.Sprintf(`{"data":{"items":[{"id":"%d","title":"AI剧"}],"pagination":{"page":%d,"pages":3}}}`, page, page)), nil
		}
		if r.URL.Path == "/videos" {
			videoCalls.Add(1)
			if page > 3 {
				t.Error("exhausted video provider was fetched again")
			}
			body := fmt.Sprintf(`<article class="video-card"><a href="/series/%d" title="视频剧">视频剧</a></article>`, page)
			if page < 3 {
				body += fmt.Sprintf(`<a href="/videos?page=%d">下一页</a>`, page+1)
			}
			return rankingHTTPResponse(r, 200, body), nil
		}
		t.Errorf("exhausted legacy provider was fetched: %s", r.URL)
		return rankingHTTPResponse(r, 404, ""), nil
	})
	d.cfg.HuangguoAIURL = "https://ai.example.org"
	d.cfg.HuangguoVideoURL = "https://video.example.org"
	cursors := map[string]mobileHuangguoCursor{"cloudfront": {Next: 2, Done: true}}
	ctx := context.WithValue(context.Background(), providerTextNoCacheKey{}, true)
	for _, step := range []struct {
		page, ai, count int
		failure, more   bool
	}{
		{1, 1, 2, false, true},
		{2, 2, 1, true, true},
		{3, 2, 2, false, true},
		{4, 3, 1, false, false},
		{5, 3, 0, false, false},
	} {
		failAI.Store(step.failure)
		expectedAI.Store(int32(step.ai))
		rows, more, err := d.mobileHuangguoCatalog(ctx, step.page, cursors)
		if len(rows) != step.count || more != step.more || (err != nil) != step.failure {
			t.Fatalf("step %d: rows=%d more=%t err=%v", step.page, len(rows), more, err)
		}
		if step.failure {
			if cursors[sourceHuangguoAI].Next != 2 {
				t.Fatal("failed source advanced")
			}
			// A restart must preserve the lagging source, not replace its next
			// page with Flutter's aggregate page number.
			directory := t.TempDir()
			if err := writeLibraryCache(directory, libraryCache{Huangguo: cursors}); err != nil {
				t.Fatal(err)
			}
			restored, err := NewMobileClient(directory)
			if err != nil {
				t.Fatal(err)
			}
			cursors = restored.huangguo
			restored.Close()
		}
	}
	if videoCalls.Load() != 3 {
		t.Fatalf("video calls=%d", videoCalls.Load())
	}
}
