package app

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestMobileScopedCredentialsProxyAndDownloadURLs(t *testing.T) {
	foreign := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "" || r.URL.Query().Get("Policy") != "" {
			t.Error("credentials leaked across origins")
		}
		w.Write([]byte("foreign-segment"))
	}))
	defer foreign.Close()
	var sameOriginCookies int
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Cookie"), "CloudFront-Policy=policy") {
			t.Error("same-origin cookie missing")
		} else {
			sameOriginCookies++
		}
		if r.URL.Path == "/redirect.ts" {
			http.Redirect(w, r, foreign.URL+"/segment.ts", http.StatusFound)
			return
		}
		w.Write([]byte("fixture-segment"))
	}))
	defer origin.Close()
	credentials := &providerMediaCredentials{origin: origin.URL, cookie: "CloudFront-Policy=policy; CloudFront-Signature=signature; CloudFront-Key-Pair-Id=key", expires: time.Now().Add(time.Minute)}
	media := providerMedia{URL: origin.URL + "/index.m3u8", credentials: credentials, Playlist: "#EXTM3U\n#EXTINF:4,\nredirect.ts\n#EXTINF:4,\n" + foreign.URL + "/segment.ts\n#EXT-X-ENDLIST\n"}
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	choice, err := mobilePlaybackChoices(media, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := c.openMobilePlayback(choice)
	if err != nil {
		t.Fatal(err)
	}
	if plan["castDirect"] != false || plan["expiresAt"].(int64) <= time.Now().UnixMilli() {
		t.Fatal("missing scoped session metadata")
	}
	raw, _ := json.Marshal(plan)
	if strings.Contains(string(raw), "CloudFront-") {
		t.Fatal("cookie exported to player")
	}
	response, err := http.Get(plan["url"].(string))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	for _, line := range strings.Split(string(body), "\n") {
		if !strings.HasPrefix(line, "http") {
			continue
		}
		response, err := http.Get(line)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if string(body) != "foreign-segment" {
			t.Fatalf("unexpected proxy response %q", body)
		}
	}
	if sameOriginCookies != 1 {
		t.Fatalf("same-origin requests: %d", sameOriginCookies)
	}
	signed, err := credentials.downloadURL(origin.URL + "/part.ts?opaque=a%2Fb")
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := url.Parse(signed)
	if !strings.HasPrefix(parsed.RawQuery, "opaque=a%2Fb&") || parsed.Query().Get("Policy") != "policy" || parsed.Query().Get("Signature") != "signature" || parsed.Query().Get("Key-Pair-Id") != "key" {
		t.Fatal("signed download grant changed")
	}
	if address, err := credentials.downloadURL(foreign.URL + "/part.ts"); err != nil || address != foreign.URL+"/part.ts" {
		t.Fatal("foreign URL changed")
	}
	credentials.expires = time.Now().Add(-time.Second)
	if _, err := credentials.downloadURL(origin.URL + "/part.ts"); err == nil {
		t.Fatal("accepted expired grant")
	}
}

func TestMobileCredentialDownloadPlanIsDurableAndRefreshable(t *testing.T) {
	var endpoint string
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/auth/guest":
			io.WriteString(w, `{"token":"guest"}`)
		case "/play/1":
			for _, value := range []string{"Policy=policy", "Signature=signature", "Key-Pair-Id=key"} {
				w.Header().Add("Set-Cookie", "CloudFront-"+value+"; Max-Age=60")
			}
			json.NewEncoder(w).Encode(map[string]any{"url": endpoint + "/index.m3u8"})
		case "/index.m3u8":
			if r.Header.Get("Cookie") == "" {
				t.Error("missing playlist credentials")
			}
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			io.WriteString(w, "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n")
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
		}
	}))
	defer origin.Close()
	endpoint = origin.URL
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.downloader.cfg.HuangjuAPIURL = origin.URL
	result, err := c.downloadPlan(context.Background(), mobileRequest{ID: "huangju:sample-1", Chapter: Chapter{ID: "huangju:sample-1:1"}})
	if err != nil {
		t.Fatal(err)
	}
	if !result.RefreshOnResume || len(result.Assets) != 2 || result.Headers["Cookie"] != "" {
		t.Fatalf("invalid durable plan: %+v", result)
	}
	for _, asset := range result.Assets {
		parsed, err := url.Parse(asset.URL)
		if err != nil {
			t.Fatal(err)
		}
		if parsed.Query().Get("Policy") != "policy" || strings.Contains(asset.Identity, "Policy=") || asset.Identity == "" {
			t.Fatal("missing signed grant or stable asset identity")
		}
	}
}
