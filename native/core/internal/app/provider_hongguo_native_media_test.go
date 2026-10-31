package app

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func hongguoVideoModelFixture() map[string]any {
	// Synthetic spade_a for the AES key 00112233445566778899aabbccddeeff.
	encryption := map[string]any{
		"encrypt": true, "encryption_method": "cenc-aes-ctr",
		"spade_a": "mr8T+Vu+EvdZvhL1X7kR90G6DvVfpSbcXaUm3luiJdyloGR1dVpzNA==",
	}
	return map[string]any{
		"video_duration": "93.554",
		"video_list": []any{
			map[string]any{"main_url": "https://media.example.test/vvc.mp4", "video_meta": map[string]any{"codec_type": "bytevc2", "definition": "2160p"}},
			map[string]any{"main_url": "https://media.example.test/high.mp4", "encrypt_info": encryption, "video_meta": map[string]any{"codec_type": "bytevc1", "definition": "1080p"}},
			map[string]any{"main_url": "https://media.example.test/low.mp4", "encrypt_info": encryption, "video_meta": map[string]any{"codec_type": "h264", "definition": "720p"}},
		},
	}
}

func TestHongguoAppMediaRejectsByteVC2Aliases(t *testing.T) {
	for _, label := range []string{"bytevc2", "BYTEVC2", "bvc2", "BVC2"} {
		for _, field := range []string{"codec", "gear"} {
			t.Run(label+"/"+field, func(t *testing.T) {
				unsupported := map[string]any{"main_url": "https://media.example.test/unsupported.mp4"}
				if field == "codec" {
					unsupported["video_meta"] = map[string]any{"codec_type": label, "definition": "2160p"}
				} else {
					unsupported["gear_des_key"] = "video_" + label + "_2160p"
				}
				model := map[string]any{"video_list": []any{unsupported}}
				if media, err := selectHongguoAppMedia(model); err == nil || media.URL != "" {
					t.Fatal("accepted unsupported ByteVC2 media")
				}
				model["video_list"] = append(model["video_list"].([]any), map[string]any{
					"main_url":   "https://media.example.test/compatible.mp4",
					"video_meta": map[string]any{"codec_type": "h264", "definition": "720p"},
				})
				if media, err := selectHongguoAppMedia(model); err != nil || media.Quality != 720 || len(media.Variants) != 1 {
					t.Fatal("unsupported media displaced the compatible rendition", err)
				}
			})
		}
	}
}

func TestHongguoAppMediaMedia(t *testing.T) {
	const videoID = "7000000000000000011"
	for _, encoding := range []string{"object", "JSON string"} {
		t.Run(encoding, func(t *testing.T) {
			var model any = hongguoVideoModelFixture()
			if encoding == "JSON string" {
				encoded, err := json.Marshal(model)
				if err != nil {
					t.Fatal(err)
				}
				model = string(encoded)
			}
			body, err := json.Marshal(map[string]any{"code": 0, "data": map[string]any{
				videoID: map[string]any{"video_model": model},
				"7000000000000000099": map[string]any{"video_model": map[string]any{"video_list": []any{
					map[string]any{"main_url": "https://media.example.test/other-episode.mp4"},
				}}},
			}})
			if err != nil {
				t.Fatal(err)
			}
			calls := 0
			d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if request.Method != http.MethodPost || request.URL.Path != "/novel/player/multi_video_model/v1/" {
					t.Errorf("unexpected stream request: %s %s", request.Method, request.URL.Path)
					return rankingHTTPResponse(request, http.StatusNotFound, ""), nil
				}
				assertHongguoUnsignedPlaybackRequest(t, request)
				var payload map[string]any
				if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
					t.Fatal(err)
				}
				biz := nestedMap(payload, "biz_param")
				if biz["video_platform"] != float64(1024) || biz["need_all_video_definition"] != true || biz["device_level"] != float64(1) || biz["detail_page_version"] != float64(0) {
					t.Errorf("invalid player parameters: %+v", biz)
				}
				if !reflect.DeepEqual(payload["mixed_video_id_map"], map[string]any{"1004": []any{videoID}}) {
					t.Errorf("player must request exactly the selected short-drama episode: %+v", payload["mixed_video_id_map"])
				}
				for _, legacy := range []string{"video_id", "content_type"} {
					if _, exists := payload[legacy]; exists {
						t.Errorf("player retained legacy field %s", legacy)
					}
				}
				return rankingHTTPResponse(request, http.StatusOK, string(body)), nil
			})
			media, err := d.resolveHongguoMedia(context.Background(), Task{
				DramaID: "hongguo:7000000000000000001",
				Chapter: Chapter{VideoURL: "hongguo-cenc://" + videoID},
			})
			if err != nil {
				t.Fatal(err)
			}
			if calls != 1 || media.URL != "https://media.example.test/high.mp4" || media.Referer != "https://novel.snssdk.com/" || media.Duration != 93554*time.Millisecond || media.Quality != 1080 {
				t.Fatalf("player lost selected media metadata or requested a fallback: calls=%d quality=%d duration=%s", calls, media.Quality, media.Duration)
			}
			if hex.EncodeToString(media.CENCKey) != "00112233445566778899aabbccddeeff" {
				t.Fatal("player lost the CENC content key")
			}
			if len(media.Variants) != 2 || media.Variants[0].Quality != 1080 || media.Variants[1].Quality != 720 || media.Variants[1].URL != "https://media.example.test/low.mp4" || hex.EncodeToString(media.Variants[1].CENCKey) != "00112233445566778899aabbccddeeff" {
				t.Fatal("player lost compatible quality choices or retained an unsupported codec")
			}
		})
	}
}

func assertHongguoUnsignedPlaybackRequest(t *testing.T, request *http.Request) {
	t.Helper()
	for _, name := range []string{"X-Gorgon", "X-Khronos", "X-SS-STUB", "X-Argus", "X-Ladon", "X-Helios", "X-Medusa", "Comment-Source", "Server-Channel"} {
		if request.Header.Get(name) != "" {
			t.Errorf("playback must not carry %s", name)
		}
	}
	query := request.URL.Query()
	for _, name := range []string{"device_id", "iid"} {
		if !hongguoNumericID.MatchString(query.Get(name)) {
			t.Errorf("playback must supply a numeric %s", name)
		}
	}
	if cdid := query.Get("cdid"); len(cdid) != 36 || cdid[14] != '4' || strings.Count(cdid, "-") != 4 {
		t.Error("playback must supply a UUID CDID")
	}
	ticket, err := strconv.ParseInt(query.Get("_rticket"), 10, 64)
	if err != nil || ticket <= 0 || query.Get("ts") != strconv.FormatInt(ticket/1000, 10) || request.Header.Get("X-SS-Req-Ticket") != query.Get("_rticket") {
		t.Error("playback timestamps must agree across query and headers")
	}
	if request.Header.Get("X-TT-Request-Tag") != "t=0;n=0" || request.Header.Get("Sdk-Version") != "2" || request.Header.Get("X-XS-From-Web") != "0" || request.Header.Get("User-Agent") != hongguoAppUserAgent {
		t.Error("playback lost required client headers")
	}
}

func TestHongguoPlaybackIdentityIsIsolatedFromCatalogAndRestart(t *testing.T) {
	const videoID = "800001"
	body, err := json.Marshal(map[string]any{"data": map[string]any{videoID: map[string]any{"video_model": hongguoVideoModelFixture()}}})
	if err != nil {
		t.Fatal(err)
	}
	state := &hongguoCatalogState{
		Version: 1, DeviceID: "7000000000000000001", InstallID: "7000000000000000002",
		Feeds: map[string]hongguoCatalogCursor{"short_play": {Offset: 18, Initialized: true}},
	}
	var identities [][3]string
	for restart := 0; restart < 2; restart++ {
		d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
			query := request.URL.Query()
			if strings.HasPrefix(request.URL.Path, "/novel/player/") {
				assertHongguoUnsignedPlaybackRequest(t, request)
				identity := [3]string{query.Get("device_id"), query.Get("iid"), query.Get("cdid")}
				if identity[0] == state.DeviceID || identity[1] == state.InstallID {
					t.Error("playback reused persisted catalog identifiers")
				}
				identities = append(identities, identity)
				return rankingHTTPResponse(request, http.StatusOK, string(body)), nil
			}
			if query.Get("device_id") != state.DeviceID || query.Get("iid") != state.InstallID || query.Get("cdid") != "" {
				t.Error("playback changed the catalog request identity")
			}
			for _, name := range []string{"X-Gorgon", "X-Khronos", "X-SS-STUB", "X-Argus", "X-Ladon", "X-Helios", "X-Medusa"} {
				if request.Header.Get(name) == "" {
					t.Errorf("catalog request lost its %s signature", name)
				}
			}
			return rankingHTTPResponse(request, http.StatusOK, `{"code":0}`), nil
		})
		d.restoreHongguoCatalog(state)
		for _, ctx := range []context.Context{context.Background(), context.WithValue(context.Background(), hongguoCommentKey{}, true)} {
			if _, err := d.resolveHongguoAppMedia(ctx, videoID); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/reading/distribution/category/landpage/v/", nil, map[string]any{"offset": 18}); err != nil {
			t.Fatal(err)
		}
		snapshot := d.hongguoCatalogSnapshot()
		if !reflect.DeepEqual(snapshot, state) {
			t.Fatal("playback changed persisted catalog pagination or identity")
		}
		persisted, err := json.Marshal(snapshot)
		if err != nil {
			t.Fatal(err)
		}
		for _, id := range identities[len(identities)-1] {
			if strings.Contains(string(persisted), id) {
				t.Error("playback identity must not be persisted")
			}
		}
	}
	if len(identities) != 4 || identities[0] != identities[1] || identities[2] != identities[3] {
		t.Fatal("playback identity must stay stable for each client lifetime")
	}
	for index := range identities[0] {
		if identities[0][index] == identities[2][index] {
			t.Error("playback identity was reused after restart")
		}
	}
}

func TestHongguoPlaybackRetryStaysUnsigned(t *testing.T) {
	const videoID = "800001"
	body, err := json.Marshal(map[string]any{"data": map[string]any{videoID: map[string]any{"video_model": hongguoVideoModelFixture()}}})
	if err != nil {
		t.Fatal(err)
	}
	var identities [][3]string
	d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
		assertHongguoUnsignedPlaybackRequest(t, request)
		query := request.URL.Query()
		identities = append(identities, [3]string{query.Get("device_id"), query.Get("iid"), query.Get("cdid")})
		if len(identities) == 1 {
			return rankingHTTPResponse(request, http.StatusServiceUnavailable, ""), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, string(body)), nil
	})
	d.cfg.Retries = 2
	if _, err := d.resolveHongguoAppMedia(context.Background(), videoID); err != nil {
		t.Fatal(err)
	}
	if len(identities) != 2 || identities[0] != identities[1] {
		t.Fatal("retry changed playback identity or did not recover")
	}
}

func TestHongguoAppMediaRejectsInvalidResponses(t *testing.T) {
	for _, test := range []struct {
		name string
		body string
		want string
	}{
		{"empty body", "", "未返回有效数据"},
		{"business error", `{"code":110001,"data":{}}`, "110001"},
		{"missing data", `{"code":0}`, "未返回兼容的媒体"},
		{"missing model", `{"code":0,"data":{"800001":{}}}`, "未返回兼容的媒体"},
		{"invalid model type", `{"code":0,"data":{"800001":{"video_model":[]}}}`, "未返回兼容的媒体"},
		{"invalid model JSON", `{"code":0,"data":{"800001":{"video_model":"{"}}}`, "播放信息格式异常"},
		{"null model JSON", `{"code":0,"data":{"800001":{"video_model":"null"}}}`, "未返回兼容的媒体"},
		{"another episode only", `{"code":0,"data":{"800002":{"video_model":{"video_list":[{"main_url":"https://media.example.test/other-episode.mp4"}]}}}}`, "未返回兼容的媒体"},
		{"legacy unkeyed model", `{"code":0,"data":{"video_model":{"video_list":[{"main_url":"https://media.example.test/other-episode.mp4"}]}}}`, "未返回兼容的媒体"},
	} {
		t.Run(test.name, func(t *testing.T) {
			d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
				return rankingHTTPResponse(request, http.StatusOK, test.body), nil
			})
			media, err := d.resolveHongguoAppMedia(context.Background(), "800001")
			if err == nil || !strings.Contains(err.Error(), test.want) || media.URL != "" {
				t.Fatalf("invalid player response was not rejected: %v", err)
			}
		})
	}
}
