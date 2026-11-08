package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"testing"
)

func TestHongguoSingleUseIdentityAcrossEpisodes(t *testing.T) {
	registrations := 0
	used := map[string]bool{}
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
			return rankingHTTPResponse(request, http.StatusOK, fmt.Sprintf(`{"device_id":"%d","install_id":"%d"}`, 100000+registrations, 200000+registrations)), nil
		}
		assertHongguoSignedPlaybackRequest(t, request)
		id := request.URL.Query().Get("device_id")
		if used[id] {
			return rankingHTTPResponse(request, http.StatusOK, ""), nil
		}
		used[id] = true
		return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001", "800002", "800003")), nil
	})
	for _, id := range []string{"800001", "800002", "800003"} {
		if _, err := d.resolveHongguoAppMedia(context.Background(), id); err != nil {
			t.Fatal("next episode reused single-use identity", err)
		}
	}
	if registrations != 3 {
		t.Fatal("each uncached resolve needs its own registration", registrations)
	}
}

func TestHongguoEmptyForegroundRecoveryIsBounded(t *testing.T) {
	for _, recover := range []bool{false, true} {
		t.Run(fmt.Sprint(recover), func(t *testing.T) {
			registrations, models := 0, 0
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/service/2/device_register/" {
					registrations++
					return rankingHTTPResponse(request, http.StatusOK, fmt.Sprintf(`{"device_id":"%d","install_id":"%d"}`, 100000+registrations, 200000+registrations)), nil
				}
				models++
				if recover && registrations == 2 {
					return rankingHTTPResponse(request, http.StatusOK, hongguoModelBatchFixture("800001")), nil
				}
				return rankingHTTPResponse(request, http.StatusOK, ""), nil
			})
			d.cfg.hongguoPlayerAttempts = 4
			_, err := d.resolveHongguoAppMedia(context.Background(), "800001")
			wantModels := 8
			if recover {
				wantModels = 5
			}
			if recover && err != nil || !recover && !errors.Is(err, errHongguoPlaybackRecoveryExhausted) || registrations != 2 || models != wantModels {
				t.Fatal("unexpected recovery result", err, registrations, models)
			}
		})
	}
}

func TestHongguoRecoveryDoesNotReregisterNonEmptyErrors(t *testing.T) {
	for _, outcome := range []struct {
		name   string
		status int
		body   string
	}{
		{"HTTP denied", 403, ""}, {"rate limited", 429, ""}, {"business", 200, `{"code":110001}`}, {"malformed", 200, "{"}, {"wrong episode", 200, hongguoModelBatchFixture("800002")},
	} {
		t.Run(outcome.name, func(t *testing.T) {
			registrations, models := 0, 0
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/service/2/device_register/" {
					registrations++
					return rankingHTTPResponse(request, 200, hongguoDeviceFixture), nil
				}
				models++
				return rankingHTTPResponse(request, outcome.status, outcome.body), nil
			})
			d.cfg.hongguoPlayerAttempts = 4
			if _, err := d.resolveHongguoAppMedia(context.Background(), "800001"); err == nil || registrations != 1 || models != 1 {
				t.Fatal("nonempty failure triggered recovery", err, registrations, models)
			}
		})
	}
}

func TestHongguoRecoveryCancellationStopsReplacement(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	registrations, models := 0, 0
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registrations++
			return rankingHTTPResponse(request, 200, hongguoDeviceFixture), nil
		}
		models++
		cancel()
		return rankingHTTPResponse(request, 200, ""), nil
	})
	d.cfg.hongguoPlayerAttempts = 4
	if _, err := d.resolveHongguoAppMedia(ctx, "800001"); !errors.Is(err, context.Canceled) || registrations != 1 || models != 1 {
		t.Fatal("cancellation did not stop model work", err, registrations, models)
	}
}
