package app

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const huangguoBrokenPage = `{"items":[],"pagination":{"page":1,"pages":2}}`

func huangguoAutomaticFixture(t *testing.T, handler func(*http.Request) (*http.Response, error)) *Downloader {
	t.Helper()
	d := rankingTestDownloader(t, handler)
	d.cfg.HuangguoAIURL = ""
	d.huangguoAIRoutes = []string{"https://first.example.org", "https://second.example.org", "https://third.example.org"}
	d.huangguoAIRouteChecked = true
	d.providerHosts[sourceHuangguoAI] = d.huangguoAIRoutes[0]
	return d
}

func TestHuangguoAPIRecoversMalformedPageAndRemembersValidatedLine(t *testing.T) {
	var hosts []string
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		hosts = append(hosts, request.URL.Host)
		if !strings.HasPrefix(huangguoEnvelopePath(t, request), "/api/search?") {
			t.Error("recovery changed request kind")
		}
		if request.URL.Host == "first.example.org" {
			return huangguoAPIResponse(request, huangguoBrokenPage), nil
		}
		return huangguoAPIResponse(request, huangguoAPIPageFixture), nil
	})
	for range 2 {
		items, more, err := d.searchHuangguoAI(context.Background(), "测试", 1)
		if err != nil || len(items) != 1 || !more || bestDramaCover(items[0]) != "https://second.example.org/cover.enc" {
			t.Fatalf("recovery lost the validated route or data: %+v %t %v", items, more, err)
		}
	}
	if strings.Join(hosts, ",") != "first.example.org,second.example.org,second.example.org" {
		t.Fatal("did not reuse the validated route", hosts)
	}
}

func TestHuangguoAPIRecoveryStopsAfterTwoInvalidPages(t *testing.T) {
	var calls atomic.Int32
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		huangguoEnvelopePath(t, request)
		return huangguoAPIResponse(request, huangguoBrokenPage), nil
	})
	_, _, err := d.searchHuangguoAI(context.Background(), "测试", 1)
	if !errors.Is(err, errHuangguoAPIInvalid) || calls.Load() != 2 {
		t.Fatal("invalid pages restarted HTML or extra route attempts", calls.Load(), err)
	}
}

func TestHuangguoAPIRecoveryDoesNotRetryRejectionOrEmptySearch(t *testing.T) {
	for _, status := range []int{200, 401, 403, 429} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			var calls atomic.Int32
			d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
				calls.Add(1)
				huangguoEnvelopePath(t, request)
				if status == 200 {
					return huangguoAPIResponse(request, `{"items":[],"pagination":{"page":1,"pages":0}}`), nil
				}
				return rankingHTTPResponse(request, status, "rejected"), nil
			})
			items, more, err := d.searchHuangguoAI(context.Background(), "测试", 1)
			if calls.Load() != 1 || (err == nil) != (status == 200) || len(items) != 0 || more {
				t.Fatal("rejection or valid empty search was retried", calls.Load(), err)
			}
		})
	}
}

func TestHuangguoAPIRecoveryCannotHideWrongEpisode(t *testing.T) {
	var calls atomic.Int32
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		huangguoEnvelopePath(t, request)
		return huangguoAPIResponse(request, `{"id":501,"ep_num":2,"video_url":"https://media.example.org/a.m3u8"}`), nil
	})
	_, _, err := d.huangguoAPIPlayback(context.Background(), "501", "3")
	if !errors.Is(err, errHuangguoAPIInvalid) || calls.Load() != 1 {
		t.Fatal("wrong episode was hidden by recovery", calls.Load(), err)
	}
}

func TestHuangguoAPIRecoveryKeepsPlaybackOrigin(t *testing.T) {
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		huangguoEnvelopePath(t, request)
		if request.URL.Host == "first.example.org" {
			return rankingHTTPResponse(request, 500, "temporary"), nil
		}
		return huangguoAPIResponse(request, `{"id":501,"ep_num":3,"video_url":"/a.m3u8"}`), nil
	})
	media, base, err := d.huangguoAPIPlayback(context.Background(), "501", "3")
	if err != nil || base != "https://second.example.org" || media != base+"/a.m3u8" {
		t.Fatal("recovered media lost its actual origin", media, base, err)
	}
}

func TestHuangguoAPILateRecoveryCannotReplaceANewManualChoice(t *testing.T) {
	started, finish := make(chan struct{}), make(chan struct{})
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		huangguoEnvelopePath(t, request)
		if request.URL.Host == "first.example.org" {
			return huangguoAPIResponse(request, huangguoBrokenPage), nil
		}
		close(started)
		select {
		case <-finish:
		case <-request.Context().Done():
			return nil, request.Context().Err()
		}
		return huangguoAPIResponse(request, huangguoAPIPageFixture), nil
	})
	done := make(chan error, 1)
	go func() { _, _, err := d.searchHuangguoAI(context.Background(), "测试", 1); done <- err }()
	<-started
	if _, err := d.selectHuangguoLine(context.Background(), "https://third.example.org"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.selectHuangguoLine(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	close(finish)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if d.providerHosts[sourceHuangguoAI] != "https://first.example.org" || d.huangguoLine != "" {
		t.Fatal("late response replaced the subsequent routing choice")
	}
}

func TestHuangguoPinnedSearchHTMLFallbackStaysOnTheSelectedLine(t *testing.T) {
	var calls atomic.Int32
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		if request.URL.Host != "second.example.org" {
			t.Error("manual HTML fallback used another line", request.URL)
		}
		if request.URL.Path == "/api/edge/request" {
			return rankingHTTPResponse(request, 404, "old API"), nil
		}
		return rankingHTTPResponse(request, 200, `<div class="hg-search-results"><a href="/video/501/" title="测试作品">测试作品</a></div>`), nil
	})
	d.huangguoLine = "https://second.example.org"
	items, _, err := d.searchHuangguoAI(context.Background(), "测试", 1)
	if err != nil || len(items) != 1 || calls.Load() != 2 {
		t.Fatal("manual fallback was lost or switched routes", items, calls.Load(), err)
	}
}

func TestHuangguoAPIRecoveryRespectsCancellationAndDeadline(t *testing.T) {
	var calls atomic.Int32
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		<-request.Context().Done()
		return nil, request.Context().Err()
	})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, _, err := d.searchHuangguoAI(ctx, "测试", 1)
	if !errors.Is(err, context.DeadlineExceeded) || calls.Load() != 1 {
		t.Fatal("cancelled read restarted on another line", calls.Load(), err)
	}
}

func TestHuangguoRouteRefreshRetainsKnownWorkingPreference(t *testing.T) {
	d := huangguoAutomaticFixture(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Host != "huangguoai.ai" {
			t.Error("route refresh did unexpected probing", request.URL)
		}
		return rankingHTTPResponse(request, 200, `<a data-url="https://first.example.org">一</a><a data-url="https://second.example.org">二</a>`), nil
	})
	d.providerHosts[sourceHuangguoAI] = "https://second.example.org"
	if routes := d.discoverHuangguoAIRoutes(context.Background(), true); len(routes) != 2 || d.providerHosts[sourceHuangguoAI] != "https://second.example.org" {
		t.Fatal("refresh discarded the working preference", routes)
	}
}
