package app

import (
	"encoding/json"
	"testing"
	"time"
)

func TestMobilePlaybackRoutesPreserveQualityAndRelease(t *testing.T) {
	primary := providerMedia{URL: "https://example.test/a.mp4", Quality: 1080}
	primary.Variants = []providerMedia{primary,
		{URL: "https://example.test/b.mp4", Quality: 1080},
		{URL: "https://example.test/c.mp4", Quality: 720},
		{URL: "file:///private/video.mp4", Quality: 1080},
	}
	manual, err := mobilePlaybackChoices(primary, nil, 1080)
	if err != nil || len(manual.media) != 2 {
		t.Fatalf("manual choices: %+v %v", manual, err)
	}
	if _, err := mobilePlaybackChoices(primary, nil, 480); err == nil {
		t.Fatal("missing manual quality silently downgraded")
	}
	choice, err := mobilePlaybackChoices(primary, nil, 0)
	if err != nil || len(choice.media) != 3 {
		t.Fatalf("choices: %+v %v", choice, err)
	}
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	first, err := c.openMobilePlayback(choice)
	if err != nil {
		t.Fatal(err)
	}
	if first["url"] != primary.URL || first["routeCount"] != 3 || first["castDirect"] != true {
		t.Fatalf("plan: %+v", first)
	}
	request, _ := json.Marshal(map[string]any{"method": "fallback", "id": first["session"]})
	raw, err := c.Call(string(request))
	if err != nil {
		t.Fatal(err)
	}
	var next map[string]any
	if err := json.Unmarshal([]byte(raw), &next); err != nil {
		t.Fatal(err)
	}
	if next["url"] != "https://example.test/b.mp4" || next["routeIndex"] != float64(1) {
		t.Fatalf("fallback: %+v", next)
	}
	for _, plan := range []map[string]any{first, next} {
		request, _ := json.Marshal(map[string]any{"method": "release", "id": plan["session"]})
		if _, err := c.Call(string(request)); err != nil {
			t.Fatal(err)
		}
	}
	if len(c.playbacks) != 0 || len(c.proxies) != 0 {
		t.Fatal("released sessions retained")
	}
	if _, err := c.Call(string(request)); err == nil {
		t.Fatal("released session accepted")
	}
}

func TestMobilePlaybackExpiredRouteRequiresResolve(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	choice, _ := mobilePlaybackChoices(providerMedia{URL: "https://example.test/a.mp4"}, nil, 0)
	choice.created = time.Now().Add(-3 * time.Minute)
	plan, err := c.openMobilePlayback(choice)
	if err != nil {
		t.Fatal(err)
	}
	request, _ := json.Marshal(map[string]any{"method": "fallback", "id": plan["session"]})
	if _, err := c.Call(string(request)); err == nil {
		t.Fatal("expired route accepted")
	}
}
