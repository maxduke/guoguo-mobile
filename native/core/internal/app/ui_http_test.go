package app

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestUIHTTPAccess(t *testing.T) {
	t.Setenv("JUKU_AUTH_USER", "admin")
	t.Setenv("JUKU_AUTH_PASSWORD", "test-password")
	handler, err := uiHTTPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, path, origin, site, password string
		status                             int
	}{
		{name: "page requires login", path: "/", status: 401},
		{name: "assets require login", path: "/assets/player.js", status: 401},
		{name: "API requires login", path: "/api/ui/config", status: 401},
		{name: "incorrect password", path: "/", password: "wrong", status: 401},
		{name: "authenticated", path: "/api/ui/config", password: "test-password", status: 204},
		{name: "health bypass", path: "/healthz", status: 200},
		{name: "health prefix protected", path: "/healthz/anything", status: 401},
		{name: "foreign origin", path: "/api/ui/config", origin: "https://evil.example", password: "test-password", status: 403},
		{name: "null origin", path: "/api/ui/config", origin: "null", password: "test-password", status: 403},
		{name: "cross site", path: "/api/ui/config", site: "cross-site", password: "test-password", status: 403},
		{name: "same origin", path: "/api/ui/config", origin: "http://example.com", site: "same-origin", password: "test-password", status: 204},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "http://example.com"+tc.path, nil)
			r.Header.Set("Origin", tc.origin)
			r.Header.Set("Sec-Fetch-Site", tc.site)
			if tc.password != "" {
				r.SetBasicAuth("admin", tc.password)
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("status %d, want %d", w.Code, tc.status)
			}
		})
	}
}

func TestUIHTTPOptionalAuth(t *testing.T) {
	t.Setenv("JUKU_AUTH_USER", "")
	t.Setenv("JUKU_AUTH_PASSWORD", "")
	h, err := uiHTTPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != 204 {
		t.Fatal(w.Code)
	}
	t.Setenv("JUKU_AUTH_USER", "admin")
	if _, err := uiHTTPHandler(h); err == nil {
		t.Fatal("partial auth configuration accepted")
	}
}

func TestPublicURL(t *testing.T) {
	for input, want := range map[string]string{"[::]:8999": "http://127.0.0.1:8999", "0.0.0.0:8999": "http://127.0.0.1:8999", "[::1]:8999": "http://[::1]:8999", "localhost:8999": "http://localhost:8999"} {
		if got := publicURL(input); got != want {
			t.Errorf("%s = %s, want %s", input, got, want)
		}
	}
}

func TestServeUICanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan error, 1)
	go func() { done <- serveUI(ctx, &http.Server{Addr: "127.0.0.1:0"}) }()
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown did not terminate server")
	}
}
