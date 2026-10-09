package app

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Exercise the actual pinned transport: replacing it with a RoundTripper fixture
// would miss failures that occur after DNS resolution but before any connection.
func TestMobileHuangguoColdRequestsRecoverFromReservedDNS(t *testing.T) {
	for _, operation := range []string{"ranking", "catalog"} {
		t.Run(operation, func(t *testing.T) {
			const route = "https://cold-huangguo.example.org"
			var entries, rankings, categories, fallbacks atomic.Int32
			target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Host != r.TLS.ServerName {
					t.Error("pinned request lost its original Host or TLS name")
				}
				switch {
				case r.Host == "huangguoai.ai" && r.URL.Path == "/":
					entries.Add(1)
					io.WriteString(w, `<a data-url="`+route+`"></a>`)
				case r.Host == "cold-huangguo.example.org" && r.URL.Path == "/ranks/hot/":
					if rankings.Add(1) > 1 && r.Header.Get("Cache-Control") != "no-cache" {
						t.Error("manual refresh did not reach the site with cache revalidation")
					}
					io.WriteString(w, strings.ReplaceAll(huangguoRankingRefreshFixture, "https://ranking.example.org", route))
				case r.Host == "cold-huangguo.example.org" && strings.HasPrefix(r.URL.Path, "/api/videos/category/"):
					categories.Add(1)
					fmt.Fprint(w, `{"data":{"items":[{"id":"117","title":"冷启动剧集"}],"pagination":{"page":1,"pages":1}}}`)
				default:
					t.Errorf("unexpected request: %s%s", r.Host, r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer target.Close()
			standard := http.DefaultTransport.(*http.Transport).Clone()
			standard.Proxy = nil
			// The fixture certificate does not cover the simulated provider names.
			standard.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
			standard.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
				if address != "93.184.216.34:443" {
					t.Errorf("connected to an unvalidated address: %s", address)
					return nil, fmt.Errorf("unexpected destination")
				}
				return (&net.Dialer{}).DialContext(ctx, network, target.Listener.Addr().String())
			}
			transport := newImageTransport(standard, standard)
			defer transport.CloseIdleConnections()
			transport.lookup = func(context.Context, string) ([]string, error) {
				return []string{"198.18.0.1"}, nil
			}
			transport.fallback = func(context.Context, string) ([]string, error) {
				fallbacks.Add(1)
				return []string{"93.184.216.34"}, nil
			}
			d := rankingTestDownloader(t, nil)
			d.client.Transport = transport
			if operation == "catalog" {
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				rows, more, err := d.mobileAICatalogPage(ctx, 1)
				if err != nil || len(rows) != 4 || more || entries.Load() != 1 || categories.Load() != 4 || fallbacks.Load() != 5 {
					t.Fatalf("cold catalog never reached the site: rows=%d entry=%d categories=%d fallback=%d err=%v", len(rows), entries.Load(), categories.Load(), fallbacks.Load(), err)
				}
				return
			}
			client := &MobileClient{downloader: d}
			for _, refresh := range []bool{false, true} {
				raw, err := client.Call(fmt.Sprintf(`{"method":"ranking","board":"huangguo-hot","refresh":%t}`, refresh))
				if err != nil {
					t.Fatalf("cold ranking never reached the site: entry=%d ranking=%d fallback=%d err=%v", entries.Load(), rankings.Load(), fallbacks.Load(), err)
				}
				var result struct {
					Items []rankingItem `json:"items"`
					Stale bool          `json:"stale"`
				}
				if err := json.Unmarshal([]byte(raw), &result); err != nil || len(result.Items) != 1 || result.Stale {
					t.Fatalf("invalid ranking response: %s err=%v", raw, err)
				}
			}
			if entries.Load() != 1 || rankings.Load() != 2 || fallbacks.Load() != 3 {
				t.Fatalf("refresh did not perform a second site request: entry=%d ranking=%d fallback=%d", entries.Load(), rankings.Load(), fallbacks.Load())
			}
		})
	}
}

func TestHuangguoTextRejectsReservedTrustedDNSBeforeConnection(t *testing.T) {
	var dials, fallbacks atomic.Int32
	standard := http.DefaultTransport.(*http.Transport).Clone()
	standard.DialContext = func(context.Context, string, string) (net.Conn, error) {
		dials.Add(1)
		return nil, fmt.Errorf("must not connect")
	}
	transport := newImageTransport(standard, standard)
	transport.lookup = func(context.Context, string) ([]string, error) {
		return []string{"198.18.0.1"}, nil
	}
	transport.fallback = func(context.Context, string) ([]string, error) {
		fallbacks.Add(1)
		return []string{"192.168.1.1"}, nil
	}
	d := rankingTestDownloader(t, nil)
	d.client.Transport = transport
	ctx := context.WithValue(context.Background(), providerTextSingleAttemptKey{}, true)
	_, _, err := d.fetchProviderTextURL(ctx, huangguoAIBaseURL+"/", "")
	if err == nil || dials.Load() != 0 || fallbacks.Load() != 1 {
		t.Fatalf("reserved DNS was dialed or trusted fallback was skipped: dial=%d fallback=%d err=%v", dials.Load(), fallbacks.Load(), err)
	}
}
