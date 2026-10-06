package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"testing"
	"time"
)

func TestUnifiedUpdateChecksNewContentAndContinuesCatalog(t *testing.T) {
	for _, test := range []struct {
		name          string
		pages         int
		savedOffset   int
		savedEnd      bool
		knownOffsets  []int
		endAt         int
		wantOffsets   []int
		wantSaved     int
		wantEnd       bool
		resumeSession bool
	}{
		{name: "first import runs one batch", pages: 2, endAt: -1, wantOffsets: []int{0, 18}, wantSaved: 36},
		{name: "known head resumes saved tail", pages: 2, savedOffset: 90, knownOffsets: []int{0}, endAt: -1, wantOffsets: []int{0, 90, 108}, wantSaved: 126, resumeSession: true},
		{name: "new head stops at overlap", pages: 4, savedOffset: 90, knownOffsets: []int{18}, endAt: -1, wantOffsets: []int{0, 18, 90, 108, 126, 144}, wantSaved: 162, resumeSession: true},
		{name: "large update continues next unread page", pages: 4, savedOffset: 180, endAt: -1, wantOffsets: []int{0, 18, 36, 54, 72, 90, 108}, wantSaved: 126},
		{name: "exhausted catalog still checks new content", pages: 4, savedOffset: 180, savedEnd: true, knownOffsets: []int{18}, endAt: -1, wantOffsets: []int{0, 18}, wantSaved: 180, wantEnd: true},
		{name: "continuation reaches end", pages: 2, savedOffset: 90, knownOffsets: []int{0}, endAt: 90, wantOffsets: []int{0, 90}, wantSaved: 108, wantEnd: true, resumeSession: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			calls := map[string][]int{}
			var known []Drama
			for index := range hongguoAppGenres {
				for _, offset := range test.knownOffsets {
					known = append(known, Drama{ID: fmt.Sprintf("hongguo:%d", 790000+index*1000+offset), Source: sourceHongguo})
				}
			}
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				var payload struct {
					Offset  int    `json:"offset"`
					Session string `json:"session_id"`
					Select  struct {
						Genre []string `json:"genre"`
					} `json:"select_items"`
				}
				if request.URL.Path != "/reading/distribution/category/landpage/v/" || json.NewDecoder(request.Body).Decode(&payload) != nil || len(payload.Select.Genre) != 1 {
					t.Errorf("unexpected catalog request: %s", request.URL.Path)
					return rankingHTTPResponse(request, 400, ""), nil
				}
				genre := payload.Select.Genre[0]
				index := -1
				for position, candidate := range hongguoAppGenres {
					if candidate.key == genre {
						index = position
					}
				}
				if index < 0 {
					t.Errorf("unexpected genre: %s", genre)
					return rankingHTTPResponse(request, 400, ""), nil
				}
				calls[genre] = append(calls[genre], payload.Offset)
				if payload.Offset == 0 && payload.Session != "" {
					t.Error("head check reused a tail session")
				}
				if test.resumeSession && payload.Offset == test.savedOffset && payload.Session != "saved-"+genre {
					t.Error("continuation lost its saved session")
				}
				body, _ := json.Marshal(map[string]any{"data": map[string]any{
					"next_offset": payload.Offset + 18, "session_id": "fixture-" + genre, "has_more": payload.Offset != test.endAt,
					"video_data": []any{map[string]any{
						"series_id": fmt.Sprint(790000 + index*1000 + payload.Offset), "series_title": "文字目录样本",
						"first_visible_time": "1773662280", "hot_score": "20", "series_play_cnt": "0",
					}},
				}})
				return rankingHTTPResponse(request, 200, string(body)), nil
			})
			d.cfg.MaxPagesPerSort = test.pages
			if test.savedOffset > 0 {
				client := d.hongguoClient()
				for _, genre := range hongguoAppGenres {
					client.state.Feeds[genre.key] = hongguoCatalogCursor{
						Offset: test.savedOffset, SessionID: "saved-" + genre.key, Initialized: true, Exhausted: test.savedEnd, UpdatedAt: time.Now(),
					}
				}
			}
			ctx := withKnownHongguoDramas(context.WithValue(context.Background(), libraryUpdateKey{}, true), known)
			items, err := d.fetchHongguoAppCatalog(ctx)
			if err != nil || len(items) != len(test.wantOffsets)*len(hongguoAppGenres) {
				t.Fatalf("catalog result: %d items, %v", len(items), err)
			}
			for _, genre := range hongguoAppGenres {
				if !reflect.DeepEqual(calls[genre.key], test.wantOffsets) {
					t.Errorf("%s requested %v, want %v", genre.key, calls[genre.key], test.wantOffsets)
				}
				cursor := d.hongguoCatalogSnapshot().Feeds[genre.key]
				if !cursor.Initialized || cursor.Offset != test.wantSaved || cursor.Exhausted != test.wantEnd {
					t.Errorf("wrong checkpoint for %s: %+v", genre.key, cursor)
				}
			}
		})
	}
}

func TestUnifiedUpdatePreservesHistoryAcrossRestart(t *testing.T) {
	calls := map[string][]int{}
	transport := func(request *http.Request) (*http.Response, error) {
		var payload struct {
			Offset int    `json:"offset"`
			Scene  string `json:"req_scene"`
		}
		if request.URL.Path != "/reading/distribution/category/landpage/v/" || json.NewDecoder(request.Body).Decode(&payload) != nil {
			t.Errorf("unexpected request: %s", request.URL.Path)
			return rankingHTTPResponse(request, 400, ""), nil
		}
		calls[payload.Scene] = append(calls[payload.Scene], payload.Offset)
		index := 0
		for position, genre := range hongguoAppGenres {
			if genre.scene == payload.Scene {
				index = position
			}
		}
		body := fmt.Sprintf(`{"data":{"next_offset":%d,"has_more":%t,"session_id":"saved-session","video_data":[{"series_id":"%d","series_title":"文字样本","first_visible_time":"1773662280","hot_score":"20","series_play_cnt":"0"}]}}`, payload.Offset+18, payload.Offset == 0, 790000+index*1000+payload.Offset)
		return rankingHTTPResponse(request, 200, body), nil
	}
	directory := t.TempDir()
	for run, wantCount := range []int{3, 6, 6} {
		d := rankingTestDownloader(t, transport)
		d.cfg.dataDir, d.cfg.MaxPagesPerSort = directory, 1
		items, err := d.RefreshDramas(context.WithValue(context.Background(), libraryUpdateKey{}, true), sourceHongguo)
		if err != nil || len(items) != wantCount {
			t.Fatalf("run %d lost history: %d items, %v", run, len(items), err)
		}
		cache, err := readLibraryCache(directory)
		if err != nil || len(cache.Dramas) != wantCount || hongguoCatalogHasMore(cache.HongguoApp) != (run == 0) {
			t.Fatalf("run %d did not persist data and cursor together: %v", run, err)
		}
		for _, drama := range cache.Dramas {
			if drama.OnlineDate != "2026-03-16" || drama.Heat != "20" || drama.Views != "0" {
				t.Fatal("update lost available sorting fields")
			}
		}
	}
	for scene, offsets := range calls {
		if !reflect.DeepEqual(offsets, []int{0, 0, 18, 0}) {
			t.Errorf("%s skipped or repeated a continuation: %v", scene, offsets)
		}
	}
}
