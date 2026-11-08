package app

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const hongguoDeviceFixture = `{"device_id":3330000000000000001,"install_id_str":"4440000000000000001"}`

func hongguoRegisteredMediaDownloader(t *testing.T, transport rankingTransport) *Downloader {
	t.Helper()
	body := fmt.Sprintf(`{"device_id_str":%q,"install_id_str":%q}`, newHongguoDeviceID(), newHongguoDeviceID())
	return rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			return rankingHTTPResponse(request, http.StatusOK, body), nil
		}
		return transport(request)
	})
}

// Decode the wire format independently: binary prefix, derived AES-CBC key,
// PKCS#7 padding, SHA-512 checksum, gzip, then the registration JSON.
func inspectHongguoRegistration(t *testing.T, request *http.Request) map[string]any {
	t.Helper()
	if request.Method != http.MethodPost || request.URL.Host != "log5-applog-lf.fqnovel.com" || request.URL.Query().Get("tt_data") != "a" || request.URL.Query().Get("use_store_region_cookie") != "1" {
		t.Error("registration changed its endpoint or transport parameters")
	}
	for _, name := range []string{"Cookie", "X-Gorgon", "X-Khronos", "X-Argus", "X-Ladon", "X-Helios", "X-Medusa"} {
		if request.Header.Get(name) != "" {
			t.Errorf("anonymous registration sent %s", name)
		}
	}
	if request.Header.Get("Content-Type") != "application/octet-stream;tt-data=a" || request.Header.Get("Log-Encode-Type") != "gzip" || request.Header.Get("X-SS-DP") != "8662" || request.Header.Get("X-Neptune") != "-8|50:51:59:30:40:47:49:39" {
		t.Error("registration lost its binary protocol headers")
	}
	body, err := io.ReadAll(request.Body)
	if err != nil {
		t.Fatal(err)
	}
	if request.Header.Get("X-SS-STUB") != fmt.Sprintf("%X", md5.Sum(body)) {
		t.Error("registration checksum does not match the encrypted body")
	}
	if len(body) < 54 || !bytes.Equal(body[:6], []byte{0x74, 0x63, 5, 0x10, 0, 0}) || (len(body)-38)%16 != 0 {
		t.Fatal("registration body is not raw ttEncrypt binary")
	}
	salt, _ := hex.DecodeString("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	seedHash := sha512.Sum512(body[6:38])
	derived := sha512.Sum512(append(seedHash[:], salt...))
	block, err := aes.NewCipher(derived[:16])
	if err != nil {
		t.Fatal(err)
	}
	plain := make([]byte, len(body)-38)
	cipher.NewCBCDecrypter(block, derived[16:32]).CryptBlocks(plain, body[38:])
	padding := int(plain[len(plain)-1])
	if padding < 1 || padding > 16 || !bytes.Equal(plain[len(plain)-padding:], bytes.Repeat([]byte{byte(padding)}, padding)) {
		t.Fatal("registration body has invalid padding")
	}
	plain = plain[:len(plain)-padding]
	if len(plain) < 64 {
		t.Fatal("registration body has no checksum")
	}
	checksum := sha512.Sum512(plain[64:])
	if !bytes.Equal(plain[:64], checksum[:]) {
		t.Fatal("registration body checksum is invalid")
	}
	reader, err := gzip.NewReader(bytes.NewReader(plain[64:]))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	var payload map[string]any
	if err := json.NewDecoder(reader).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	header := nestedMap(payload, "header")
	if payload["magic_tag"] != "ss_app_log" || header["aid"] != float64(8662) || header["package"] != "com.phoenix.read" || header["os_version"] != "16" || header["device_model"] != "25053RT47C" || header["sig_hash"] != "56a962410c494bbaf0b58dba20cae56f" {
		t.Error("registration payload lost required app/device fields or string OS version")
	}
	if header["device_id"] != nil || header["install_id"] != nil || payload["_gen_time"] != header["apk_first_install_time"] || fmt.Sprint(payload["_gen_time"]) == "0" {
		t.Error("cold registration sent an existing identity or inconsistent timestamps")
	}
	return header
}

func TestHongguoPlaybackDeviceRegistrationIsScopedToResolve(t *testing.T) {
	var registrations, models int
	var registration map[string]any
	var identity [3]string
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
			registration = inspectHongguoRegistration(t, request)
			response := rankingHTTPResponse(request, http.StatusOK, hongguoDeviceFixture)
			for _, cookie := range []string{"ttreq=fixture; Path=/", "install_id=4440000000000000001; Path=/", "store-region=cn; Path=/", "store-region-src=did; Path=/", "sessionid=account-secret; Path=/", "unrelated=excluded; Path=/"} {
				response.Header.Add("Set-Cookie", cookie)
			}
			return response, nil
		}
		models++
		query := request.URL.Query()
		current := [3]string{query.Get("device_id"), query.Get("iid"), query.Get("cdid")}
		if registrations != (models+1)/2 || current[0] != "3330000000000000001" || current[1] != "4440000000000000001" || registration["cdid"] != current[2] || registration["app_version"] != query.Get("version_name") {
			t.Error("playback did not use the registered device profile")
		}
		if models == 1 {
			identity = current
		} else if models == 2 && current != identity {
			t.Error("retry or next resolve rotated the registered identity")
		}
		cookies := request.Cookies()
		if len(cookies) != 4 || request.Header.Get("Cookie") != "install_id=4440000000000000001; ttreq=fixture; store-region=cn; store-region-src=did" {
			t.Error("playback did not restrict cookies to registered device cookies")
		}
		assertHongguoSignedPlaybackRequest(t, request)
		if models == 1 {
			return rankingHTTPResponse(request, http.StatusServiceUnavailable, ""), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, `{"data":{"800001":{"video_model":{"video_list":[{"main_url":"https://media.example.test/episode.mp4","codec_type":"h264","encrypt":false}]}}}}`), nil
	})
	d.cfg.Retries = 2
	d.client.Jar, _ = cookiejar.New(nil)
	for _, host := range []string{hongguoAppBaseURL, "https://log5-applog-lf.fqnovel.com"} {
		address, _ := url.Parse(host)
		d.client.Jar.SetCookies(address, []*http.Cookie{{Name: "sessionid", Value: "account-secret"}})
	}
	for range 2 {
		if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
			t.Fatal(err)
		}
	}
	if registrations != 2 || models != 3 {
		t.Fatalf("registration/model request counts: %d/%d", registrations, models)
	}
}

func TestHongguoPlaybackDeviceRegistrationRejectsInvalidResponses(t *testing.T) {
	for _, body := range []string{"", `null`, `{`, `{"device_id":0,"install_id":444}`, `{"device_id":"333","install_id":"bad"}`, `{"device_id":"0333","install_id":"444"}`, `{"device_id":3e19,"install_id":444}`, `{"device_id":"333","install_id":"444"} {}`, `{"device_id":"333"}`, `{"device_id":"1234567890123456789012345678901","install_id":"444"}`, `{"code":110001,"device_id":"333","install_id":"444"}`, strings.Repeat(" ", 65537)} {
		t.Run(fmt.Sprint(len(body))+"-"+truncate(body, 35), func(t *testing.T) {
			models := 0
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/service/2/device_register/" {
					return rankingHTTPResponse(request, http.StatusOK, body), nil
				}
				models++
				return rankingHTTPResponse(request, http.StatusOK, `{}`), nil
			})
			_, err := d.resolveHongguoAppMedia(context.Background(), "800001")
			if err == nil || !strings.Contains(err.Error(), "播放设备注册失败") || models != 0 {
				t.Fatalf("invalid registration reached media resolution: models=%d error=%v", models, err)
			}
		})
	}
}

func TestHongguoPlaybackDeviceRegistrationFailureCanRetry(t *testing.T) {
	registrations := 0
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
			if registrations == 1 {
				return rankingHTTPResponse(request, http.StatusBadGateway, "private-response-details"), nil
			}
			return rankingHTTPResponse(request, http.StatusOK, hongguoDeviceFixture), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, `{"data":{"800001":{"video_model":{"video_list":[{"main_url":"https://media.example.test/episode.mp4","codec_type":"h264","encrypt":false}]}}}}`), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || !strings.Contains(err.Error(), "播放设备注册失败") || strings.Contains(err.Error(), "private-response-details") {
		t.Fatal("registration failure did not retain a safe error", err)
	}
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); !errors.Is(err, errHongguoDeviceRegistration) || registrations != 1 {
		t.Fatal("registration rejection ignored cooldown", err)
	}
	d.hongguoClient().registrationRetryAfter = time.Now().Add(-time.Second)
	for range 2 {
		if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
			t.Fatal(err)
		}
	}
	if registrations != 3 {
		t.Fatal("resolve did not get its own registration")
	}
}

func TestHongguoPlaybackRegistrationCancellationIsIsolated(t *testing.T) {
	entered := make(chan struct{})
	var registrations atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			if registrations.Add(1) == 1 {
				close(entered)
				<-request.Context().Done()
				return nil, request.Context().Err()
			}
			return rankingHTTPResponse(request, http.StatusOK, hongguoDeviceFixture), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800002")), nil
	})
	d.limiter = newRequestLimiter(8, time.Nanosecond)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := d.resolveHongguoAppMedia(ctx, "800001"); done <- err }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("registration did not start")
	}
	// The source limiter serializes network I/O; cancellation must release its
	// gate so a different resolve can register its own identity and succeed.
	other := make(chan error, 1)
	go func() { _, err := d.resolveHongguoAppMedia(context.Background(), "800002"); other <- err }()
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal("registration ignored cancellation", err)
	}
	if err := <-other; err != nil {
		t.Fatal("another resolve inherited cancellation or cooldown", err)
	}
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800002"); err != nil {
		t.Fatal("canceled registration imposed a cooldown", err)
	}
	if registrations.Load() != 3 {
		t.Fatal("separate resolves reused a device")
	}
}

func TestHongguoConcurrentPlaybackUsesIndependentDevices(t *testing.T) {
	var mu sync.Mutex
	devices := map[string]bool{}
	var registrations atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			n := registrations.Add(1)
			return rankingHTTPResponse(request, http.StatusOK, fmt.Sprintf(`{"device_id":"%d","install_id":"%d"}`, 100000+n, 200000+n)), nil
		}
		mu.Lock()
		defer mu.Unlock()
		id := request.URL.Query().Get("device_id")
		if devices[id] {
			t.Error("concurrent resolves shared a single-use identity")
		}
		devices[id] = true
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001")), nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var group sync.WaitGroup
	for range 8 {
		group.Go(func() {
			if _, err := d.resolveHongguoAppMedia(ctx, "800001"); err != nil {
				t.Error(err)
			}
		})
	}
	group.Wait()
	if registrations.Load() != 8 || len(devices) != 8 {
		t.Fatal("concurrent resolves did not allocate separate identities")
	}
}

func TestHongguoPlaybackEmptyResponseRetriesWithinExistingBudget(t *testing.T) {
	for _, body := range []string{"", " \n\t"} {
		t.Run(fmt.Sprint(len(body)), func(t *testing.T) {
			var registrations, models int
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/service/2/device_register/" {
					registrations++
					return rankingHTTPResponse(request, http.StatusOK, hongguoDeviceFixture), nil
				}
				models++
				if models == 1 {
					return rankingHTTPResponse(request, http.StatusOK, body), nil
				}
				return rankingHTTPResponse(request, http.StatusOK, `{"data":{"800001":{"video_model":{"video_list":[{"main_url":"https://media.example.test/episode.mp4","codec_type":"h264","encrypt":false}]}}}}`), nil
			})
			d.cfg.Retries = 2
			if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
				t.Fatal("transient empty response did not recover", err)
			}
			if registrations != 1 || models != 2 {
				t.Fatalf("empty response registration/model requests: %d/%d", registrations, models)
			}
			models = 0
			d.cfg.Retries = 1
			if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || !strings.Contains(err.Error(), "未返回有效数据") || models != 1 || registrations != 2 {
				t.Fatal("empty response exceeded the request budget or reused identity", err)
			}
		})
	}
}

func TestHongguoPlaybackDeviceCookiesDoNotFollowRedirects(t *testing.T) {
	for _, stage := range []string{"registration", "playback"} {
		t.Run(stage, func(t *testing.T) {
			calls := 0
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if request.URL.Host == "untrusted.example.test" {
					t.Error("anonymous playback forwarded a request on redirect")
					return rankingHTTPResponse(request, http.StatusOK, `{}`), nil
				}
				if stage == "playback" && request.URL.Path == "/service/2/device_register/" {
					response := rankingHTTPResponse(request, http.StatusOK, hongguoDeviceFixture)
					response.Header.Add("Set-Cookie", "ttreq=fixture; Path=/")
					return response, nil
				}
				response := rankingHTTPResponse(request, http.StatusTemporaryRedirect, "")
				response.Header.Set("Location", "https://untrusted.example.test/redirect")
				return response, nil
			})
			_, err := d.resolveHongguoAppMedia(context.Background(), "800001")
			wantCalls := 1
			if stage == "playback" {
				wantCalls = 2
			}
			if err == nil || !strings.Contains(err.Error(), "HTTP 307") || calls != wantCalls {
				t.Fatal("registration/playback redirect was not rejected", calls, err)
			}
		})
	}
}

func TestHongguoPlaybackDoesNotRetryBusinessOrFormatErrors(t *testing.T) {
	for _, body := range []string{`{"code":110001}`, `{`, `{"data":{}}`} {
		t.Run(body, func(t *testing.T) {
			models := 0
			d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
				models++
				return rankingHTTPResponse(request, http.StatusOK, body), nil
			})
			d.cfg.Retries = 3
			if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || models != 1 {
				t.Fatal("nonempty error response was retried or accepted", models, err)
			}
		})
	}
}
