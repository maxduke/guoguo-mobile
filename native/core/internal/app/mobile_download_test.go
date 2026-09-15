package app

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"
)

func TestMobileOfflinePlanPreservesKeysAndRelativeResources(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	media := providerMedia{URL: "https://example.com/series/index.m3u8", HLSKey: []byte("0123456789abcdef"), Playlist: `#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="../key"
#EXTINF:4,
segment.ts
#EXTINF:4,
segment.ts
#EXT-X-ENDLIST
`}
	plan, err := c.planMobileMedia(context.Background(), media, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Process || plan.Input != "index.m3u8" || len(plan.Assets) != 1 {
		t.Fatalf("unexpected plan: %+v", plan)
	}
	if plan.Assets[0].URL != "https://example.com/series/segment.ts" {
		t.Fatal("relative segment resolved incorrectly")
	}
	if len(plan.Inline) != 2 {
		t.Fatal("key or playlist missing")
	}
	key, _ := base64.StdEncoding.DecodeString(plan.Inline[0].Body)
	if string(key) != "0123456789abcdef" {
		t.Fatal("inline key lost")
	}
	playlist, _ := base64.StdEncoding.DecodeString(plan.Inline[1].Body)
	if strings.Contains(string(playlist), "https://") || strings.Contains(string(playlist), "../") || strings.Contains(string(playlist), `\"`) {
		t.Fatal("offline playlist has external or malformed references")
	}
}

func TestMobileOfflinePlanRejectsLiveAndNonHTTPResources(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for _, playlist := range []string{"#EXTM3U\n#EXTINF:4,\nsegment.ts", "#EXTM3U\n#EXTINF:4,\nfile:///etc/passwd\n#EXT-X-ENDLIST"} {
		if _, err := c.planMobileMedia(context.Background(), providerMedia{URL: "https://example.com/index.m3u8", Playlist: playlist}, nil); err == nil {
			t.Fatal("accepted invalid offline playlist")
		}
	}
}
