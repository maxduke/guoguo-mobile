package app

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"testing/iotest"
	"time"
)

func TestHongguoMobilePlaybackHasBoundedDedicatedRetries(t *testing.T) {
	for _, outcome := range []string{"recover", "exhaust", "cancel"} {
		t.Run(outcome, func(t *testing.T) {
			c, err := NewMobileClient(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			d := c.downloader
			d.limiter = newRequestLimiter(8, time.Nanosecond)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			registrations := 0
			var paths []string
			d.client = &http.Client{Transport: rankingTransport(func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/service/2/device_register/" {
					registrations++
					return rankingHTTPResponse(r, 200, hongguoDeviceFixture), nil
				}
				assertHongguoSignedPlaybackRequest(t, r)
				paths = append(paths, r.URL.Path)
				if outcome == "cancel" {
					cancel()
				}
				if outcome == "recover" && len(paths) == 2 {
					return rankingHTTPResponse(r, 200, hongguoModelBatchFixture("800001")), nil
				}
				return rankingHTTPResponse(r, 200, ""), nil
			})}
			if outcome == "recover" {
				_, err = c.Call(`{"method":"resolve","id":"hongguo:700001","chapter":{"id":"one","videoUrl":"hongguo-cenc://800001"}}`)
				if err != nil {
					t.Fatal(err)
				}
			} else {
				_, err = d.resolveHongguoAppMedia(ctx, "800001", "800002")
				if err == nil || outcome == "cancel" && !errors.Is(err, context.Canceled) {
					t.Fatal("ignored exhaustion/cancellation", err)
				}
			}
			want := []string{hongguoVideoTabPath, hongguoLegacyPlayerPath}
			wantRegistrations := 2
			if outcome == "cancel" {
				want = want[:1]
				wantRegistrations = 1
			}
			if !reflect.DeepEqual(paths, want) || registrations != wantRegistrations || d.hongguoRequestAttempts() != 2 {
				t.Fatal("playback expanded its two-model bound or changed general retries", paths, registrations)
			}
		})
	}
}

func TestHongguoPlaybackNonEmptyFailuresDoNotProbeLegacy(t *testing.T) {
	for _, failure := range []string{"HTTP 503", "connection", "body read", "wrong episode", "bad JSON"} {
		t.Run(failure, func(t *testing.T) {
			calls := 0
			d := hongguoRegisteredMediaDownloader(t, func(r *http.Request) (*http.Response, error) {
				calls++
				assertHongguoSignedPlaybackRequest(t, r)
				switch failure {
				case "HTTP 503":
					return rankingHTTPResponse(r, 503, ""), nil
				case "connection":
					return nil, errors.New("fixture connection failed")
				case "body read":
					response := rankingHTTPResponse(r, 200, "")
					response.Body = io.NopCloser(iotest.ErrReader(errors.New("read failed")))
					return response, nil
				case "wrong episode":
					return rankingHTTPResponse(r, 200, hongguoModelBatchFixture("800002")), nil
				default:
					return rankingHTTPResponse(r, 200, "{"), nil
				}
			})
			d.cfg.hongguoPlayerAttempts = 4
			if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || calls != 1 {
				t.Fatal("non-empty failure expanded recovery", calls, err)
			}
		})
	}
}

// A Connection header alone cannot prevent Go from reusing an HTTP/2 session.
// Verify that retry isolation works through the production transport layers,
// while successful playback continues to reuse the original HTTP/2 pool.
func TestHongguoPlaybackRetryOpensIsolatedConnection(t *testing.T) {
	var mu sync.Mutex
	var addresses []string
	var protocols []int
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		mu.Lock()
		addresses = append(addresses, request.RemoteAddr)
		protocols = append(protocols, request.ProtoMajor)
		call := len(addresses)
		mu.Unlock()
		if call != 2 {
			_, _ = io.WriteString(w, hongguoModelBatchFixture("800001"))
		}
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	clientCopy := *server.Client()
	client := &clientCopy
	base := client.Transport.(*http.Transport)
	client.Transport = &imageTransport{base: &huangguoBrowserTransport{base: &cdnTransport{base: base}}}
	defer base.CloseIdleConnections()
	d := rankingTestDownloader(t, nil)
	d.client, d.cfg.Retries = client, 2
	d.hongguoClient().baseURL = server.URL
	identity := hongguoPlayerIdentity{deviceID: "111001", installID: "222001", cdid: "fixture"}
	for range 3 {
		if _, err := d.hongguoRequest(context.Background(), http.MethodPost, "/novel/player/multi_video_model/v1/", nil, nil, 0, 0, &identity); err != nil {
			t.Fatal(err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(addresses) != 4 || addresses[0] != addresses[1] || addresses[0] != addresses[3] || addresses[2] == addresses[0] {
		t.Fatal("retry did not isolate its connection or disturbed the shared pool", addresses)
	}
	if !reflect.DeepEqual(protocols, []int{2, 2, 2, 2}) {
		t.Fatal("retry changed the supported playback protocols", protocols)
	}
}

func TestHongguoCatalogRetriesKeepSignedRoute(t *testing.T) {
	calls := 0
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.Host != "api5-normal-sinfonlineb.fqnovel.com" || request.Close || request.Header.Get("X-Gorgon") == "" {
			t.Error("player retry policy changed a signed catalog request")
		}
		if calls == 1 {
			return rankingHTTPResponse(request, http.StatusServiceUnavailable, ""), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, `{"code":0}`), nil
	})
	d.cfg.Retries = 2
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/reading/distribution/category/landpage/v/", nil, nil); err != nil || calls != 2 {
		t.Fatal("catalog retry budget changed", calls, err)
	}
}
