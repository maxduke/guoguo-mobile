package app

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMediaPrefetchCENCFFmpegDecode(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("local FFmpeg is unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	file := filepath.Join(t.TempDir(), "encrypted.mp4")
	const key = "00112233445566778899aabbccddeeff"
	command := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "color=size=180x320:rate=10", "-t", "1", "-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-encryption_scheme", "cenc-aes-ctr", "-encryption_key", key, "-encryption_kid", key, file)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("generate encrypted fixture: %v %s", err, output)
	}
	payload, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"generated-cenc"`)
		w.Header().Set("Content-Type", "video/mp4")
		http.ServeContent(w, r, "fixture", time.Time{}, bytes.NewReader(payload))
	}))
	defer origin.Close()
	d := &Downloader{client: origin.Client(), cfg: Config{Retries: 3}}
	proxy, err := d.newHLSProxy(ctx, providerMedia{URL: origin.URL + "/fixture.mp4"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	if stats := proxy.prefetch(ctx, 0, 64); stats.cached != 64 {
		t.Fatalf("CENC prefix not warmed: %+v", stats)
	}
	command = exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-xerror", "-nostdin", "-decryption_key", key, "-i", proxy.root, "-threads", "1", "-progress", "pipe:1", "-f", "null", "-")
	output, err := command.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "frame=10\n") || !strings.Contains(string(output), "progress=end") {
		t.Fatalf("cached CENC prefix failed decode: %v %s", err, output)
	}
	if proxy.reusedBytes.Load() < 64 || proxy.Err() != nil {
		t.Fatal("decode bypassed the cache or lost the stream")
	}
}
