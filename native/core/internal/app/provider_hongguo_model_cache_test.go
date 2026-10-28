package app

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestHongguoCachedModelPreservesCENCAndCancellation(t *testing.T) {
	for _, encoded := range []bool{false, true} {
		calls := 0
		d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
			calls++
			var model any = hongguoVideoModelFixture()
			if encoded {
				body, _ := json.Marshal(model)
				model = string(body)
			}
			body, _ := json.Marshal(map[string]any{"data": map[string]any{"800001": map[string]any{"video_model": model}, "800002": map[string]any{"video_model": model}}})
			return rankingHTTPResponse(request, http.StatusOK, string(body)), nil
		})
		if _, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002"); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, err := d.resolveHongguoAppMedia(ctx, "800002"); err != context.Canceled {
			t.Fatal("canceled caller used model cache", err)
		}
		media, err := d.resolveHongguoAppMedia(context.Background(), "800002")
		if err != nil {
			t.Fatal(err)
		}
		if calls != 1 || media.Quality != 1080 || media.Duration != 93554*time.Millisecond || hex.EncodeToString(media.CENCKey) != "00112233445566778899aabbccddeeff" || len(media.Variants) != 2 {
			t.Fatal("cached model lost media or was consumed by a canceled caller")
		}
	}
}

func TestHongguoLookaheadRequiresFreshMatchingDetail(t *testing.T) {
	for _, expiry := range []time.Time{time.Time{}, time.Now().Add(-time.Second), time.Now().Add(time.Minute)} {
		d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
			t.Fatal("lookahead must not fetch detail")
			return nil, nil
		})
		d.hongguoClient().details["700001"] = hongguoDetailEntry{ExpiresAt: expiry, Chapters: []Chapter{{VideoURL: "hongguo-cenc://800001"}, {VideoURL: "hongguo-cenc://800002"}}}
		ctx := context.WithValue(context.Background(), hongguoMetadataAheadKey{}, 2)
		if got := d.hongguoUpcomingVideoIDs(ctx, "700002", "800001"); len(got) != 0 {
			t.Fatal("borrowed another series detail")
		}
		if got := d.hongguoUpcomingVideoIDs(ctx, "700001", "800099"); len(got) != 0 {
			t.Fatal("unmatched current episode gained lookahead")
		}
		got := d.hongguoUpcomingVideoIDs(ctx, "700001", "800001")
		if time.Now().Before(expiry) && !reflect.DeepEqual(got, []string{"800002"}) || !time.Now().Before(expiry) && len(got) != 0 {
			t.Fatal("lookahead used stale or wrong detail", got)
		}
	}
}

func hongguoModelBatchFixture(ids ...string) string {
	data := map[string]any{}
	for _, id := range ids {
		data[id] = map[string]any{"video_model": map[string]any{"video_list": []any{
			map[string]any{"main_url": "https://media.example.test/" + id + ".mp4", "video_meta": map[string]any{"codec_type": "h264", "definition": "720p"}},
		}}}
	}
	body, _ := json.Marshal(map[string]any{"code": 0, "data": data})
	return string(body)
}

func TestHongguoBatchFailureFallsBackWithinExistingBudget(t *testing.T) {
	for _, failure := range []struct {
		status int
		body   string
	}{
		{http.StatusServiceUnavailable, ""},
		{http.StatusOK, ""},
		{http.StatusOK, `{"code":110001}`},
		{http.StatusOK, `{"data":{"800002":{"video_model":{}}}}`},
	} {
		var requests [][]string
		var identity string
		d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
			var payload struct {
				IDs map[string][]string `json:"mixed_video_id_map"`
			}
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			requests = append(requests, payload.IDs["1004"])
			if len(requests) == 1 {
				identity = request.URL.Query().Get("device_id")
				return rankingHTTPResponse(request, failure.status, failure.body), nil
			}
			if request.URL.Query().Get("device_id") != identity {
				t.Fatal("single fallback rotated the device")
			}
			return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001")), nil
		})
		d.cfg.Retries = 2
		media, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002", "800003")
		if err != nil || media.URL != "https://media.example.test/800001.mp4" {
			t.Fatal("batch failure broke current episode", err)
		}
		if !reflect.DeepEqual(requests, [][]string{{"800001", "800002", "800003"}, {"800001"}}) {
			t.Fatal("fallback exceeded the budget or retried lookahead", requests)
		}
		if len(d.hongguoClient().upcomingModels) != 0 {
			t.Fatal("failed batch warmed another episode")
		}
	}
}

func TestHongguoBatchFailureAndCancelDoNotExpandRetries(t *testing.T) {
	for _, cancelFirst := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		calls := 0
		d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
			calls++
			if cancelFirst {
				cancel()
			}
			return rankingHTTPResponse(request, http.StatusServiceUnavailable, ""), nil
		})
		d.cfg.Retries = 2
		if _, err := d.resolveHongguoAppMedia(ctx, "800001", "800002"); err == nil || cancelFirst && !errors.Is(err, context.Canceled) {
			t.Fatal("accepted failed model response")
		}
		want := 2
		if cancelFirst {
			want = 1
		}
		if calls != want {
			t.Fatal("retry/cancellation budget changed", calls, want)
		}
		cancel()
	}
}

func TestHongguoBatchDoesNotRetryDeviceRegistrationFailure(t *testing.T) {
	registrations, models := 0, 0
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
		} else {
			models++
		}
		return rankingHTTPResponse(request, http.StatusBadGateway, ""), nil
	})
	d.cfg.Retries = 2
	_, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002")
	if !errors.Is(err, errHongguoDeviceRegistration) || registrations != 1 || models != 0 {
		t.Fatal("model fallback retried registration", registrations, models, err)
	}
}

func TestHongguoMobileLookaheadBatchesOnlyValidatedUpcomingEpisodes(t *testing.T) {
	var requests [][]string
	d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
		var payload struct {
			IDs map[string][]string `json:"mixed_video_id_map"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		ids := payload.IDs["1004"]
		requests = append(requests, ids)
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture(ids...)), nil
	})
	d.hongguoClient().details["700001"] = hongguoDetailEntry{
		ExpiresAt: time.Now().Add(time.Minute),
		Chapters: []Chapter{
			{ID: "one", VideoURL: "hongguo-cenc://800001"},
			{ID: "two", VideoURL: "hongguo-cenc://800002"},
			{ID: "three", VideoURL: "hongguo-cenc://800003"},
			{ID: "four", VideoURL: "hongguo-cenc://800004"},
		},
	}
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	c.downloader = d
	defer c.Close()
	for index := 1; index <= 3; index++ {
		request := fmt.Sprintf(`{"method":"resolve","id":"hongguo:700001","chapter":{"id":"selected","videoUrl":"hongguo-cenc://80000%d"},"metadataAhead":%d}`, index, 2*(index%2))
		value, err := c.Call(request)
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		if err := json.Unmarshal([]byte(value), &result); err != nil {
			t.Fatal(err)
		}
		if result["remoteUrl"] != fmt.Sprintf("https://media.example.test/80000%d.mp4", index) {
			t.Fatal("lookahead selected another episode")
		}
	}
	if !reflect.DeepEqual(requests, [][]string{{"800001", "800002", "800003"}}) {
		t.Fatalf("three selections should use one bounded model request: %v", requests)
	}
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800002"); err != nil {
		t.Fatal(err)
	}
	if len(requests) != 2 || !reflect.DeepEqual(requests[1], []string{"800002"}) {
		t.Fatal("retry reused a consumed model", requests)
	}
}

func TestHongguoLookaheadLeavesSingleEpisodeRequestsUnchanged(t *testing.T) {
	var requested []string
	d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
		var payload struct {
			IDs map[string][]string `json:"mixed_video_id_map"`
		}
		json.NewDecoder(request.Body).Decode(&payload)
		requested = payload.IDs["1004"]
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture(requested...)), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(requested, []string{"800001"}) {
		t.Fatal("ordinary resolve fetched unrequested episodes")
	}
	for _, count := range []int{-1, 3} {
		c, err := NewMobileClient(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		c.downloader = d
		_, err = c.Call(fmt.Sprintf(`{"method":"resolve","id":"hongguo:700001","chapter":{"id":"selected","videoUrl":"hongguo-cenc://800001"},"metadataAhead":%d}`, count))
		c.Close()
		if err == nil {
			t.Fatal("accepted an invalid metadata lookahead")
		}
	}
}

func TestHongguoModelCacheExpiresAndDoesNotAcceptOtherEpisodes(t *testing.T) {
	calls := 0
	d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001", "800002", "800099")), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002"); err != nil {
		t.Fatal(err)
	}
	client := d.hongguoClient()
	if len(client.upcomingModels) != 1 {
		t.Fatal("cached an unrequested episode")
	}
	entry := client.upcomingModels["800002"]
	entry.expiresAt = time.Now().Add(-time.Second)
	client.upcomingModels["800002"] = entry
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800002"); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatal("expired model did not cause a fresh request")
	}
}

func TestHongguoModelCacheRejectsInvalidAndOversizedModels(t *testing.T) {
	for _, model := range []any{map[string]any{"video_list": []any{}}, strings.Repeat(" ", hongguoModelMaxBytes+1)} {
		d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
			var data map[string]any
			json.Unmarshal([]byte(hongguoModelBatchFixture("800001")), &data)
			data["data"].(map[string]any)["800002"] = map[string]any{"video_model": model}
			body, _ := json.Marshal(data)
			return rankingHTTPResponse(request, http.StatusOK, string(body)), nil
		})
		if _, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002"); err != nil {
			t.Fatal(err)
		}
		if len(d.hongguoClient().upcomingModels) != 0 {
			t.Fatal("cached an invalid or oversized model")
		}
	}
}

func TestHongguoModelCacheIsBoundedAndMissingCurrentDoesNotWarm(t *testing.T) {
	d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
		var payload struct {
			IDs map[string][]string `json:"mixed_video_id_map"`
		}
		json.NewDecoder(request.Body).Decode(&payload)
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture(payload.IDs["1004"]...)), nil
	})
	for index := 0; index < 8; index++ {
		current, next := fmt.Sprint(800000+index*10), fmt.Sprint(800001+index*10)
		if _, err := d.resolveHongguoAppMedia(context.Background(), current, next); err != nil {
			t.Fatal(err)
		}
	}
	if len(d.hongguoClient().upcomingModels) != hongguoModelCacheLimit {
		t.Fatal("model cache exceeded its bound")
	}
	d = hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800002")), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002"); err == nil {
		t.Fatal("accepted another episode")
	}
	if len(d.hongguoClient().upcomingModels) != 0 {
		t.Fatal("missing current model warmed speculative entries")
	}
}
