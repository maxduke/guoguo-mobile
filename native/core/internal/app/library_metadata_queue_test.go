package app

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestPrimarySortFieldsNeedNoAdditionalInterfacesWhenComplete(t *testing.T) {
	hongguo := hongguoDramaFromAny(map[string]any{"series_id": "7615465407347952664", "series_title": "列表剧", "series_cover": coverAddressFixture, "first_visible_time": "1773662280", "hot_score": "20019", "series_play_cnt": "0"}, "测试")
	huangdouRow := map[string]any{"id": "target", "name": "列表剧", "is_vip": false, "issue_date": "2026-03-16", "hot_rate": "20019", "click": 0}
	huangdou := huangdouDramaFromMap(huangdouRow)
	ranking, err := parseHuangdouRanking(map[string]any{"data": map[string]any{"list": []any{huangdouRow}}}, 1)
	if err != nil {
		t.Fatal(err)
	}
	huangguo, ok := dramaFromAIMap(map[string]any{"id": "453", "title": "列表剧", "episode_count": 12, "publish_date": "2026-03-16", "play_count": "0", "created_at": "2026-01-01"}, huangguoAIBaseURL, "测试")
	if !ok {
		t.Fatal("invalid primary list fixture")
	}
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		t.Errorf("complete primary data triggered an optional request: %s", request.URL.Path)
		return rankingHTTPResponse(request, 404, ""), nil
	})
	for _, drama := range []Drama{hongguo, huangdou, ranking.Items[0].Drama, huangguo} {
		if drama.OnlineDate != "2026-03-16" || drama.Views != "0" || !hasCompleteSortMetadata(drama) {
			t.Errorf("primary sort fields were lost: %+v", drama)
		}
		if _, err := d.fetchDramaSortMetadata(context.Background(), drama); err != nil {
			t.Fatal(err)
		}
	}
	creationOnly, _ := dramaFromAIMap(map[string]any{"id": "454", "title": "列表剧", "created_at": "2026-01-01"}, huangguoAIBaseURL, "测试")
	if creationOnly.OnlineDate != "" || hasSortMetric("未知") || hasSortMetric("-1") {
		t.Fatal("creation time or unknown metrics were misclassified as available sorting data")
	}
}

func TestBackgroundRequestsYieldToForeground(t *testing.T) {
	limiter := newRequestLimiter(1, time.Nanosecond)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	request := httptest.NewRequest("GET", "https://hongguoduanju.com/search/test", nil)
	release, err := limiter.acquire(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	background := make(chan func(), 1)
	foreground := make(chan func(), 1)
	go func() {
		unlock, _ := limiter.acquire(context.WithValue(ctx, backgroundCatalogKey{}, true), request)
		background <- unlock
	}()
	go func() {
		unlock, _ := limiter.acquire(ctx, request)
		foreground <- unlock
	}()

	for {
		limiter.mu.Lock()
		waiting := limiter.foregroundWaiting
		limiter.mu.Unlock()
		if waiting > 0 {
			break
		}
		if ctx.Err() != nil {
			t.Fatal("foreground waiter did not register")
		}
		time.Sleep(time.Millisecond)
	}
	release()
	select {
	case unlock := <-foreground:
		if unlock == nil {
			t.Fatal("foreground timed out")
		}
		select {
		case <-background:
			t.Fatal("background ran alongside a waiting foreground request")
		default:
		}
		unlock()
	case <-background:
		t.Fatal("optional metadata overtook foreground work")
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	select {
	case unlock := <-background:
		if unlock == nil {
			t.Fatal("background did not resume")
		}
		unlock()
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}

func TestOptionalDetailPermissionFailureDoesNotBlockForeground(t *testing.T) {
	limiter := newRequestLimiter(1, time.Nanosecond)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	foreground := httptest.NewRequest("GET", "https://hongguoduanju.com/search/test", nil).WithContext(ctx)
	background := foreground.WithContext(context.WithValue(ctx, backgroundCatalogKey{}, true))
	limiter.observe(background, &http.Response{StatusCode: http.StatusForbidden, Header: http.Header{}})
	if release, err := limiter.acquire(background.Context(), background); err == nil {
		release()
		t.Fatal("repeated forbidden details must cool down")
	}
	release, err := limiter.acquire(ctx, foreground)
	if err != nil {
		t.Fatal("an optional detail's permissions blocked public search", err)
	}
	release()
	limiter.observe(background, &http.Response{StatusCode: http.StatusTooManyRequests, Header: http.Header{"Retry-After": {"60"}}})
	if release, err := limiter.acquire(ctx, foreground); err == nil {
		release()
		t.Fatal("site rate limits must still be respected")
	}
}
