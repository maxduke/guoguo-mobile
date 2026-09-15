package app

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Authentication is optional for portable desktop use. Compose requires a password.
func uiHTTPHandler(next http.Handler) (http.Handler, error) {
	user, password := os.Getenv("JUKU_AUTH_USER"), os.Getenv("JUKU_AUTH_PASSWORD")
	if user != "" && password == "" {
		return nil, errors.New("JUKU_AUTH_USER requires JUKU_AUTH_PASSWORD")
	}
	if user == "" {
		user = "admin"
	}
	expectedUser, expectedPassword := sha256.Sum256([]byte(user)), sha256.Sum256([]byte(password))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		if r.URL.Path == "/healthz" {
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				w.WriteHeader(http.StatusMethodNotAllowed)
				return
			}
			w.Header().Set("Cache-Control", "no-store")
			w.WriteHeader(http.StatusOK)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte("ok\n"))
			}
			return
		}
		// Apply the playback API's cross-site protection to every management endpoint.
		if strings.HasPrefix(r.URL.Path, "/api/") {
			if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
				http.Error(w, "cross-site request denied", http.StatusForbidden)
				return
			}
			if origin := r.Header.Get("Origin"); origin != "" {
				parsed, err := url.Parse(origin)
				if err != nil || parsed.User != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || !strings.EqualFold(parsed.Host, r.Host) {
					http.Error(w, "cross-site request denied", http.StatusForbidden)
					return
				}
			}
			r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		}
		if password != "" {
			suppliedUser, suppliedPassword, ok := r.BasicAuth()
			userHash, passwordHash := sha256.Sum256([]byte(suppliedUser)), sha256.Sum256([]byte(suppliedPassword))
			valid := subtle.ConstantTimeCompare(userHash[:], expectedUser[:]) & subtle.ConstantTimeCompare(passwordHash[:], expectedPassword[:])
			if !ok || valid != 1 {
				w.Header().Set("WWW-Authenticate", `Basic realm="guoguo-video", charset="UTF-8"`)
				w.Header().Set("Cache-Control", "no-store")
				http.Error(w, "authentication required", http.StatusUnauthorized)
				return
			}
		}
		next.ServeHTTP(w, r)
	}), nil
}

func serveUI(ctx context.Context, server *http.Server) error {
	requestCtx, cancelRequests := context.WithCancel(context.Background())
	defer cancelRequests()
	server.BaseContext = func(net.Listener) context.Context { return requestCtx }
	done := make(chan struct{})
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		select {
		case <-ctx.Done():
			cancelRequests() // Stop long-running streams before draining HTTP connections.
			drain, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := server.Shutdown(drain); err != nil {
				_ = server.Close()
			}
		case <-done:
		}
	}()
	err := server.ListenAndServe()
	close(done)
	<-stopped
	return err
}

func (a *UIApp) serveUntilSignal(server *http.Server) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return serveUI(ctx, server)
}

func (a *UIApp) stopBackgroundWork() {
	a.mu.Lock()
	a.closed = true
	libraryDone := a.libraryLoading
	if a.libraryCancel != nil {
		a.libraryCancel()
	}
	for _, cancel := range a.runningCancels {
		cancel()
	}
	for _, cancel := range a.parsingCancels {
		cancel()
	}
	a.cond.Broadcast()
	a.mu.Unlock()
	a.stopSortMetadata()
	a.workers.Wait()
	if libraryDone != nil {
		<-libraryDone
	}
	a.closePlaybacks()
	a.mu.Lock()
	dirty := a.libraryDirty
	a.mu.Unlock()
	if dirty {
		a.persistLibrary()
	}
	_ = a.playbackHistory().flush()
}
