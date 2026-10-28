package app

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestMobileResolveCancellationOwnsExactRequestAndSurvivesDispatchWait(t *testing.T) {
	c := &MobileClient{}
	r := mobileRequest{RequestID: "resolve-one", ID: "hongguo:1", Chapter: Chapter{ID: "2"}}
	ctx, finish, err := c.beginResolve(context.Background(), r)
	if err != nil {
		t.Fatal(err)
	}
	defer finish()
	if _, _, err := c.beginResolve(context.Background(), r); err == nil {
		t.Fatal("duplicate active request accepted")
	}
	wrong := r
	wrong.Chapter.ID = "3"
	c.cancelResolve(wrong)
	if ctx.Err() != nil {
		t.Fatal("another episode canceled this request")
	}
	c.cancelResolve(r)
	if ctx.Err() != context.Canceled {
		t.Fatal("matching request was not canceled")
	}
	if time.Until(c.canceledResolves[r.RequestID].expires) < 74*time.Second {
		t.Fatal("cancellation cannot cover the Android dispatch budget")
	}
	finish()
	if _, _, err := c.beginResolve(context.Background(), r); err != context.Canceled {
		t.Fatal("queued canceled request restarted", err)
	}
	wrong.RequestID = "independent"
	other, done, err := c.beginResolve(context.Background(), wrong)
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
	if other.Err() != context.Canceled {
		t.Fatal("close did not stop a resolution")
	}
	done()
	if len(c.resolveReads) != 0 {
		t.Fatal("closed request retained")
	}
}

func TestMobileResolveCancellationInterruptsRealProviderWork(t *testing.T) {
	started := make(chan struct{})
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		close(started)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	c := &MobileClient{downloader: d}
	defer c.Close()
	done := make(chan error, 1)
	go func() {
		_, err := c.Call(`{"method":"resolve","requestId":"network","id":"hongguo:1","chapter":{"id":"2","videoUrl":"hongguo-cenc://2"}}`)
		done <- err
	}()
	select {
	case <-started:
	case err := <-done:
		t.Fatal("resolution ended before provider IO", err)
	case <-time.After(time.Second):
		t.Fatal("resolution did not start provider IO")
	}
	if _, err := c.Call(`{"method":"cancelResolve","requestId":"network","id":"hongguo:1","chapter":{"id":"2"}}`); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled resolution succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("cancel did not interrupt provider IO")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.resolveReads) != 0 || len(c.playbacks) != 0 || len(c.proxies) != 0 {
		t.Fatal("canceled resolution published or retained resources")
	}
}

func TestMobileCanceledOrClosedResolveCannotPublishPlayback(t *testing.T) {
	for _, closed := range []bool{false, true} {
		c := &MobileClient{}
		ctx, cancel := context.WithCancel(context.Background())
		if closed {
			c.Close()
		} else {
			cancel()
		}
		choice := mobilePlaybackChoice{media: []providerMedia{{URL: "https://media.example.test/episode.mp4"}}}
		if _, err := c.openMobilePlaybackContext(ctx, choice); !errors.Is(err, context.Canceled) {
			t.Fatal("canceled/closed resolution published a playback", err)
		}
		cancel()
		if len(c.playbacks) != 0 {
			t.Fatal("playback resurrected after cancellation")
		}
	}
}
