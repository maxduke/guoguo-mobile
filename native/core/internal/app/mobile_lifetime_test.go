package app

import (
	"net/http"
	"testing"
	"time"
)

func TestMobileCloseCancelsInFlightDetailAndRejectsLaterCalls(t *testing.T) {
	started := make(chan struct{})
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		close(started)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	c := &MobileClient{downloader: d}
	done := make(chan error, 1)
	go func() {
		_, err := c.Call(`{"method":"detail","source":"guanguo","id":"guanguo:123"}`)
		done <- err
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("detail did not start")
	}
	c.Close()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("closing the core accepted an unfinished detail")
		}
	case <-time.After(time.Second):
		t.Fatal("closing the core did not cancel detail IO")
	}
	if _, err := c.Call(`{"method":"coreInfo"}`); err == nil {
		t.Fatal("closed core accepted a new call")
	}
	c.Close()
}
