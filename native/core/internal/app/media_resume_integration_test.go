package app

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type mediaDisconnectWriter struct {
	http.ResponseWriter
	remaining int
}

func (writer *mediaDisconnectWriter) Write(data []byte) (int, error) {
	if len(data) > writer.remaining {
		count, _ := writer.ResponseWriter.Write(data[:writer.remaining])
		writer.remaining = 0
		return count, io.ErrUnexpectedEOF
	}
	count, err := writer.ResponseWriter.Write(data)
	writer.remaining -= count
	return count, err
}

func verifyResumedTimeline(t *testing.T, ctx context.Context, ffmpeg, input string) {
	t.Helper()
	command := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "warning", "-xerror", "-nostdin", "-i", input,
		"-map", "0:v:0", "-map", "0:a:0", "-progress", "pipe:1", "-f", "null", "-")
	var progress, diagnostic bytes.Buffer
	command.Stdout, command.Stderr = &progress, &diagnostic
	if err := command.Run(); err != nil {
		t.Fatalf("decode resumed timeline: %v\n%s", err, diagnostic.String())
	}
	values := make(map[string]string)
	for _, line := range strings.Split(progress.String(), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			values[key] = strings.TrimSpace(value)
		}
	}
	frames, _ := strconv.Atoi(values["frame"])
	micros, _ := strconv.Atoi(values["out_time_us"])
	if values["progress"] != "end" || frames != 1800 || micros < 59_900_000 || micros > 60_200_000 {
		t.Fatalf("interrupted media lost frames, audio or duration: %v\n%s", values, diagnostic.String())
	}
}

func TestMobileProxyResumesInterruptedMedia(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("local FFmpeg is unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	fixture := filepath.Join(t.TempDir(), "fixture.mp4")
	command := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30:duration=60", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=60", "-c:v", "libx264", "-preset", "ultrafast", "-threads", "1", "-c:a", "aac", "-movflags", "+faststart", "-y", fixture)
	if diagnostic, err := command.CombinedOutput(); err != nil {
		t.Fatalf("generate fixture: %v %s", err, diagnostic)
	}
	video, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"stream", "prefetch", "failed stream"} {
		t.Run(mode, func(t *testing.T) {
			var interrupted, interruptEnabled atomic.Bool
			interruptEnabled.Store(mode != "prefetch")
			var resumes atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if request.URL.Path != "/fixture.mp4" {
					t.Error("unrelated resource")
					http.NotFound(writer, request)
					return
				}
				writer.Header().Set("ETag", `"generated-media-v1"`)
				if request.Header.Get("If-Range") == `"generated-media-v1"` {
					resumes.Add(1)
				}
				if request.Method == http.MethodGet && interruptEnabled.Load() && (interrupted.CompareAndSwap(false, true) || mode == "failed stream") {
					writer = &mediaDisconnectWriter{ResponseWriter: writer, remaining: min(64*1024, len(video)/2)}
				}
				http.ServeContent(writer, request, "fixture.mp4", time.Time{}, bytes.NewReader(video))
			}))
			defer server.Close()
			d := rankingTestDownloader(t, nil)
			d.cfg.Retries, d.client = 3, server.Client()
			proxy, err := d.newHLSProxy(ctx, providerMedia{URL: server.URL + "/fixture.mp4"}, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer proxy.Close()
			if mode == "prefetch" {
				stats := proxy.prefetch(ctx, 0, 128*1024)
				if stats.cached == 0 {
					t.Fatal("prefetch did not cache media")
				}
				interruptEnabled.Store(true)
			}
			response, err := http.Get(proxy.root)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			data, err := io.ReadAll(response.Body)
			if mode == "failed stream" {
				if err == nil || len(data) == len(video) {
					t.Fatal("incomplete media was accepted")
				}
				return
			}
			if err != nil || !bytes.Equal(data, video) {
				t.Fatalf("byte continuation changed media: %v, bytes=%d", err, len(data))
			}
			input := filepath.Join(t.TempDir(), "resumed.mp4")
			if err := os.WriteFile(input, data, 0600); err != nil {
				t.Fatal(err)
			}
			verifyResumedTimeline(t, ctx, ffmpeg, input)
			if !interrupted.Load() || resumes.Load() == 0 {
				t.Fatal("automatic byte continuation was not exercised")
			}
		})
	}
}
