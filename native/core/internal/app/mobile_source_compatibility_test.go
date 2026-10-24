package app

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"net/http"
	"strings"
	"testing"

	fhttp "github.com/bogdanfinn/fhttp"
)

func TestMobileDSDCoverKeepsPageClientIdentity(t *testing.T) {
	var art bytes.Buffer
	if err := png.Encode(&art, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	requests := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		requests++
		if r.URL.Host != "images.example.org" || r.Header.Get("Referer") != dsdBaseURL+"/" || r.UserAgent() != dsdUserAgent {
			t.Error("DSD artwork lost the source page's client identity")
			return rankingHTTPResponse(r, http.StatusForbidden, "client identity mismatch"), nil
		}
		return rankingHTTPResponse(r, http.StatusOK, art.String()), nil
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	raw, err := c.Call(`{"method":"cover","id":"dsd:123","url":"https://images.example.org/poster.png"}`)
	var result struct{ Data, ContentType string }
	if err != nil || json.Unmarshal([]byte(raw), &result) != nil || result.Data == "" || result.ContentType != "image/png" || requests != 1 {
		t.Fatal("cover did not complete through the ordinary mobile identity/cache path", err)
	}
}

func TestShuangguoUsesExistingBrowserTransportWithoutChangingOtherSources(t *testing.T) {
	cfg := defaultConfig()
	cfg.dataDir, cfg.OutputDir, cfg.ProxyURL, cfg.Retries = t.TempDir(), t.TempDir(), "direct", 1
	d := NewDownloader(cfg)
	defer d.client.CloseIdleConnections()
	transport := d.client.Transport.(*imageTransport).base.(*huangguoBrowserTransport)
	calls := 0
	transport.newClient = func(string) (browserHTTPClient, error) {
		return &browserFixtureClient{do: func(r *fhttp.Request) (*fhttp.Response, error) {
			calls++
			if r.URL.Host != "www.duanju2.com" || !strings.Contains(strings.Join(r.Header["user-agent"], " "), "Chrome/150.") || strings.Join(r.Header["sec-ch-ua-platform"], " ") != `"macOS"` {
				t.Error("source browser headers and TLS profile identity diverged")
			}
			return &fhttp.Response{StatusCode: http.StatusOK, Header: fhttp.Header{}, Body: io.NopCloser(strings.NewReader("fixture catalog"))}, nil
		}}, nil
	}
	var events []diagnosticEvent
	transport.record = func(event diagnosticEvent) { events = append(events, event) }
	transport.base = rankingTransport(func(r *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(r, http.StatusOK, "native source fixture"), nil
	})
	body, err := d.fetchProviderText(context.Background(), shuangguoBaseURL+"/show/26-----------.html", shuangguoBaseURL+"/")
	if err != nil || body != "fixture catalog" || calls != 1 || len(events) != 1 || events[0].Source != sourceShuangguo {
		t.Fatal("Shuangguo did not reuse the source-scoped browser connection", err)
	}
	r, _ := http.NewRequest(http.MethodGet, hongguoBaseURL+"/", nil)
	if transport.matches(r) {
		t.Fatal("browser routing expanded to an unrelated source")
	}
	r, _ = http.NewRequest(http.MethodPost, shuangguoBaseURL+"/", nil)
	if transport.matches(r) {
		t.Fatal("browser navigation transport captured a POST")
	}
}

func TestShuangguoDeclaresLocalSearchWhileKeepingCatalogCapability(t *testing.T) {
	c := &MobileClient{downloader: rankingTestDownloader(t, nil)}
	for _, item := range c.sourceCapabilities() {
		if item.Source == sourceShuangguo {
			if item.Search || item.SearchScope != "local" || !item.Categories || !item.BackgroundCatalog {
				t.Fatal("degraded search disabled unrelated source capabilities", item)
			}
			return
		}
	}
	t.Fatal("Shuangguo source identity disappeared")
}
