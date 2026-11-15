package app

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestHuangguoPublisherRoutesUseOnlyValidatedArrayData(t *testing.T) {
	script := `var subdomains=['thu', // comment
	'pku']; var urls=['publisher-fixture.example.org/'];
	var otherUrls=['https://untrusted.example.org'];`
	want := []string{"https://thu.publisher-fixture.example.org", "https://pku.publisher-fixture.example.org"}
	if got := parseHuangguoPublishRoutes(script); !reflect.DeepEqual(got, want) {
		t.Fatal("publisher routes lost their declared domain/subdomain identity", got)
	}
	for _, host := range []string{"thu.publisher-fixture.example.org", "pku.publisher-fixture.example.org"} {
		t.Cleanup(func() { huangguoAIDiscoveredHosts.Delete(host) })
	}
	for _, script := range []string{
		`var urls=['127.0.0.1','192.168.1.1','localhost','https://bad.example.org','bad.example.org/path','huangguoai.pages.dev','huangguoai.com'];`,
		`var urls=['one.example.org']; var urls=['two.example.org'];`,
		`var subdomains=['a/b','user@evil','a.b']; var urls=['domain.example.org'];`,
	} {
		if got := parseHuangguoPublishRoutes(script); len(got) != 0 {
			t.Fatal("accepted invalid publisher data", got)
		}
	}
}

func TestHuangguoDiscoveryFallsBackToOfficialPublisher(t *testing.T) {
	var paths []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		paths = append(paths, r.URL.Host+r.URL.RequestURI())
		if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" {
			t.Error("publisher inherited account credentials")
		}
		if deadline, ok := r.Context().Deadline(); !ok || time.Until(deadline) > 8*time.Second {
			t.Error("discovery is unbounded")
		}
		if r.URL.Host == "huangguoai.ai" {
			return nil, errors.New("main landing unavailable")
		}
		if r.URL.Host != "huangguoai.pages.dev" {
			t.Fatal("publisher escaped its fixed origin")
		}
		if r.URL.Path == "/" {
			return rankingHTTPResponse(r, 200, `<script src="https://untrusted.example.org/publish.js"></script><script src="/publish.js?v=2"></script>`), nil
		}
		if r.URL.RequestURI() != "/publish.js?v=2" {
			t.Fatal("wrong publisher script")
		}
		return rankingHTTPResponse(r, 200, `var subdomains=['a'];var urls=['publisher-fallback.example.org'];`), nil
	})
	t.Cleanup(func() { huangguoAIDiscoveredHosts.Delete("a.publisher-fallback.example.org") })
	got := d.discoverHuangguoAIRoutes(context.Background(), false)
	if !reflect.DeepEqual(got, []string{"https://a.publisher-fallback.example.org"}) || len(paths) != 3 {
		t.Fatal("main failure did not use one bounded publisher read", paths, got)
	}
	if again := d.discoverHuangguoAIRoutes(context.Background(), false); !reflect.DeepEqual(again, got) || len(paths) != 3 {
		t.Fatal("discovery cache caused more requests")
	}
}

func TestHuangguoCancelledDiscoveryDoesNotReadPublisher(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		cancel()
		return nil, ctx.Err()
	})
	if got := d.discoverHuangguoAIRoutes(ctx, true); len(got) != 0 || calls != 1 {
		t.Fatal("cancelled discovery continued", got, calls)
	}
}

func TestHuangguoPublisherCannotRedirect(t *testing.T) {
	calls := 0
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		response := rankingHTTPResponse(r, 302, "")
		response.Header.Set("Location", "https://untrusted.example.org/publish.js")
		return response, nil
	})
	if got := d.discoverHuangguoPublisher(context.Background()); len(got) != 0 || calls != 1 {
		t.Fatal("publisher redirect was followed", got, calls)
	}
	if got := parseHuangguoPublishRoutes("var urls=['" + strings.Repeat("a", 16400) + "'];"); len(got) != 0 {
		t.Fatal("unbounded route declaration accepted")
	}
}

func TestHuangguoFailedDiscoveryRefreshRetainsRoutesAndWarning(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		return nil, errors.New("publisher and landing unavailable")
	})
	d.huangguoAIRoutes = []string{"https://cached-line.example.org"}
	d.providerHosts[sourceHuangguoAI] = d.huangguoAIRoutes[0]
	result := d.huangguoLines(context.Background(), true)
	if result["warning"] == "" || !reflect.DeepEqual(d.huangguoAIRoutes, []string{"https://cached-line.example.org"}) || d.providerHosts[sourceHuangguoAI] != d.huangguoAIRoutes[0] {
		t.Fatal("failed refresh lost routes or hid its failure", result)
	}
}
