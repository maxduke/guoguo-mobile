package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestMobileDiagnosticNetworkCacheAndFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/auth/guest" {
			fmt.Fprint(w, `{"token":"fixture-token"}`)
			return
		}
		fmt.Fprint(w, `[{"slug":"romance","name":"甜宠"}]`)
	}))
	defer server.Close()
	client := newSourceMobileClient(t)
	client.downloader.cfg.HuangjuAPIURL = server.URL
	response := callNewMobileSource(t, client, map[string]any{"method": "categories", "source": "huangju", "traceId": "success"})
	metadata := response["_diagnostic"].(map[string]any)
	if metadata["networkAttempts"] != float64(2) || metadata["httpStatus"] != float64(200) || metadata["result"] != "success" {
		t.Fatalf("network diagnostic: %+v", metadata)
	}
	_, err := client.Call(`{"method":"catalog","source":"huangju","category":"../invalid","traceId":"failure"}`)
	if err == nil {
		t.Fatal("invalid category accepted")
	}
	response = callNewMobileSource(t, client, map[string]any{"method": "requestDiagnostic", "traceId": "failure"})
	metadata = response["diagnostic"].(map[string]any)
	if metadata["result"] != "failed" || metadata["networkAttempts"] != float64(0) || metadata["stage"] != "request" {
		t.Fatalf("pre-network failure diagnostic: %+v", metadata)
	}
	board, _ := findRankingBoard("huangju-latest")
	if board.ID == "" {
		for _, candidate := range rankingBoards {
			if candidate.Source == sourceHuangju {
				board = candidate
				break
			}
		}
	}
	client.downloader.rankings = rankingCache{pages: map[string]rankingPage{}, pending: map[string]*rankingCall{}}
	// Exercise the real ranking cache path rather than inferring cache from zero I/O.
	page := rankingPage{FetchedAt: time.Now()}
	client.downloader.rankings.pages[fmt.Sprintf("%s:%d", board.ID, 1)] = page
	trace := &mobileTrace{value: mobileDiagnostic{At: time.Now()}}
	ctx := context.WithValue(context.Background(), mobileTraceKey{}, trace)
	_, err = client.downloader.loadRankingPage(ctx, board, 1, false)
	if err != nil || trace.snapshot(nil, nil, true).CacheHits != 1 {
		t.Fatalf("cache hit missing: %v %+v", err, trace.value)
	}
}

func TestMobileDiagnosticFailureClassificationAndClosedSchema(t *testing.T) {
	for _, test := range []struct {
		err  error
		want string
	}{
		{context.Canceled, "cancelled"}, {publicError(context.Canceled), "cancelled"},
		{context.DeadlineExceeded, "timeout"}, {&net.DNSError{Err: "no such host", Name: "secret"}, "dns"},
		{errors.New("secret HTTP 403：站点要求浏览器验证"), "verification"},
		{errors.New("secret HTTP 429，已暂停该域名请求"), "backoff"},
		{errors.New("secret HTTP 500"), "http"}, {errors.New("secret EOF"), "connection"},
	} {
		if got := diagnosticFailure(test.err); got != test.want {
			t.Errorf("got %s, want %s", got, test.want)
		}
	}
	trace := &mobileTrace{value: mobileDiagnostic{Source: sourceHuangju, Method: "catalog", At: time.Now()}}
	ctx := context.WithValue(context.Background(), mobileTraceKey{}, trace)
	var workers sync.WaitGroup
	for range 10 {
		workers.Go(func() {
			for range 100 {
				traceNetwork(ctx)
			}
		})
	}
	workers.Wait()
	value := trace.snapshot(errors.New("https://secret/path?token=secret"), nil, true)
	traceNetwork(ctx)
	if value.NetworkAttempts != 1000 || trace.value.NetworkAttempts != 1000 {
		t.Fatal("trace closing/counting failed")
	}
	raw, _ := json.Marshal(value)
	if strings.Contains(string(raw), "secret") {
		t.Fatal("raw exception leaked")
	}
	partial := (&mobileTrace{value: mobileDiagnostic{At: time.Now()}}).snapshot(nil, map[string]any{"warning": "secret EOF", "stale": true}, true)
	if partial.Result != "partial" || partial.Failure != "connection" {
		t.Fatalf("partial: %+v", partial)
	}
}

func TestMobileDiagnosticBoundedAndDisposed(t *testing.T) {
	client := newSourceMobileClient(t)
	for i := range 70 {
		client.saveDiagnostic(fmt.Sprintf("trace-%d", i), mobileDiagnostic{})
	}
	if len(client.diagnostics) != 64 || len(client.diagnosticOrder) != 64 {
		t.Fatal("unbounded diagnostics")
	}
	if _, exists := client.diagnostics["trace-0"]; exists {
		t.Fatal("old trace retained")
	}
	client.Close()
	client.saveDiagnostic("late", mobileDiagnostic{})
	if len(client.diagnostics) != 0 {
		t.Fatal("late trace retained after close")
	}
}

func TestMobileCatalogCancellationOwnershipAndCapabilities(t *testing.T) {
	client := newSourceMobileClient(t)
	capabilities := client.sourceCapabilities()
	background := 0
	for _, item := range capabilities {
		if item.BackgroundCatalog {
			background++
		}
	}
	if len(capabilities) != 19 || background != 16 {
		t.Fatalf("capabilities: %+v", capabilities)
	}
	for _, source := range []string{sourceHongguo, "huangguo", sourceHuangdou} {
		if _, _, err := client.beginCatalogRead(context.Background(), mobileRequest{Source: source, Background: true, RequestID: "aggregate"}); err == nil {
			t.Fatal("stateful aggregate prefetch accepted")
		}
	}
	request := mobileRequest{Source: sourceHuangju, Category: "romance", Page: 2, RequestID: "page-2", Background: true}
	ctx, finish, err := client.beginCatalogRead(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if deadline, _ := ctx.Deadline(); time.Until(deadline) > 8*time.Second {
		t.Fatal("missing deadline")
	}
	wrong := request
	wrong.Category = "other"
	client.cancelCatalogRead(wrong)
	if ctx.Err() != nil {
		t.Fatal("wrong identity canceled read")
	}
	client.cancelCatalogRead(request)
	if ctx.Err() != context.Canceled {
		t.Fatal("matching read not canceled")
	}
	finish()
	if len(client.catalogReads) != 0 {
		t.Fatal("finished read retained")
	}
	if _, _, err := client.beginCatalogRead(context.Background(), request); err != context.Canceled {
		t.Fatal("cancel-before-start not honored")
	}
	request.RequestID = "next"
	ctx, finish, err = client.beginCatalogRead(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	client.Close()
	if ctx.Err() != context.Canceled {
		t.Fatal("close did not cancel")
	}
	finish()
}

func TestMobileCatalogCancellationInterruptsNetworkAndRecordsTrace(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/auth/guest" {
			fmt.Fprint(w, `{"token":"fixture-token"}`)
			return
		}
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	client := newSourceMobileClient(t)
	client.downloader.cfg.HuangjuAPIURL = server.URL
	finished := make(chan error, 1)
	go func() {
		_, err := client.Call(`{"method":"catalog","source":"huangju","page":2,"background":true,"requestId":"cancel-network","traceId":"cancel-trace"}`)
		finished <- err
	}()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("request did not start")
	}
	client.cancelCatalogRead(mobileRequest{Source: sourceHuangju, Page: 2, RequestID: "cancel-network"})
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("canceled request succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("network not interrupted")
	}
	response := callNewMobileSource(t, client, map[string]any{"method": "requestDiagnostic", "traceId": "cancel-trace"})
	metadata := response["diagnostic"].(map[string]any)
	if metadata["result"] != "cancelled" || metadata["failure"] != "cancelled" || metadata["networkAttempts"] != float64(2) {
		t.Fatalf("cancel diagnostic: %+v", metadata)
	}
}
