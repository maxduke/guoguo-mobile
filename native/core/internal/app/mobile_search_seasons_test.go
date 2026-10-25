package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func callMobileSeasonPage(t *testing.T, c *MobileClient, query string, page int, continuation string) map[string]any {
	t.Helper()
	request := mobileRequest{Method: "search", Source: sourceHongguo, Query: query, Page: page, Continuation: continuation}
	raw, _ := json.Marshal(request)
	response, err := c.Call(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal([]byte(response), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestMobileSeasonPaginationCompletesGapsWithoutDelayingFirstPage(t *testing.T) {
	fixtures := hongguoManySeasonFixtures()
	var queries []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		query := r.URL.Query().Get("query")
		queries = append(queries, query)
		body := fixtures[query]
		if r.URL.Path == "/api/search/result" {
			body = fixtures["page"]
			if r.URL.Query().Get("page") != "1" {
				body = fmt.Sprintf(`{"pageNum":%s,"hasMore":false,"totalCount":233,"searchList":[]}`, r.URL.Query().Get("page"))
			}
		}
		if body == "" {
			body = `{"suggest_list":[]}`
		}
		return rankingHTTPResponse(r, 200, body), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	result := callMobileSeasonPage(t, c, hongguoManySeasonQuery, 1, "")
	if len(queries) != 2 || result["hasMore"] != true || result["continuation"] == "" {
		t.Fatal("first page waited for probes or lost its continuation", queries, result)
	}
	first := result["continuation"].(string)
	initial := c.seasonCursors[first].clone()
	other := callMobileSeasonPage(t, c, hongguoManySeasonQuery, 1, "")
	if len(queries) != 2 || other["continuation"] == first {
		t.Fatal("same-query owners failed to share base results or shared a mutable cursor")
	}
	var firstBatch map[string]any
	var firstQueries []string
	for page := 2; result["hasMore"] == true; page++ {
		if page > 10 {
			t.Fatal("continuation failed to stop")
		}
		before := len(queries)
		result = callMobileSeasonPage(t, c, hongguoManySeasonQuery, page, result["continuation"].(string))
		if page == 2 {
			firstBatch = result
			firstQueries = append([]string(nil), queries[before:]...)
		}
		if len(queries)-before > mobileSeasonPageQueries {
			t.Fatal("page exceeded the probe budget", len(queries)-before)
		}
	}
	if len(result["items"].([]any)) != 35 || result["warning"] != "" || result["limited"] != true {
		t.Fatal("lost verified seasons or treated the website estimate as a complete result", result)
	}
	if !reflect.DeepEqual(c.seasonCursors[first], initial) {
		t.Fatal("published cursor was mutated")
	}
	before := len(queries)
	replayed := callMobileSeasonPage(t, c, hongguoManySeasonQuery, 2, first)
	if !reflect.DeepEqual(queries[before:], firstQueries) || !reflect.DeepEqual(replayed["items"], firstBatch["items"]) {
		t.Fatal("replaying the first cursor advanced a shared keyword cursor")
	}
}

func seasonTestCursor(t *testing.T, c *MobileClient, maximum int) string {
	t.Helper()
	series := &hongguoSearchSeries{title: "修仙", key: "修仙", unit: "季", maximum: maximum, known: map[int]bool{1: true, maximum: true}, labels: map[int]string{maximum: hongguoSearchChineseSeason(maximum)}}
	cursor := &mobileSeasonCursor{query: "修仙", page: 1, entry: hongguoSearchEntry{Dramas: []Drama{{ID: "hongguo:1", Title: "修仙"}, {ID: "hongguo:last", Title: "修仙第" + hongguoSearchChineseSeason(maximum) + "季"}}}, groups: []mobileSeasonGroup{{series: series, nextSeason: maximum + 1}}, attempted: map[string]bool{"修仙": true}}
	token, err := c.rememberSeasonCursor(context.Background(), cursor)
	if err != nil || token == "" {
		t.Fatal("could not save test cursor", err)
	}
	return token
}

func TestMobileSeasonEmptyBatchDoesNotHideLaterKnownGap(t *testing.T) {
	var queries []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		query := r.URL.Query().Get("query")
		queries = append(queries, query)
		body := `{"suggest_list":[]}`
		if query == "修仙第六季" {
			body = `{"suggest_list":[{"word_type":"short_play_name","name":"修仙第六季","video_data":{"series_id":"7300000000000000006","episode_cnt":20}}]}`
		}
		return rankingHTTPResponse(r, 200, body), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	result := callMobileSeasonPage(t, c, "修仙", 2, seasonTestCursor(t, c, 7))
	if len(result["items"].([]any)) != 2 || result["hasMore"] != true {
		t.Fatal("empty batch incorrectly ended continuation", result)
	}
	for page := 3; result["hasMore"] == true; page++ {
		result = callMobileSeasonPage(t, c, "修仙", page, result["continuation"].(string))
	}
	if len(result["items"].([]any)) != 3 || result["limited"] != true || len(queries) > mobileSeasonQueryLimit {
		t.Fatal("later season was hidden or missing seasons reported complete", result, queries)
	}
}

func TestMobileSeasonFailedProbeIsRetriedAndSuccessfulBatchSurvives(t *testing.T) {
	fail := true
	var queries []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		query := r.URL.Query().Get("query")
		queries = append(queries, query)
		if query == "修仙第三季" && fail {
			return rankingHTTPResponse(r, 200, `{}`), nil
		}
		body := `{"suggest_list":[]}`
		if query == "修仙第二季" {
			body = `{"suggest_list":[{"word_type":"short_play_name","name":"修仙第二季","video_data":{"series_id":"7300000000000000002","episode_cnt":10}}]}`
		}
		return rankingHTTPResponse(r, 200, body), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	result := callMobileSeasonPage(t, c, "修仙", 2, seasonTestCursor(t, c, 4))
	if len(result["items"].([]any)) != 3 || result["warning"] == "" || result["hasMore"] != true {
		t.Fatal("successful batches were discarded after a failed probe", result)
	}
	fail = false
	before := len(queries)
	callMobileSeasonPage(t, c, "修仙", 3, result["continuation"].(string))
	if queries[before] != "修仙第三季" {
		t.Fatal("failed probe was consumed", queries)
	}
}

func TestMobileSeasonCancellationDoesNotAdvanceAnotherOwner(t *testing.T) {
	type ownerKey struct{}
	started := make(chan struct{})
	var once sync.Once
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.Context().Value(ownerKey{}) == true {
			once.Do(func() { close(started) })
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		return rankingHTTPResponse(r, 200, `{"suggest_list":[]}`), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	token := seasonTestCursor(t, c, 3)
	ctx, cancel := context.WithCancel(context.WithValue(context.Background(), ownerKey{}, true))
	defer cancel()
	failed := make(chan error, 1)
	request := mobileRequest{Source: sourceHongguo, Query: "修仙", Page: 2, Continuation: token}
	go func() { _, err := c.searchHongguoPage(ctx, request, nil); failed <- err }()
	<-started
	second := make(chan error, 1)
	go func() {
		result, err := c.searchHongguoPage(context.Background(), request, nil)
		if err == nil && result["hasMore"] != true {
			err = errors.New("second owner lost its continuation")
		}
		second <- err
	}()
	cancel()
	if err := <-failed; !errors.Is(err, context.Canceled) {
		t.Fatal("canceled owner did not stop", err)
	}
	if err := <-second; err != nil {
		t.Fatal("second owner inherited cancellation", err)
	}
	if c.seasonCursors[token].requests != 0 || len(c.seasonCursors) != 2 {
		t.Fatal("cancellation consumed or published a cursor", len(c.seasonCursors))
	}
}

func TestMobileSeasonCursorIdentityExpiryAndBounds(t *testing.T) {
	c := &MobileClient{downloader: rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		t.Fatal("invalid cursor reached upstream", r.URL)
		return nil, nil
	})}
	token := seasonTestCursor(t, c, 3)
	for _, request := range []mobileRequest{
		{Query: "修仙", Page: 2},
		{Query: "另一部", Page: 2, Continuation: token},
		{Query: "修仙", Page: 3, Continuation: token},
	} {
		result, err := c.searchHongguoPage(context.Background(), request, nil)
		if err != nil || result["restartRequired"] != true || result["limited"] != true {
			t.Fatal("invalid cursor did not request a clean restart", err, result)
		}
	}
	c.seasonCursors[token].expires = time.Now().Add(-time.Second)
	if result := callMobileSeasonPage(t, c, "修仙", 2, token); result["restartRequired"] != true {
		t.Fatal("expired cursor reused", result)
	}
	for index := 0; index < mobileSeasonCursorLimit+3; index++ {
		seasonTestCursor(t, c, 3)
	}
	if len(c.seasonCursors) != mobileSeasonCursorLimit {
		t.Fatal("cursor retention was unbounded", len(c.seasonCursors))
	}
	cursor := &mobileSeasonCursor{entry: hongguoSearchEntry{Warning: strings.Repeat("x", mobileSeasonCursorBytes)}}
	if token, err := c.rememberSeasonCursor(context.Background(), cursor); err != nil || token != "" {
		t.Fatal("oversized cursor retained", token, err)
	}
	c.Close()
	if len(c.seasonCursors) != 0 {
		t.Fatal("closed core retained continuation state")
	}
}

func TestMobileSeasonQueryBudgetCannotCreateACompleteBaseline(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(r, 200, `{"suggest_list":[]}`), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	token := seasonTestCursor(t, c, 200)
	result := callMobileSeasonPage(t, c, "修仙", 2, token)
	for page := 3; result["hasMore"] == true; page++ {
		if page > 10 {
			t.Fatal("query budget did not stop pagination")
		}
		token = result["continuation"].(string)
		result = callMobileSeasonPage(t, c, "修仙", page, token)
	}
	if result["limited"] != true || result["warning"] == "" || len(result["items"].([]any)) != 2 {
		t.Fatal("budget exhaustion was treated as a complete seasonal result", fmt.Sprint(result))
	}
}

func TestMobileSeasonExtensionChecksBothNumberStyles(t *testing.T) {
	var queries []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		query := r.URL.Query().Get("query")
		queries = append(queries, query)
		body := `{"suggest_list":[]}`
		if query == "修仙第3季" {
			body = `{"suggest_list":[{"word_type":"short_play_name","name":"修仙第3季","video_data":{"series_id":"7300000000000000003","episode_cnt":20}}]}`
		}
		return rankingHTTPResponse(r, 200, body), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	result := callMobileSeasonPage(t, c, "修仙", 2, seasonTestCursor(t, c, 2))
	for page := 3; result["hasMore"] == true; page++ {
		if page > 4 {
			t.Fatal("extension did not stop after two absent seasons")
		}
		result = callMobileSeasonPage(t, c, "修仙", page, result["continuation"].(string))
	}
	if len(result["items"].([]any)) != 3 || result["limited"] != false || !reflect.DeepEqual(queries, []string{"修仙第三季", "修仙第3季", "修仙第4季", "修仙第四季", "修仙第5季", "修仙第五季"}) {
		t.Fatal("number-style fallback or extension miss count was incorrect", queries, result)
	}
}
