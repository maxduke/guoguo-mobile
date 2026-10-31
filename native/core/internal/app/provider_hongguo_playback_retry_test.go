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
			var hosts []string
			d.client = &http.Client{Transport: rankingTransport(func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/service/2/device_register/" {
					registrations++
					return rankingHTTPResponse(request, http.StatusOK, hongguoDeviceFixture), nil
				}
				assertHongguoUnsignedPlaybackRequest(t, request)
				hosts = append(hosts, request.URL.Host)
				if outcome == "cancel" {
					cancel()
				}
				if outcome == "recover" && len(hosts) == 4 {
					return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001")), nil
				}
				return rankingHTTPResponse(request, http.StatusOK, ""), nil
			})}
			if outcome == "recover" {
				_, err = c.Call(`{"method":"resolve","id":"hongguo:700001","chapter":{"id":"one","videoUrl":"hongguo-cenc://800001"}}`)
				if err != nil {
					t.Fatal("mobile playback did not reach the fourth permitted route", err)
				}
			} else {
				_, err = d.resolveHongguoAppMedia(ctx, "800001")
				if err == nil || outcome == "cancel" && !errors.Is(err, context.Canceled) {
					t.Fatal("mobile playback ignored exhaustion or cancellation", err)
				}
			}
			want := []string{"api5-normal-sinfonlineb.fqnovel.com", "api5-normal-hl.fqnovel.com", "api5-normal-lf.fqnovel.com", "api5-normal-sinfonlineb.fqnovel.com"}
			if outcome == "cancel" {
				want = want[:1]
			}
			if !reflect.DeepEqual(hosts, want) || registrations != 1 || d.hongguoRequestAttempts() != 2 {
				t.Fatal("playback changed the route/count, registered again, or changed the general request budget", hosts, registrations)
			}
		})
	}
}

func TestHongguoPlaybackRotatesRoutesWithinBudget(t *testing.T) {
	for _, failure := range []string{"empty", "HTTP 503", "connection", "body read"} {
		t.Run(failure, func(t *testing.T) {
			var hosts []string
			var identities [][3]string
			d := hongguoRegisteredMediaDownloader(t, func(request *http.Request) (*http.Response, error) {
				assertHongguoUnsignedPlaybackRequest(t, request)
				hosts = append(hosts, request.URL.Host)
				query := request.URL.Query()
				identities = append(identities, [3]string{query.Get("device_id"), query.Get("iid"), query.Get("cdid")})
				if request.Close != (len(hosts) > 1) {
					t.Error("only playback retries should request an unpooled connection")
				}
				if len(hosts) == 3 {
					return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001")), nil
				}
				switch failure {
				case "HTTP 503":
					return rankingHTTPResponse(request, http.StatusServiceUnavailable, ""), nil
				case "connection":
					return nil, errors.New("fixture connection failed")
				case "body read":
					response := rankingHTTPResponse(request, http.StatusOK, "")
					response.Body = io.NopCloser(iotest.ErrReader(errors.New("fixture read failed")))
					return response, nil
				default:
					return rankingHTTPResponse(request, http.StatusOK, " \n\t"), nil
				}
			})
			d.cfg.Retries = 3
			if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
				t.Fatal("playback did not recover within the existing budget", err)
			}
			want := []string{"api5-normal-sinfonlineb.fqnovel.com", "api5-normal-hl.fqnovel.com", "api5-normal-lf.fqnovel.com"}
			if !reflect.DeepEqual(hosts, want) {
				t.Fatal("playback retried the same route or exceeded its budget", hosts)
			}
			if identities[0] != identities[1] || identities[0] != identities[2] {
				t.Fatal("changing playback routes changed the registered device")
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
	d.hongguoClient().player = hongguoPlayerIdentity{deviceID: "111001", installID: "222001", cdid: "fixture"}
	for range 3 {
		if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
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
