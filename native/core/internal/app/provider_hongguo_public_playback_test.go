package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

const hongguoPublicFixtureMP4 = "https://v3-hgweb.qznovelvod.com/video.mp4?ticket=fixture"

func TestHongguoPublicPlaybackFromMobileResolveAndDownloadPlan(t *testing.T) {
	client := newSourceMobileClient(t)
	d := client.downloader
	d.cfg.hongguoPlayerAttempts = 1
	d.limiter.configure(1, 0)
	expires := time.Now().Add(time.Minute).Truncate(time.Second)
	var calls []string
	d.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
		calls = append(calls, r.URL.Path)
		switch r.URL.Path {
		case "/service/2/device_register/":
			return rankingHTTPResponse(r, 200, `{"device_id_str":"900001","install_id_str":"900002"}`), nil
		case hongguoVideoTabPath:
			return rankingHTTPResponse(r, 200, ""), nil
		case hongguoPublicPlaybackPath:
			body, _ := io.ReadAll(r.Body)
			if r.Method != http.MethodPost || r.URL.Host != "hongguoduanju.com" || r.URL.RawQuery != "" ||
				string(body) != `{"item_id":"800001"}` || r.Header.Get("Cookie") != "" ||
				r.Context().Value(hongguoPublicPlaybackRequestKey{}) != true {
				t.Error("the public playback request lost its episode or anonymous route")
			}
			return rankingHTTPResponse(r, 200, fmt.Sprintf(`{"base_resp":{"StatusCode":0},"main_url":%q,"url_expire":%d}`, hongguoPublicFixtureMP4, expires.Unix())), nil
		default:
			return rankingHTTPResponse(r, 404, ""), nil
		}
	})
	request := map[string]any{
		"method": "resolve", "id": "hongguo:700001", "traceId": "public-playback",
		"chapter": map[string]string{"id": "first", "videoUrl": "hongguo-cenc://800001"},
	}
	play := callNewMobileSource(t, client, request)
	if play["quality"] != float64(360) || play["expiresAt"] != float64(expires.UnixMilli()) ||
		play["contentKey"] != "" || !strings.HasPrefix(play["url"].(string), "http://127.0.0.1:") {
		t.Fatalf("unexpected public playback session: %+v", play)
	}
	callNewMobileSource(t, client, map[string]any{"method": "release", "id": play["session"]})
	diagnostic := callNewMobileSource(t, client, map[string]any{"method": "requestDiagnostic", "traceId": "public-playback"})["diagnostic"].(map[string]any)
	if diagnostic["sourceStage"] != "public_playback" || diagnostic["httpStatus"] != float64(200) {
		t.Fatalf("incorrect playback diagnostics: %+v", diagnostic)
	}

	request["method"] = "downloadPlan"
	plan := callNewMobileSource(t, client, request)
	if plan["refreshOnResume"] != true || plan["process"] != false || len(plan["assets"].([]any)) != 1 {
		t.Fatalf("public download lost its refresh contract: %+v", plan)
	}
	request["method"], request["quality"] = "resolve", 720
	calls = nil
	raw, _ := json.Marshal(request)
	if _, err := client.Call(string(raw)); err == nil {
		t.Fatal("fixed 720p should not select only the public 360p fallback")
	}
	for _, path := range calls {
		if path == hongguoPublicPlaybackPath {
			t.Fatal("fixed 720p queried the 360p endpoint")
		}
	}
}

func TestHongguoPublicPlaybackDenialScope(t *testing.T) {
	for _, sample := range []struct {
		name, body       string
		status           int
		episodeOnly      bool
		expectedRequests int
	}{
		{"episode access", `{"error":"public_fallback_unavailable"}`, 403, true, 2},
		{"site forbid", `{}`, 403, false, 1},
		{"site challenge", `<title>Just a moment</title>cloudflare`, 200, false, 1},
		{"rate limit", `{}`, 429, false, 1},
	} {
		t.Run(sample.name, func(t *testing.T) {
			d := newSourceMobileClient(t).downloader
			requests := 0
			d.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
				requests++
				return rankingHTTPResponse(r, sample.status, sample.body), nil
			})
			for _, id := range []string{"800001", "800002"} {
				_, err := d.resolveHongguoPublicMedia(context.Background(), id)
				want := errHongguoPublicPlaybackDenied
				if sample.episodeOnly {
					want = errHongguoPublicEpisodeUnavailable
				}
				if !errors.Is(err, want) || isHongguoSourceRefusal(err) {
					t.Fatalf("wrong denial scope: %v", err)
				}
			}
			if requests != sample.expectedRequests {
				t.Fatalf("public endpoint called %d times, want %d", requests, sample.expectedRequests)
			}
		})
	}
}

func TestHongguoPublicPlaybackRejectsUnusableResponse(t *testing.T) {
	for _, sample := range []struct {
		name, episode, address string
		expiry                 time.Duration
		status                 int
	}{
		{"other episode", "800002", hongguoPublicFixtureMP4, time.Minute, 200},
		{"expired", "800001", hongguoPublicFixtureMP4, -time.Second, 200},
		{"nearly expired", "800001", hongguoPublicFixtureMP4, time.Second, 200},
		{"wrong domain", "800001", "https://qznovelvod.com.example.org/x.mp4", time.Minute, 200},
		{"private network", "800001", "https://192.168.1.2/x.mp4", time.Minute, 200},
		{"redirect", "800001", hongguoPublicFixtureMP4, time.Minute, 302},
	} {
		t.Run(sample.name, func(t *testing.T) {
			d := newSourceMobileClient(t).downloader
			calls := 0
			d.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
				calls++
				body := fmt.Sprintf(`{"base_resp":{"StatusCode":0},"item_id":%q,"main_url":%q,"url_expire":%d}`,
					sample.episode, sample.address, time.Now().Add(sample.expiry).Unix())
				response := rankingHTTPResponse(r, sample.status, body)
				response.Header.Set("Location", "https://elsewhere.example.org/play")
				return response, nil
			})
			if _, err := d.resolveHongguoPublicMedia(context.Background(), "800001"); err == nil || calls != 1 {
				t.Fatalf("accepted an invalid playback reply or followed a redirect: %v, calls=%d", err, calls)
			}
		})
	}
}

func TestHongguoPublicPlaybackTransportChecksExactPostAndPublicDNS(t *testing.T) {
	base := http.DefaultTransport.(*http.Transport).Clone()
	transport := newImageTransport(base, base)
	transport.fallback = nil
	for _, sample := range []struct {
		method, address string
		lookup          bool
	}{
		{http.MethodPost, hongguoBaseURL + hongguoPublicPlaybackPath, true},
		{http.MethodPost, "https://remote.example.org" + hongguoPublicPlaybackPath, false},
		{http.MethodPost, hongguoBaseURL + "/api/other", false},
		{http.MethodGet, hongguoBaseURL + hongguoPublicPlaybackPath, false},
	} {
		lookup := false
		transport.lookup = func(context.Context, string) ([]string, error) {
			lookup = true
			return []string{"127.0.0.1"}, nil
		}
		ctx := context.WithValue(context.Background(), hongguoPublicPlaybackRequestKey{}, true)
		request, err := http.NewRequestWithContext(ctx, sample.method, sample.address, strings.NewReader("{}"))
		if err != nil {
			t.Fatal(err)
		}
		if response, err := transport.RoundTrip(request); response != nil || err == nil || lookup != sample.lookup {
			t.Fatalf("unexpected admission for %s %s: lookup=%v error=%v", sample.method, sample.address, lookup, err)
		}
	}
}
