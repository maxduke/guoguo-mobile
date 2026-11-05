package app

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const huangguoAPIPageFixture = `{"items":[{"id":501,"title":"测试作品","cover":"/cover.enc","episode_count":3,"total_episodes":8,"hot":123,"is_finished":true,"author":{"id":12345,"name":"不是作品"}}],"pagination":{"page":1,"pages":2}}`

func huangguoAPIResponse(request *http.Request, data string) *http.Response {
	return rankingHTTPResponse(request, 200, `{"status":1,"data":`+data+`}`)
}

func huangguoEnvelopePath(t *testing.T, request *http.Request) string {
	t.Helper()
	var envelope map[string]string
	if request.Method != http.MethodPost || request.URL.Path != "/api/edge/request" || json.NewDecoder(request.Body).Decode(&envelope) != nil || envelope["method"] != "GET" || envelope["body"] != "" || envelope["content_type"] != "" {
		t.Errorf("invalid anonymous read envelope: %s %s", request.Method, request.URL.Path)
	}
	if request.Header.Get("Cookie") != "" || request.Header.Get("Authorization") != "" || request.Header.Get("Content-Type") != "application/json" {
		t.Error("API inherited account credentials or lost its content type")
	}
	return envelope["path"]
}

func TestHuangguoAPISearchPreservesIdentityAndLiteralQuery(t *testing.T) {
	const base = "https://api-huangguo.example.org"
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		path := huangguoEnvelopePath(t, request)
		u, _ := url.Parse(path)
		if u.Path != "/api/search" || u.Query().Get("q") != "AI & 测试/词" || u.Query().Get("page") != "1" || request.Header.Get("Referer") != base+"/" {
			t.Error("search lost its literal query or route")
		}
		return huangguoAPIResponse(request, huangguoAPIPageFixture), nil
	})
	d.cfg.HuangguoAIURL = base
	d.client.Jar, _ = cookiejar.New(nil)
	address, _ := url.Parse(base)
	d.client.Jar.SetCookies(address, []*http.Cookie{{Name: "account", Value: "private"}})
	d.cfg.Token = "private"
	rows, more, err := d.searchHuangguoAI(context.Background(), "AI & 测试/词", 1)
	if err != nil || !more || len(rows) != 1 || rows[0].ID != "huangguoai:501" || rows[0].Source != sourceHuangguoAI || rows[0].Heat != "123" || rows[0].ReleaseStatus != "finished" {
		t.Fatalf("API search changed metadata or identities: rows=%+v more=%t err=%v", rows, more, err)
	}
}

func TestHuangguoAPIDetailKeepsLegacyEpisodeKeysAndSparseNumbers(t *testing.T) {
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if huangguoEnvelopePath(t, request) != "/api/videos/501" {
			t.Error("wrong detail target")
		}
		return huangguoAPIResponse(request, `{"id":501,"title":"测试作品","episode_count":3,"episodes":[{"ep_num":3,"title":"第三集"},{"ep_num":1,"title":"第一集"}]}`), nil
	})
	d.cfg.HuangguoAIURL = "https://api-huangguo.example.org"
	drama, chapters, err := d.fetchHuangguoAIDetail(context.Background(), "501")
	if err != nil || drama.ID != "huangguoai:501" || len(chapters) != 2 || chapters[0].ID != "huangguoai:501:1" || chapters[1].ID != "huangguoai:501:ep-3" || chapters[1].EpisodeString(0) != "3" || !strings.HasSuffix(chapters[1].PageURL, "/video/501/ep-3/") {
		t.Fatalf("detail changed episode identity or filled missing episodes: %+v %v", chapters, err)
	}
}

func TestHuangguoAPIPlaybackRejectsWrongIdentityWithoutHTMLFallback(t *testing.T) {
	for _, data := range []string{
		`{"id":502,"ep_num":3,"video_url":"https://media.example.org/a.mp4"}`,
		`{"id":501,"ep_num":2,"video_url":"https://media.example.org/a.mp4"}`,
		`{"id":501,"ep_num":3,"video_url":"javascript:private"}`,
	} {
		t.Run(data, func(t *testing.T) {
			var calls atomic.Int32
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls.Add(1)
				if huangguoEnvelopePath(t, request) != "/api/videos/501/play?ep=3&page_texts=0" {
					t.Error("wrong episode target")
				}
				return huangguoAPIResponse(request, data), nil
			})
			d.cfg.HuangguoAIURL = "https://api-huangguo.example.org"
			_, err := d.resolveProviderMedia(context.Background(), Task{DramaID: "huangguoai:501", Chapter: Chapter{ID: "huangguoai:501:ep-3", CurrentEpisode: rawEpisode(3)}})
			if err == nil || calls.Load() != 1 {
				t.Fatalf("accepted or hid wrong playback identity: calls=%d err=%v", calls.Load(), err)
			}
		})
	}
}

func TestHuangguoAPIPlaybackUsesSelectedRouteAndExistingHLSPath(t *testing.T) {
	const base = "https://selected-huangguo.example.org"
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		if request.URL.Host == "media.example.org" {
			if request.Header.Get("Referer") != base+"/" {
				t.Error("media lost selected route referer")
			}
			return rankingHTTPResponse(request, 200, "#EXTM3U\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n"), nil
		}
		if request.URL.Host != "selected-huangguo.example.org" || huangguoEnvelopePath(t, request) != "/api/videos/501/play?ep=3&page_texts=0" {
			t.Error("playback used stale page or route")
		}
		return huangguoAPIResponse(request, `{"id":501,"ep_num":3,"video_url":"https://media.example.org/a.m3u8"}`), nil
	})
	d.huangguoLine = base
	media, err := d.resolveProviderMedia(context.Background(), Task{DramaID: "huangguoai:501", Chapter: Chapter{ID: "huangguoai:501:ep-3", CurrentEpisode: rawEpisode(3), PageURL: "https://old-huangguo.example.org/video/501/ep-3/"}})
	if err != nil || media.Playlist == "" || media.Duration != 4*time.Second || media.Referer != base+"/" || calls.Load() != 2 {
		t.Fatalf("API playback bypassed existing media handling: %+v err=%v calls=%d", media, err, calls.Load())
	}
}

func TestHuangguoAPIUnsupportedAndBlockedResponsesHaveBoundedFallback(t *testing.T) {
	for _, status := range []int{404, 403, 429} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			var calls atomic.Int32
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls.Add(1)
				return rankingHTTPResponse(request, status, "private response"), nil
			})
			for i := 0; i < 2; i++ {
				_, err := d.requestHuangguoAPI(context.Background(), "https://api-huangguo.example.org", "/api/videos", false)
				if err == nil || huangguoAPICanFallback(context.Background(), err) != (status == 404) {
					t.Fatal("wrong fallback policy", err)
				}
			}
			want := int32(1) // 404 capability cache; 403/429 existing limiter backoff.
			if calls.Load() != want {
				t.Fatalf("repeated unsupported or blocked request: %d", calls.Load())
			}
		})
	}
}

func TestHuangguoAPICancellationDoesNotStartHTMLFallback(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		cancel()
		return nil, request.Context().Err()
	})
	d.cfg.HuangguoAIURL = "https://api-huangguo.example.org"
	_, _, err := d.searchHuangguoAI(ctx, "测试", 1)
	if !errors.Is(err, context.Canceled) || calls.Load() != 1 {
		t.Fatal("cancelled search restarted", err)
	}
}

func TestHuangguoAPIMalformedPagesAreNotTreatedAsEmptySuccess(t *testing.T) {
	for _, body := range []string{
		`{"items":[],"pagination":{"page":2,"pages":2}}`,
		`{"items":[],"pagination":{"page":1,"pages":2}}`,
		`{"items":[{"id":501,"author":{"name":"作者"}}],"pagination":{"page":1,"pages":1}}`,
		`{"pagination":{"page":1,"pages":1}}`,
	} {
		if _, _, err := parseHuangguoAPIPage([]byte(body), "https://api-huangguo.example.org", "", 1); err == nil {
			t.Fatalf("accepted malformed API page: %s", body)
		}
	}
	rows, more, err := parseHuangguoAPIPage([]byte(`{"items":[],"pagination":{"page":1,"pages":0}}`), "https://api-huangguo.example.org", "", 1)
	if err != nil || len(rows) != 0 || more {
		t.Fatal("valid empty search failed", err)
	}
}

func TestHuangguoAPIRankingKeepsOfficialOrderAndCovers(t *testing.T) {
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if huangguoEnvelopePath(t, request) != "/api/ranks/hot" {
			t.Error("wrong ranking")
		}
		return huangguoAPIResponse(request, `{"type":"hot","items":[{"rank":2,"video_id":501,"title":"测试作品","cover":"/poster.enc","metric_label":"播放","metric_value":128},{"rank":4,"video_id":502,"title":"另一作品"}]}`), nil
	})
	d.cfg.HuangguoAIURL = "https://api-huangguo.example.org"
	board, _ := findRankingBoard("huangguo-hot")
	page, err := d.fetchHuangguoRankingPage(context.Background(), board)
	if err != nil || len(page.Items) != 2 || page.Items[0].Rank != 2 || page.Items[1].Rank != 4 || page.Items[0].Drama.ID != "huangguoai:501" || bestDramaCover(page.Items[0].Drama) != d.cfg.HuangguoAIURL+"/poster.enc" || page.HasMore {
		t.Fatalf("ranking lost upstream order or identity: %+v err=%v", page, err)
	}
}

func TestMobileHuangguoMetadataAndChaptersUseTheJSONAdapter(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	d := c.downloader
	d.cfg.HuangguoAIURL = "https://api-huangguo.example.org"
	d.limiter = newRequestLimiter(2, time.Nanosecond)
	var calls atomic.Int32
	d.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		if huangguoEnvelopePath(t, request) != "/api/videos/9007199254740993" {
			t.Error("large ID lost precision")
		}
		return huangguoAPIResponse(request, `{"id":9007199254740993,"title":"完整资料","cover":"/poster.enc","description":"简介","tags":["都市"],"counts":{"hot":123},"episode_count":2,"episodes":[{"ep_num":1},{"ep_num":2}]}`), nil
	})
	raw, err := c.Call(`{"method":"detail","id":"huangguoai:9007199254740993"}`)
	var detail struct {
		Item struct {
			ID, Description, Cover, Category, Heat string
			Tags                                   []string
		}
	}
	if err != nil || json.Unmarshal([]byte(raw), &detail) != nil || detail.Item.ID != "huangguoai:9007199254740993" || detail.Item.Description != "简介" || detail.Item.Category != "" || detail.Item.Heat != "123" || len(detail.Item.Tags) != 1 {
		t.Fatal("mobile metadata bypassed the API adapter", raw, err)
	}
	raw, err = c.Call(`{"method":"chapters","id":"huangguoai:9007199254740993"}`)
	var chapters struct{ Chapters []Chapter }
	if err != nil || json.Unmarshal([]byte(raw), &chapters) != nil || len(chapters.Chapters) != 2 || chapters.Chapters[1].ID != "huangguoai:9007199254740993:ep-2" || calls.Load() != 2 {
		t.Fatal("mobile chapters changed identity or bypassed the API", raw, err)
	}
}

func TestHuangguoAPIReadDoesNotFollowRedirects(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		if request.URL.Host != "api-huangguo.example.org" {
			t.Error("API followed a foreign redirect")
		}
		response := rankingHTTPResponse(request, 307, "")
		response.Header.Set("Location", "https://foreign.example.org/api/edge/request")
		return response, nil
	})
	_, err := d.requestHuangguoAPI(context.Background(), "https://api-huangguo.example.org", "/api/videos", false)
	if err == nil || calls.Load() != 1 {
		t.Fatal("redirect was followed or accepted", err)
	}
}

func TestHuangguoAPIPinnedTransportRejectsReservedDNSBeforeConnecting(t *testing.T) {
	var dials, fallbacks atomic.Int32
	standard := http.DefaultTransport.(*http.Transport).Clone()
	standard.Proxy = nil
	standard.TLSClientConfig = &tls.Config{}
	standard.DialContext = func(context.Context, string, string) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("must not connect")
	}
	transport := newImageTransport(standard, standard)
	transport.lookup = func(context.Context, string) ([]string, error) { return []string{"198.18.0.1"}, nil }
	transport.fallback = func(context.Context, string) ([]string, error) { fallbacks.Add(1); return []string{"192.168.1.1"}, nil }
	d := rankingTestDownloader(t, nil)
	d.client.Transport = transport
	_, err := d.requestHuangguoAPI(context.Background(), "https://api-huangguo.example.org", "/api/videos", false)
	if err == nil || dials.Load() != 0 || fallbacks.Load() != 1 {
		t.Fatal("API bypassed public DNS validation", err)
	}
}
