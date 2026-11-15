package app

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

const hongguoFallbackFixtureURL = "https://api5-normal-sinfonlineb.fqnovel.com/fixture-fallback"

func hongguoFallbackFixtureModel(clear bool) map[string]any {
	row := map[string]any{"codec_type": "h264", "vwidth": 1080, "vheight": 1920, "main_url": "https://qznovelvod.com/fixture.mp4"}
	if clear {
		row["encrypt"] = false
	}
	return map[string]any{"video_id": "internal-video-one", "video_duration": 56.007, "video_list": []any{row}, "fallback_api": hongguoFallbackFixtureURL}
}
func hongguoJSON(value any) string { raw, _ := json.Marshal(value); return string(raw) }
func hongguoFallbackFixtureDownloader(t *testing.T, inline, fallback map[string]any, status int) (*Downloader, *int, *int) {
	t.Helper()
	models, backups := 0, 0
	d := hongguoRegisteredMediaDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/fixture-fallback" {
			backups++
			if deadline, ok := r.Context().Deadline(); !ok || time.Until(deadline) > 8*time.Second {
				t.Error("fallback exceeded its subdeadline")
			}
			if r.Method != "GET" || r.Header.Get("Cookie") != "" || r.Header.Get("X-Gorgon") != "" || r.Header.Get("X-Medusa") != "" {
				t.Error("fallback forwarded identity, cookies or signatures")
			}
			return rankingHTTPResponse(r, status, hongguoJSON(map[string]any{"code": 0, "video_info": map[string]any{"code": 0, "data": fallback}})), nil
		}
		models++
		return rankingHTTPResponse(r, 200, hongguoJSON(map[string]any{"data": map[string]any{"800001": map[string]any{"video_model": hongguoJSON(inline)}}})), nil
	})
	d.client.Jar, _ = cookiejar.New(nil)
	address, _ := url.Parse(hongguoFallbackFixtureURL)
	d.client.Jar.SetCookies(address, []*http.Cookie{{Name: "sessionid", Value: "account-secret"}})
	return d, &models, &backups
}
func TestHongguoFallbackOnlyRecoversMissingMetadata(t *testing.T) {
	for _, clear := range []bool{true, false} {
		t.Run(fmt.Sprint(clear), func(t *testing.T) {
			inline, fallback := hongguoFallbackFixtureModel(clear), hongguoFallbackFixtureModel(true)
			row := fallback["video_list"].([]any)[0].(map[string]any)
			row["encrypt"] = true
			row["spade_a"] = hongguoSyntheticSpade
			d, models, backups := hongguoFallbackFixtureDownloader(t, inline, fallback, 200)
			media, err := d.resolveHongguoAppMedia(context.Background(), "800001")
			want := 1
			if clear {
				want = 0
			}
			if err != nil || *models != 1 || *backups != want || media.Quality != 1080 {
				t.Fatal("incorrect fallback request contract", err, *models, *backups)
			}
			if !clear && hex.EncodeToString(media.CENCKey) != "00112233445566778899aabbccddeeff" {
				t.Fatal("recovered media lost key")
			}
		})
	}
}
func TestHongguoFallbackEligibilityRejectsUnprovenModels(t *testing.T) {
	for _, name := range []string{"missing id", "numeric id", "missing duration", "zero duration", "NaN duration", "missing dimensions", "encrypted without key", "bad key", "unsafe URL", "lookalike host"} {
		t.Run(name, func(t *testing.T) {
			inline := hongguoFallbackFixtureModel(false)
			row := inline["video_list"].([]any)[0].(map[string]any)
			switch name {
			case "missing id":
				delete(inline, "video_id")
			case "numeric id":
				inline["video_id"] = 800001
			case "missing duration":
				delete(inline, "video_duration")
			case "zero duration":
				inline["video_duration"] = 0
			case "NaN duration":
				inline["video_duration"] = "NaN"
			case "missing dimensions":
				delete(row, "vwidth")
				row["definition"] = "1080p"
			case "encrypted without key":
				row["encrypt"] = true
			case "bad key":
				row["spade_a"] = "invalid"
			case "unsafe URL":
				inline["fallback_api"] = "https://127.0.0.1/private"
			case "lookalike host":
				inline["fallback_api"] = "https://fqnovel.com.attacker.invalid/private"
			}
			d, _, backups := hongguoFallbackFixtureDownloader(t, inline, hongguoFallbackFixtureModel(true), 200)
			if media, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || media.URL != "" || *backups != 0 {
				t.Fatal("unproven model triggered recovery", err, *backups)
			}
		})
	}
}
func TestHongguoFallbackIndependentlyValidatesEveryCandidate(t *testing.T) {
	for _, name := range []string{"wrong id", "missing id", "preview", "missing duration", "unknown encryption", "missing key", "invalid key", "low actual dimensions", "missing dimensions", "unsafe media", "unsupported codec"} {
		t.Run(name, func(t *testing.T) {
			backup := hongguoFallbackFixtureModel(true)
			row := backup["video_list"].([]any)[0].(map[string]any)
			switch name {
			case "wrong id":
				backup["video_id"] = "different"
			case "missing id":
				delete(backup, "video_id")
			case "preview":
				backup["video_duration"] = 10
			case "missing duration":
				delete(backup, "video_duration")
			case "unknown encryption":
				delete(row, "encrypt")
			case "missing key":
				row["encrypt"] = true
			case "invalid key":
				row["spade_a"] = "invalid"
			case "low actual dimensions":
				row["vwidth"] = 720
				row["vheight"] = 1280
				row["definition"] = "1080p"
			case "missing dimensions":
				delete(row, "vwidth")
			case "unsafe media":
				row["main_url"] = "https://127.0.0.1/private"
			case "unsupported codec":
				row["codec_type"] = "bytevc2"
			}
			d, models, backups := hongguoFallbackFixtureDownloader(t, hongguoFallbackFixtureModel(false), backup, 200)
			if media, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002"); err == nil || media.URL != "" || *models != 1 || *backups != 1 {
				t.Fatal("invalid fallback accepted or repeated model request", err, *models, *backups)
			}
		})
	}
	backup := hongguoFallbackFixtureModel(true)
	backup["video_duration"] = 56.006644
	backup["video_list"] = append(backup["video_list"].([]any), map[string]any{"codec_type": "h264", "encrypt": false, "vwidth": 720, "vheight": 1280, "main_url": "https://qznovelvod.com/low.mp4"})
	d, _, _ := hongguoFallbackFixtureDownloader(t, hongguoFallbackFixtureModel(false), backup, 200)
	media, err := d.resolveHongguoAppMedia(context.Background(), "800001")
	if err != nil || len(media.Variants) != 1 || media.Variants[0].Quality != 1080 {
		t.Fatal("rounding or resolution floor mishandled", err)
	}
}
func TestHongguoFallbackRefusalRedirectAndCancellation(t *testing.T) {
	for _, status := range []int{403, 429, 307, 503} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			d, models, backups := hongguoFallbackFixtureDownloader(t, hongguoFallbackFixtureModel(false), nil, status)
			_, err := d.resolveHongguoAppMedia(context.Background(), "800001", "800002")
			if err == nil || *models != 1 || *backups != 1 || isHongguoSourceRefusal(err) != (status == 403 || status == 429) {
				t.Fatal("incorrect fallback refusal or repeated lookup", err)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	d := hongguoRegisteredMediaDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/fixture-fallback" {
			calls++
			cancel()
			return nil, r.Context().Err()
		}
		return rankingHTTPResponse(r, 200, hongguoJSON(map[string]any{"data": map[string]any{"800001": map[string]any{"video_model": hongguoFallbackFixtureModel(false)}}})), nil
	})
	_, err := d.resolveHongguoAppMedia(ctx, "800001", "800002")
	if !errors.Is(err, context.Canceled) || calls != 1 || len(d.hongguoClient().upcomingModels) != 0 {
		t.Fatal("cancellation published or retried fallback", err)
	}
}
func TestHongguoOfficialRefusalStopsBeforeOtherProviderRoutes(t *testing.T) {
	for _, stage := range []string{"registration", "model"} {
		for _, method := range []string{"resolve", "downloadPlan"} {
			t.Run(stage+"/"+method, func(t *testing.T) {
				c, err := NewMobileClient(t.TempDir())
				if err != nil {
					t.Fatal(err)
				}
				defer c.Close()
				d := c.downloader
				d.limiter = newRequestLimiter(8, time.Nanosecond)
				calls := 0
				d.client = &http.Client{Transport: rankingTransport(func(r *http.Request) (*http.Response, error) {
					calls++
					if r.URL.Path == "/service/2/device_register/" {
						if stage == "registration" {
							return rankingHTTPResponse(r, 200, `{"code":110001}`), nil
						}
						return rankingHTTPResponse(r, 200, hongguoDeviceFixture), nil
					}
					if r.URL.Path == hongguoVideoTabPath {
						return rankingHTTPResponse(r, 403, "account-secret"), nil
					}
					t.Error("refusal reached webpage or third-party route")
					return rankingHTTPResponse(r, 503, ""), nil
				})}
				_, err = c.Call(hongguoJSON(map[string]any{"method": method, "traceId": "refusal", "id": "hongguo:700001", "chapter": map[string]any{"id": "1", "videoUrl": "hongguo-cenc://800001"}}))
				if err == nil {
					t.Fatal("refusal did not fail")
				}
				raw, err := c.Call(`{"method":"requestDiagnostic","traceId":"refusal"}`)
				if err != nil {
					t.Fatal(err)
				}
				var diagnostic struct {
					Diagnostic mobileDiagnostic `json:"diagnostic"`
				}
				if err = json.Unmarshal([]byte(raw), &diagnostic); err != nil {
					t.Fatal(err)
				}
				v := diagnostic.Diagnostic
				wantReason, wantCalls := "http_denied", 2
				if stage == "registration" {
					wantReason, wantCalls = "registration_failed", 1
				}
				if v.Source != sourceHongguo || v.Method != method || v.SourceStage != stage || v.SourceFailure != wantReason || v.Result != "failed" || calls != wantCalls {
					t.Fatalf("diagnostic refusal contract: %+v calls=%d", v, calls)
				}
				if strings.Contains(raw, "account-secret") || strings.Contains(raw, "fqnovel.com") || strings.Contains(raw, "device_id") {
					t.Fatal("diagnostic leaked request data")
				}
			})
		}
	}
}

func TestHongguoFallbackURLCipherUsesIndependentNodeFixtures(t *testing.T) {
	raw, err := os.ReadFile("testdata/hongguo_spade_urls.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []struct{ Seed, Address, Encoded string }
	if err = json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatal(err)
	}
	for _, f := range fixtures {
		urlSafe := strings.TrimRight(strings.NewReplacer("+", "-", "/", "_").Replace(f.Encoded), "=")
		if decoded, err := decodeHongguoSpadeURL(urlSafe, f.Seed); err != nil || decoded != f.Address {
			t.Fatal("URL-safe Spade representation differs", err)
		}
		decoded, err := decodeHongguoSpadeURL(f.Encoded, f.Seed)
		if err != nil || decoded != f.Address {
			t.Fatal("Spade URL differs from independent Node fixture", err)
		}
	}
	for _, bad := range []string{"", "invalid", fixtures[0].Encoded[:8], strings.Repeat("x", 16385)} {
		if _, err := decodeHongguoSpadeURL(bad, fixtures[0].Seed); err == nil {
			t.Fatal("malformed encrypted address accepted")
		}
	}
	backup := hongguoFallbackFixtureModel(true)
	row := backup["video_list"].([]any)[0].(map[string]any)
	backup["key_seed"] = fixtures[0].Seed
	row["main_url"] = fixtures[0].Encoded
	row["backup_url_list"] = []any{fixtures[1].Encoded, fixtures[2].Encoded}
	d, _, _ := hongguoFallbackFixtureDownloader(t, hongguoFallbackFixtureModel(false), backup, 200)
	media, err := d.resolveHongguoAppMedia(context.Background(), "800001")
	if err != nil || media.URL != fixtures[0].Address || len(media.Variants) != 2 || media.Variants[1].URL != fixtures[1].Address {
		t.Fatal("encrypted URL validation or backup retention failed", err)
	}
}

func TestHongguoFallbackAcceptsSupportedAddressWrappersAndRejectsRedirects(t *testing.T) {
	for _, address := range []any{hongguoFallbackFixtureURL, map[string]any{"fallback_api": hongguoFallbackFixtureURL}, hongguoJSON(map[string]any{"fallback_api": hongguoFallbackFixtureURL}), []any{hongguoFallbackFixtureURL}} {
		inline := hongguoFallbackFixtureModel(false)
		inline["fallback_api"] = address
		d, _, calls := hongguoFallbackFixtureDownloader(t, inline, hongguoFallbackFixtureModel(true), 200)
		if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil || *calls != 1 {
			t.Fatal("supported fallback wrapper failed", err)
		}
	}
	calls := 0
	d := hongguoRegisteredMediaDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/fixture-fallback" {
			calls++
			response := rankingHTTPResponse(r, 307, "")
			response.Header.Set("Location", "https://api5-normal-hl.fqnovel.com/redirect")
			return response, nil
		}
		if strings.Contains(r.URL.Path, "redirect") {
			t.Fatal("fallback followed a redirect")
		}
		return rankingHTTPResponse(r, 200, hongguoJSON(map[string]any{"data": map[string]any{"800001": map[string]any{"video_model": hongguoFallbackFixtureModel(false)}}})), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || calls != 1 {
		t.Fatal("redirect contract failed", err)
	}
}

func TestHongguoFallbackNetworkFailureDoesNotBorrowInlineHTTPStatus(t *testing.T) {
	d := hongguoRegisteredMediaDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/fixture-fallback" {
			return nil, errors.New("fixture connection failure")
		}
		return rankingHTTPResponse(r, 200, hongguoJSON(map[string]any{"data": map[string]any{"800001": map[string]any{"video_model": hongguoFallbackFixtureModel(false)}}})), nil
	})
	trace := &mobileTrace{value: mobileDiagnostic{At: time.Now()}}
	ctx := context.WithValue(context.Background(), mobileTraceKey{}, trace)
	_, err := d.resolveHongguoAppMedia(ctx, "800001")
	result := trace.snapshot(err, nil, true)
	if err == nil || result.SourceStage != "model_fallback" || result.SourceFailure != "fallback_request_failed" || result.HTTPStatus != 0 || result.ResponseBytes != 0 {
		t.Fatalf("stale inline response leaked into fallback diagnostic: %+v", result)
	}
}

func TestHongguoFallbackRespectsRequestedOriginalQualityTier(t *testing.T) {
	for _, quality := range []int{0, 720, 480} {
		t.Run(fmt.Sprint(quality), func(t *testing.T) {
			inline := hongguoFallbackFixtureModel(false)
			inline["video_list"] = append(inline["video_list"].([]any), map[string]any{"codec_type": "h264", "vwidth": 720, "vheight": 1280, "main_url": "https://qznovelvod.com/low.mp4"})
			backup := hongguoFallbackFixtureModel(true)
			row := backup["video_list"].([]any)[0].(map[string]any)
			row["vwidth"], row["vheight"] = 720, 1280
			d, _, backups := hongguoFallbackFixtureDownloader(t, inline, backup, 200)
			c, err := NewMobileClient(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			c.downloader = d
			raw, err := c.Call(hongguoJSON(map[string]any{"method": "resolve", "id": "hongguo:700001", "chapter": map[string]any{"id": "1", "videoUrl": "hongguo-cenc://800001"}, "quality": quality}))
			if quality == 720 {
				if err != nil {
					t.Fatal("matching original manual quality tier was rejected")
				}
				var result struct {
					Quality int `json:"quality"`
				}
				if json.Unmarshal([]byte(raw), &result) != nil || result.Quality != 720 || *backups != 1 {
					t.Fatal("manual quality was not preserved")
				}
			} else {
				if err == nil {
					t.Fatal("automatic quality downgraded or unavailable manual tier invented")
				}
				want := 1
				if quality == 480 {
					want = 0
				}
				if *backups != want {
					t.Fatal("incorrect fallback eligibility", *backups)
				}
			}
		})
	}
}
