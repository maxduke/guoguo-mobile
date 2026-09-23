package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const hongguoSuggestionFixture = `{"suggest_list":[
{"name":"永冬之下，冻土之上","keyword":"7679734241927646270","word_type":"short_play_name","video_data":{"series_id":7679734241927646270}},
{"name":"永夜苟神：十万住户供我发育","word_type":"short_play_name","video_data":{}},
{"name":"永世长青","word_type":"short_play_name"},
{"name":"永恒道宫","word_type":"common_query"},
{"name":"永夜苟神：十万住户供我发育（第二季）","word_type":"short_play_name"},
{"name":"永冬求生：我为龙国捕猎百亿资源","word_type":"short_play_name"},
{"name":"永恒罐子","word_type":"common_query"},
{"name":"永乐种田","word_type":"short_play_name"}
]}`

func TestHongguoSuggestionsPreserveNamesWithoutFetchingDramaMetadata(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		q := r.URL.Query()
		if r.Method != http.MethodGet || r.URL.Host != "hongguoduanju.com" || r.URL.Path != "/incent_resource/suggestion" || q.Get("app_id") != "8662" || q.Get("count") != "10" || q.Get("query") != "永&夜" {
			t.Errorf("unexpected suggestion request: %s", r.URL)
		}
		return rankingHTTPResponse(r, 200, hongguoSuggestionFixture), nil
	})
	c := &MobileClient{downloader: d}
	raw, err := c.Call(`{"method":"suggestions","source":"hongguo","query":" 永&夜 "}`)
	var response struct {
		Items []hongguoSearchSuggestion `json:"items"`
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(raw), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Items) != 8 || response.Items[1].Name != "永夜苟神：十万住户供我发育" {
		t.Fatal(response)
	}
	if calls.Load() != 1 || strings.Contains(raw, "video_data") {
		t.Fatal("typing fetched full metadata")
	}

}

func TestHongguoSuggestionValidationAndLimit(t *testing.T) {
	rows := []map[string]string{{"name": " "}, {"name": "a\nb"}, {"name": strings.Repeat("永", 81)}, {"name": " 永世长青 "}, {"name": "永世长青"}}
	for i := 0; i < 20; i++ {
		rows = append(rows, map[string]string{"name": fmt.Sprintf("永夜%d", i)})
	}
	body, _ := json.Marshal(map[string]any{"suggest_list": rows})
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) { return rankingHTTPResponse(r, 200, string(body)), nil })
	items, err := d.hongguoSearchSuggestions(context.Background(), "永")
	if err != nil || len(items) != 10 || items[0].Name != "永世长青" || items[1].Name != "永夜0" {
		t.Fatal("suggestions must be bounded, trimmed and deduplicated", items, err)
	}
}

func TestHongguoSuggestionsRejectInvalidResponses(t *testing.T) {
	for _, body := range []string{`{}`, `{"suggest_list":null}`, `{"suggest_list":"bad"}`, `{"suggest_list":[{"name":9}]}`, `<html>invalid</html>`, strings.Repeat("x", hongguoSuggestionBodyLimit+1)} {
		d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) { return rankingHTTPResponse(r, 200, body), nil })
		if _, err := d.hongguoSearchSuggestions(context.Background(), "永"); err == nil {
			t.Fatal("invalid upstream response was accepted")
		}
		if len(d.hongguoClient().suggestions) != 0 {
			t.Fatal("failed response was cached as a valid empty result")
		}
	}
}

func TestHongguoSuggestionCacheAndExpiry(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return rankingHTTPResponse(r, 200, hongguoSuggestionFixture), nil
	})
	first, _ := d.hongguoSearchSuggestions(context.Background(), "永")
	first[0].Name = "调用者改动"
	second, _ := d.hongguoSearchSuggestions(context.Background(), " 永 ")
	if calls.Load() != 1 || second[0].Name == first[0].Name {
		t.Fatal("cache must reuse upstream results without sharing mutable slices")
	}
	client := d.hongguoClient()
	client.mu.Lock()
	client.suggestions["永"] = hongguoSuggestionEntry{Items: second, ExpiresAt: time.Now().Add(-time.Second)}
	for i := 0; i < hongguoSuggestionCacheLimit; i++ {
		client.suggestions[fmt.Sprint(i)] = hongguoSuggestionEntry{Items: second, ExpiresAt: time.Now().Add(time.Minute)}
	}
	client.mu.Unlock()
	if _, err := d.hongguoSearchSuggestions(context.Background(), "永"); err != nil || calls.Load() != 2 || len(client.suggestions) != hongguoSuggestionCacheLimit {
		t.Fatal("expired cache must refetch without growing the cache", err, calls.Load(), len(client.suggestions))
	}
}

func TestHongguoSuggestionConcurrentRequestsShareFetch(t *testing.T) {
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(started)
		}
		<-release
		return rankingHTTPResponse(r, 200, hongguoSuggestionFixture), nil
	})
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if items, err := d.hongguoSearchSuggestions(context.Background(), "永"); err != nil || len(items) != 8 {
				t.Error("concurrent suggestion request failed", err)
			}
		}()
	}
	<-started
	close(release)
	group.Wait()
	if calls.Load() != 1 {
		t.Fatal("identical queries were sent more than once", calls.Load())
	}
}

func TestHongguoSuggestionCanceledOwnerDoesNotStrandAnotherBrowser(t *testing.T) {
	var calls atomic.Int32
	started := make(chan struct{})
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(started)
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		return rankingHTTPResponse(r, 200, hongguoSuggestionFixture), nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	owner := make(chan error, 1)
	go func() { _, err := d.hongguoSearchSuggestions(ctx, "永"); owner <- err }()
	<-started
	waiter := make(chan error, 1)
	go func() {
		items, err := d.hongguoSearchSuggestions(context.Background(), "永")
		if err == nil && len(items) != 8 {
			err = fmt.Errorf("expected 8 suggestions, got %d", len(items))
		}
		waiter <- err
	}()
	cancel()
	if err := <-owner; !errors.Is(err, context.Canceled) {
		t.Fatal("canceled query did not stop", err)
	}
	if err := <-waiter; err != nil || calls.Load() != 2 {
		t.Fatal("another browser inherited the owner's canceled request", err, calls.Load())
	}
}

func TestMobileSuggestionsInputAndSourceChecks(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return rankingHTTPResponse(r, 200, `{"suggest_list":[]}`), nil
	})
	c := &MobileClient{downloader: d}
	for _, query := range []string{"", "a\nb", strings.Repeat("永", 81)} {
		request, _ := json.Marshal(map[string]string{"method": "suggestions", "source": "hongguo", "query": query})
		if _, err := c.Call(string(request)); err == nil {
			t.Fatal("invalid input accepted")
		}
	}
	if _, err := c.Call(`{"method":"suggestions","source":"huangdou","query":"永"}`); err == nil {
		t.Fatal("invalid source accepted")
	}
	if calls.Load() != 0 {
		t.Fatal("invalid input reached upstream")
	}
}

func TestLiveHongguoSearchSuggestions(t *testing.T) {
	if os.Getenv("JUKU_LIVE_SUGGESTIONS") != "1" {
		t.Skip("set JUKU_LIVE_SUGGESTIONS=1 for one public suggestion request")
	}
	cfg := defaultConfig()
	cfg.dataDir, cfg.OutputDir, cfg.Retries = t.TempDir(), t.TempDir(), 1
	items, err := NewDownloader(cfg).hongguoSearchSuggestions(context.Background(), "永")
	if err != nil || len(items) == 0 || len(items) > 10 {
		t.Fatal("live suggestions unavailable", len(items), err)
	}
	t.Logf("public Hongguo suggestions: %d names", len(items))
}
