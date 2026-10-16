package app

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func hongguoPreloadModelFixture() map[string]any {
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

func TestHongguoAppPreloadMedia(t *testing.T) {
	const videoID = "7000000000000000011"
	for _, encoding := range []string{"object", "JSON string"} {
		t.Run(encoding, func(t *testing.T) {
			var model any = hongguoPreloadModelFixture()
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
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if request.Method != http.MethodPost || request.URL.Path != "/novel/player/multi_video_model/preload/v1/" {
					t.Errorf("unexpected stream request: %s %s", request.Method, request.URL.Path)
					return rankingHTTPResponse(request, http.StatusNotFound, ""), nil
				}
				var payload map[string]any
				if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
					t.Fatal(err)
				}
				biz := nestedMap(payload, "biz_param")
				if biz["video_platform"] != float64(1024) || biz["need_all_video_definition"] != true || biz["device_level"] != float64(3) || biz["detail_page_version"] != float64(0) {
					t.Errorf("invalid preload parameters: %+v", biz)
				}
				if !reflect.DeepEqual(payload["mixed_video_id_map"], map[string]any{"1004": []any{videoID}}) {
					t.Errorf("preload must request exactly the selected short-drama episode: %+v", payload["mixed_video_id_map"])
				}
				for _, legacy := range []string{"video_id", "content_type"} {
					if _, exists := payload[legacy]; exists {
						t.Errorf("preload retained legacy field %s", legacy)
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
				t.Fatalf("preload lost selected media metadata or requested a fallback: calls=%d quality=%d duration=%s", calls, media.Quality, media.Duration)
			}
			if hex.EncodeToString(media.CENCKey) != "00112233445566778899aabbccddeeff" {
				t.Fatal("preload lost the CENC content key")
			}
			if len(media.Variants) != 2 || media.Variants[0].Quality != 1080 || media.Variants[1].Quality != 720 || media.Variants[1].URL != "https://media.example.test/low.mp4" || hex.EncodeToString(media.Variants[1].CENCKey) != "00112233445566778899aabbccddeeff" {
				t.Fatal("preload lost compatible quality choices or retained an unsupported codec")
			}
		})
	}
}

func TestHongguoAppPreloadRejectsInvalidResponses(t *testing.T) {
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
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				return rankingHTTPResponse(request, http.StatusOK, test.body), nil
			})
			media, err := d.resolveHongguoAppMedia(context.Background(), "800001")
			if err == nil || !strings.Contains(err.Error(), test.want) || media.URL != "" {
				t.Fatalf("invalid preload response was not rejected: %v", err)
			}
		})
	}
}
