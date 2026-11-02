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
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func hongguoRecoveryTestDownloader(t *testing.T, transport rankingTransport) *Downloader {
	t.Helper()
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	d := c.downloader
	d.client = &http.Client{Transport: transport}
	d.limiter = newRequestLimiter(8, time.Nanosecond)
	return d
}

func hongguoRotatedDeviceFixture(attempt int) string {
	return fmt.Sprintf(`{"device_id_str":"33300000000000000%02d","install_id_str":"44400000000000000%02d"}`, attempt, attempt)
}

func primeHongguoIdentityFailure(t *testing.T, d *Downloader) hongguoPlayerLease {
	t.Helper()
	lease, err := d.hongguoPlaybackLease(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		d.hongguoPlaybackRoundFailed(lease, true)
	}
	return lease
}

func TestHongguoBlockedIdentityRecoversAfterTwoEmptyRounds(t *testing.T) {
	registrations, models := 0, 0
	var hosts, cdids []string
	d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
			profile := inspectHongguoRegistration(t, request)
			cdids = append(cdids, mapString(profile, "cdid"))
			if registrations == 2 && models != 8 {
				t.Error("identity changed before two complete empty rounds", models)
			}
			response := rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(registrations))
			response.Header.Add("Set-Cookie", fmt.Sprintf("ttreq=device-%d; Path=/", registrations))
			response.Header.Add("Set-Cookie", "sessionid=account-secret; Path=/")
			return response, nil
		}
		models++
		hosts = append(hosts, request.URL.Host)
		assertHongguoUnsignedPlaybackRequest(t, request)
		if request.Header.Get("Cookie") != fmt.Sprintf("ttreq=device-%d", registrations) {
			t.Error("playback mixed old identity or account cookies")
		}
		if request.URL.Query().Get("cdid") != cdids[registrations-1] {
			t.Error("replacement playback did not use the newly registered CDID")
		}
		if registrations == 1 {
			return rankingHTTPResponse(request, http.StatusOK, " \n\t"), nil
		}
		body, _ := json.Marshal(map[string]any{"data": map[string]any{"800001": map[string]any{"video_model": hongguoVideoModelFixture()}}})
		return rankingHTTPResponse(request, http.StatusOK, string(body)), nil
	})
	d.client.Jar, _ = cookiejar.New(nil)
	for _, host := range []string{hongguoAppBaseURL, "https://api5-normal-hl.fqnovel.com", "https://api5-normal-lf.fqnovel.com", "https://log5-applog-lf.fqnovel.com"} {
		address, _ := url.Parse(host)
		d.client.Jar.SetCookies(address, []*http.Cookie{{Name: "sessionid", Value: "account-secret"}})
	}
	media, err := d.resolveHongguoAppMedia(context.Background(), "800001")
	if err != nil || media.Quality != 1080 || hex.EncodeToString(media.CENCKey) != "00112233445566778899aabbccddeeff" {
		t.Fatal("blocked identity did not recover compatible encrypted media", err)
	}
	if registrations != 2 || models != 9 || cdids[0] == cdids[1] {
		t.Fatal("recovery changed the identity count, timing or CDID", registrations, models)
	}
	want := []string{"api5-normal-sinfonlineb.fqnovel.com", "api5-normal-hl.fqnovel.com", "api5-normal-lf.fqnovel.com", "api5-normal-sinfonlineb.fqnovel.com"}
	if !reflect.DeepEqual(hosts[:4], want) || !reflect.DeepEqual(hosts[4:8], want) {
		t.Fatal("identity recovery bypassed the complete route rounds", hosts)
	}
}

func TestHongguoIdentityRecoveryStopsWhenNewIdentityAlsoFails(t *testing.T) {
	registrations, models := 0, 0
	healthy := false
	d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
			return rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(registrations)), nil
		}
		models++
		if healthy {
			return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001")), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, ""), nil
	})
	for _, expected := range []int{12, 16} {
		if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); !errors.Is(err, errHongguoPlaybackRecoveryExhausted) {
			t.Fatal("persistent empty responses lost the bounded recovery failure", err)
		}
		if models != expected || registrations != 2 {
			t.Fatal("persistent outage caused more identity changes or unbounded requests", registrations, models)
		}
	}
	healthy = true
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
		t.Fatal(err)
	}
	// Only a valid current-identity media model grants recovery for a new period.
	lease := primeHongguoIdentityFailure(t, d)
	if changed, err := d.rotateHongguoPlaybackDevice(context.Background(), lease); err != nil || !changed || registrations != 3 {
		t.Fatal("successful playback did not reset the failure period", changed, registrations, err)
	}
}

func TestHongguoIdentityRecoveryRequiresEntirelyEmptyResponses(t *testing.T) {
	for _, failure := range []string{"mixed HTTP", "HTTP 503", "HTTP 403", "business", "invalid JSON", "missing episode"} {
		t.Run(failure, func(t *testing.T) {
			registrations, models := 0, 0
			d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/service/2/device_register/" {
					registrations++
					return rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(registrations)), nil
				}
				models++
				switch failure {
				case "mixed HTTP":
					if models != 2 {
						return rankingHTTPResponse(request, http.StatusOK, ""), nil
					}
					fallthrough
				case "HTTP 503":
					return rankingHTTPResponse(request, http.StatusServiceUnavailable, ""), nil
				case "HTTP 403":
					return rankingHTTPResponse(request, http.StatusForbidden, ""), nil
				case "business":
					return rankingHTTPResponse(request, http.StatusOK, `{"code":110001}`), nil
				case "invalid JSON":
					return rankingHTTPResponse(request, http.StatusOK, `{`), nil
				default:
					return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800002")), nil
				}
			})
			if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil {
				t.Fatal("accepted a failed or mismatched model")
			}
			want := 1
			if failure == "mixed HTTP" || failure == "HTTP 503" {
				want = 4
			}
			if registrations != 1 || models != want {
				t.Fatal("nonempty errors triggered identity recovery", registrations, models)
			}
		})
	}
}

func TestHongguoPrefetchDoesNotSpendIdentityRecovery(t *testing.T) {
	for _, upcoming := range [][]string{{"800002"}, nil} {
		t.Run(fmt.Sprint(len(upcoming)), func(t *testing.T) {
			registrations, models := 0, 0
			d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/service/2/device_register/" {
					registrations++
					return rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(registrations)), nil
				}
				models++
				return rankingHTTPResponse(request, http.StatusOK, ""), nil
			})
			// Last episodes and expired details can carry a background hint while
			// yielding no actual lookahead IDs. They still must not rotate.
			ctx := context.WithValue(context.Background(), hongguoMetadataAheadKey{}, 2)
			_, err := d.resolveHongguoAppMedia(ctx, "800001", upcoming...)
			wantEmpty := 4
			if len(upcoming) != 0 {
				wantEmpty = 3 // The remaining single-episode part of the batch budget.
			}
			if hongguoEmptyAttemptCount(err) != wantEmpty || models != 4 || registrations != 1 || d.hongguoClient().playerHealth.emptyRounds != 0 {
				t.Fatal("background metadata changed or consumed foreground recovery", models, registrations, err)
			}
		})
	}
}

func TestHongguoIdentityRotationFailureRetainsReadyIdentity(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusServiceUnavailable} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			registrations := 0
			d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				registrations++
				if registrations == 1 {
					return rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(1)), nil
				}
				return rankingHTTPResponse(request, status, `{}`), nil
			})
			old := primeHongguoIdentityFailure(t, d)
			if changed, err := d.rotateHongguoPlaybackDevice(context.Background(), old); changed || err == nil {
				t.Fatal("accepted an unsuccessful replacement registration", changed, err)
			}
			ready, err := d.hongguoPlaybackLease(context.Background())
			if err != nil || ready.identity != old.identity || registrations != 2 {
				t.Fatal("failed rotation discarded the ready identity or registered again", registrations, err)
			}
			if changed, err := d.rotateHongguoPlaybackDevice(context.Background(), old); changed || err != nil || registrations != 2 {
				t.Fatal("failed registration was retried in the same failure period", changed, registrations, err)
			}
		})
	}
}

func TestHongguoConcurrentIdentityRotationAndStaleModels(t *testing.T) {
	var registrations atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(unblock)
	d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		attempt := int(registrations.Add(1))
		if attempt == 2 {
			close(started)
			select {
			case <-release:
			case <-request.Context().Done():
				return nil, request.Context().Err()
			}
		}
		return rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(attempt)), nil
	})
	old := primeHongguoIdentityFailure(t, d)
	var oldResult map[string]any
	_ = json.Unmarshal([]byte(hongguoModelBatchFixture("800002")), &oldResult)
	d.keepHongguoUpcomingModels(oldResult, []string{"800002"}, old.identity)
	snapshot := d.hongguoCatalogSnapshot()
	var workers sync.WaitGroup
	results := make(chan error, 9)
	rotate := func() {
		defer workers.Done()
		changed, err := d.rotateHongguoPlaybackDevice(context.Background(), old)
		if err == nil && !changed {
			err = errors.New("waiting recovery did not receive a replacement identity")
		}
		results <- err
	}
	workers.Add(1)
	go rotate()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("replacement registration did not start")
	}
	// A reply already dispatched with the old identity may succeed during the
	// replacement registration; it must not grant a second replacement attempt.
	d.hongguoPlaybackModelSucceeded(old)
	for range 8 {
		workers.Add(1)
		go rotate()
	}
	ctx, cancel := context.WithCancel(context.Background())
	canceled := make(chan error, 1)
	go func() { _, err := d.hongguoPlaybackLease(ctx); canceled <- err }()
	cancel()
	if err := <-canceled; !errors.Is(err, context.Canceled) {
		t.Fatal("identity waiter did not cancel independently", err)
	}
	unblock()
	workers.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	if registrations.Load() != 2 {
		t.Fatal("concurrent failure reports caused repeated registrations", registrations.Load())
	}
	current, err := d.hongguoPlaybackLease(context.Background())
	if err != nil || current.identity == old.identity {
		t.Fatal("new requests did not use the replacement identity", err)
	}
	// Replies dispatched before rotation may finish, but cannot reset the new
	// identity's recovery budget or repopulate its cache with old-key models.
	d.hongguoPlaybackModelSucceeded(old)
	if retry, rotate := d.hongguoPlaybackRoundFailed(old, true); retry || rotate {
		t.Fatal("late old-identity failure changed current recovery state")
	}
	d.keepHongguoUpcomingModels(oldResult, []string{"800002"}, old.identity)
	if !d.hongguoPlaybackRecoveryAttempted(current) || d.takeHongguoUpcomingModel("800002") != nil {
		t.Fatal("late old-identity reply reset recovery or restored an invalidated cache")
	}
	if !reflect.DeepEqual(d.hongguoCatalogSnapshot(), snapshot) {
		t.Fatal("playback recovery changed persisted catalog state")
	}
	serialized, _ := json.Marshal(snapshot)
	for _, identity := range []hongguoPlayerIdentity{old.identity, current.identity} {
		if strings.Contains(string(serialized), identity.deviceID) || strings.Contains(string(serialized), identity.cdid) {
			t.Fatal("replacement playback identity leaked into catalog persistence")
		}
	}
}

func TestHongguoCanceledRotationDoesNotPublishIdentity(t *testing.T) {
	var registrations atomic.Int32
	started := make(chan struct{})
	d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		attempt := int(registrations.Add(1))
		if attempt == 2 {
			close(started)
			<-request.Context().Done()
			// Even an uncooperative transport's successful late reply is discarded.
		}
		return rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(attempt)), nil
	})
	old := primeHongguoIdentityFailure(t, d)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := d.rotateHongguoPlaybackDevice(ctx, old); done <- err }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("replacement registration did not start")
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal("rotation did not honor its owner cancellation", err)
	}
	ready, err := d.hongguoPlaybackLease(context.Background())
	if err != nil || ready.identity != old.identity {
		t.Fatal("canceled registration published a replacement", err)
	}
	if changed, err := d.rotateHongguoPlaybackDevice(context.Background(), ready); err != nil || !changed || registrations.Load() != 3 {
		t.Fatal("an active caller could not recover after a canceled owner", changed, err)
	}
}

func TestHongguoOnlyCurrentValidModelsResetIdentityRecovery(t *testing.T) {
	registrations := 0
	valid := false
	d := hongguoRecoveryTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
			return rankingHTTPResponse(request, http.StatusOK, hongguoRotatedDeviceFixture(registrations)), nil
		}
		if valid {
			return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001")), nil
		}
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800002")), nil
	})
	old := primeHongguoIdentityFailure(t, d)
	if changed, err := d.rotateHongguoPlaybackDevice(context.Background(), old); err != nil || !changed {
		t.Fatal(err)
	}
	rotated, _ := d.hongguoPlaybackLease(context.Background())
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || !d.hongguoPlaybackRecoveryAttempted(rotated) {
		t.Fatal("a different episode's model reset the registration allowance", err)
	}
	valid = true
	if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err != nil {
		t.Fatal(err)
	}
	current, _ := d.hongguoPlaybackLease(context.Background())
	if retry, _ := d.hongguoPlaybackRoundFailed(rotated, true); retry {
		t.Fatal("a failure dispatched before successful playback started a new recovery")
	}
	d.hongguoPlaybackRoundFailed(current, true)
	d.hongguoPlaybackModelSucceeded(rotated)
	if changed, err := d.rotateHongguoPlaybackDevice(context.Background(), current); err != nil || changed {
		t.Fatal("a late successful reply bypassed the two-empty-round threshold", err)
	}
	if retry, rotate := d.hongguoPlaybackRoundFailed(current, true); !retry || !rotate {
		t.Fatal("a late success incorrectly reset the new failure evidence")
	}
}
