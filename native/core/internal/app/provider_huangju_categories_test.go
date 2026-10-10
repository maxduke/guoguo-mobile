package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestHuangjuCategoriesExpandedAndStillBounded(t *testing.T) {
	for _, test := range []struct {
		name      string
		count     int
		duplicate bool
		valid     bool
	}{
		{"current_374_categories", 374, false, true},
		{"oversized", 1001, false, false},
		{"duplicate", 374, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/auth/guest" {
					fmt.Fprint(w, `{"token":"fixture-token"}`)
					return
				}
				rows := make([]map[string]any, test.count)
				for index := range rows {
					rows[index] = map[string]any{"slug": fmt.Sprintf("type-%d", index), "name": fmt.Sprintf("分类%d", index)}
				}
				if test.duplicate {
					rows[1] = rows[0]
				}
				json.NewEncoder(w).Encode(rows)
			}))
			defer server.Close()
			client := newSourceMobileClient(t)
			client.downloader.cfg.HuangjuAPIURL = server.URL
			rows, err := client.downloader.fetchHuangjuCategories(context.Background())
			if (err == nil) != test.valid {
				t.Fatalf("valid=%v err=%v", test.valid, err)
			}
			if test.valid && len(rows) != test.count+1 {
				t.Fatalf("categories lost: %d", len(rows))
			}
		})
	}
}

type guestWaitingContext struct {
	context.Context
	once    sync.Once
	waiting chan struct{}
}

func (ctx *guestWaitingContext) Done() <-chan struct{} {
	ctx.once.Do(func() { close(ctx.waiting) })
	return ctx.Context.Done()
}

func TestHuangjuForegroundGuestRetriesCanceledPrefetchOwner(t *testing.T) {
	started := make(chan struct{})
	releaseServer := make(chan struct{})
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		if calls.Add(1) == 1 {
			close(started)
			select {
			case <-r.Context().Done():
			case <-releaseServer:
			}
			return
		}
		fmt.Fprint(w, `{"token":"fresh-token"}`)
	}))
	defer server.Close()
	defer close(releaseServer)
	client := newSourceMobileClient(t)
	client.downloader.cfg.HuangjuAPIURL = server.URL
	guest := client.downloader.huangjuClient()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	owner := make(chan error, 1)
	go func() { _, err := guest.guestToken(context.WithValue(ctx, backgroundCatalogKey{}, true)); owner <- err }()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("guest not started")
	}
	foregroundCtx, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	waiting := &guestWaitingContext{Context: foregroundCtx, waiting: make(chan struct{})}
	foreground := make(chan error, 1)
	go func() {
		token, err := guest.guestToken(waiting)
		if err == nil && token != "fresh-token" {
			err = errors.New("wrong token")
		}
		foreground <- err
	}()
	select {
	case <-waiting.waiting:
	case <-time.After(time.Second):
		t.Fatal("foreground did not share guest")
	}
	cancel()
	if err := <-owner; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation identity lost: %v", err)
	}
	if err := <-foreground; err != nil {
		t.Fatalf("foreground poisoned by canceled guest: %v", err)
	}
	if calls.Load() != 2 {
		t.Fatalf("guest attempts: %d", calls.Load())
	}
}
