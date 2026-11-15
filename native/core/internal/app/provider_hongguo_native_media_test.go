package app

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
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
					"encrypt":    false,
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
				if request.Method != http.MethodGet || request.URL.Path != hongguoVideoTabPath {
					t.Fatalf("unexpected current stream request: %s %s", request.Method, request.URL.Path)
				}
				assertHongguoSignedPlaybackRequest(t, request)
				query := request.URL.Query()
				for key, expected := range map[string]string{"video_id": videoID, "video_id_type": "0", "device_level": "1", "video_platform": "1024", "need_all_video_definition": "1", "need_mp4_align": "0", "use_os_player": "0", "source": "0"} {
					if query.Get(key) != expected {
						t.Errorf("wrong playback query %s", key)
					}
				}
				var result map[string]any
				json.Unmarshal(body, &result)
				if encoding == "JSON string" {
					body, _ = json.Marshal(map[string]any{"code": 0, "data": map[string]any{"video_model_data": result["data"]}})
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

func assertHongguoSignedPlaybackRequest(t *testing.T, request *http.Request) {
	t.Helper()
	for _, name := range []string{"X-Gorgon", "X-Helios", "X-Medusa", "X-VC-Bdturing-Sdk-Version", "Comment-Source", "Server-Channel"} {
		if request.Header.Get(name) != "" {
			t.Errorf("playback must not carry %s", name)
		}
	}
	for _, name := range []string{"X-Argus", "X-Ladon"} {
		decoded, err := base64.StdEncoding.DecodeString(request.Header.Get(name))
		if err != nil || len(decoded) <= 4 {
			t.Errorf("missing real %s signature", name)
		}
	}
	var body []byte
	if request.Body != nil {
		var err error
		body, err = io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		request.Body = io.NopCloser(bytes.NewReader(body))
	}
	if len(body) > 0 {
		digest := md5.Sum(body)
		if request.Header.Get("X-SS-STUB") != hex.EncodeToString(digest[:]) || request.Header.Get("Content-Encoding") != "gzip" {
			t.Error("signature does not bind the actual gzip wire body")
		}
	} else if request.Header.Get("X-SS-STUB") != "" || request.Header.Get("Content-Encoding") != "" || request.Header.Get("Content-Type") != "" {
		t.Error("bodyless GET acquired a body header")
	}
	if request.Header.Get("X-TT-Store-Region") != "cn" || request.Header.Get("X-TT-Store-Region-Src") != "did" {
		t.Error("missing anonymous player region")
	}
	q := request.URL.Query()
	for _, name := range []string{"device_id", "iid"} {
		if !hongguoNumericID.MatchString(q.Get(name)) {
			t.Errorf("invalid registered %s", name)
		}
	}
	if cdid := q.Get("cdid"); len(cdid) != 36 || cdid[14] != '4' || strings.Count(cdid, "-") != 4 {
		t.Error("invalid registered UUID")
	}
	stamp, err := strconv.ParseInt(request.Header.Get("X-Khronos"), 10, 64)
	if err != nil || q.Get("ts") != request.Header.Get("X-Khronos") || request.Header.Get("X-SS-Req-Ticket") != strconv.FormatInt(stamp*1000, 10) {
		t.Error("signature timestamps disagree")
	}
	ticket, err := strconv.ParseInt(q.Get("_rticket"), 10, 64)
	if err != nil || ticket < stamp*1000 || ticket >= (stamp+1)*1000 {
		t.Error("invalid final query ticket")
	}
	version, passport := "74332", "5051452"
	if request.URL.Path == hongguoVideoTabPath {
		version, passport = "73932", "50561"
	}
	if !strings.HasPrefix(request.Header.Get("User-Agent"), "com.phoenix.read/"+version+" ") || q.Get("version_code") != version || request.Header.Get("Passport-Sdk-Version") != passport || request.Header.Get("Sdk-Version") != "2" || request.Header.Get("X-SS-DP") != "8662" {
		t.Error("playback lost its endpoint profile")
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
			if request.URL.Path == hongguoVideoTabPath {
				assertHongguoSignedPlaybackRequest(t, request)
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
	if len(identities) != 4 {
		t.Fatal("missing playback identity")
	}
	for i := 1; i < len(identities); i++ {
		if identities[i][2] == identities[i-1][2] {
			t.Fatal("separate resolves reused an identity")
		}
	}
	for index := range identities[0] {
		if identities[0][index] == identities[2][index] {
			t.Error("playback identity was reused after restart")
		}
	}
}

func TestHongguoPlaybackRetryStaysSigned(t *testing.T) {
	const videoID = "800001"
	body, err := json.Marshal(map[string]any{"data": map[string]any{videoID: map[string]any{"video_model": hongguoVideoModelFixture()}}})
	if err != nil {
		t.Fatal(err)
	}
	var identities [][3]string
	d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
		assertHongguoSignedPlaybackRequest(t, request)
		query := request.URL.Query()
		identities = append(identities, [3]string{query.Get("device_id"), query.Get("iid"), query.Get("cdid")})
		if len(identities) == 1 {
			return rankingHTTPResponse(request, http.StatusOK, ""), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, string(body)), nil
	})
	d.cfg.Retries = 2
	if _, err := d.resolveHongguoAppMedia(context.Background(), videoID); err != nil {
		t.Fatal(err)
	}
	if len(identities) != 2 || identities[0] == identities[1] {
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
		{"trailing model JSON", `{"data":{"800001":{"video_model":"{} {}"}}}`, "播放信息格式异常"},
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
