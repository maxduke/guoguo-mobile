package sourcecheck

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type mediaClient struct {
	address  string
	releases int
	hls      bool
}

func (c *mediaClient) Call(raw string) (string, error) {
	var request map[string]any
	_ = json.Unmarshal([]byte(raw), &request)
	if request["method"] == "release" {
		c.releases++
		return `{}`, nil
	}
	return fmt.Sprintf(`{"url":%q,"hls":%t,"session":"private-session","headers":{"User-Agent":"fixture"}}`, c.address, c.hls), nil
}

func TestMediaProbeHonorsHLSHintAndMasterForExtensionlessURLs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/master", "/variant":
			if r.Header.Get("Range") != "bytes=0-65535" {
				t.Error("playlist truncated to a media prefix")
			}
			fmt.Fprint(w, "#EXTM3U\n"+strings.Repeat("# fixture metadata\n", 100))
			if r.URL.Path == "/master" {
				fmt.Fprint(w, "#EXT-X-STREAM-INF:BANDWIDTH=100000\n/variant\n")
			} else {
				fmt.Fprint(w, "#EXTINF:4,\n/segment\n")
			}
		default:
			_, _ = w.Write(append([]byte("\x00\x00\x00\x18ftypisom"), make([]byte, 1012)...))
		}
	}))
	defer server.Close()
	client := &mediaClient{address: server.URL + "/master", hls: true}
	step := probeMedia(context.Background(), client, "source", "id", json.RawMessage(`{"id":"chapter"}`))
	if step.Status != "passed" || step.MediaKind != "mp4" || step.MediaBytes != 1024 || client.releases != 1 {
		t.Fatalf("extensionless HLS failed: %+v", step)
	}
}

func TestMediaProbeChecksKeyAndSegmentWithoutReportingCredentials(t *testing.T) {
	keys, segments := 0, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/index.m3u8":
			fmt.Fprint(w, "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key?token=private\"\n#EXTINF:4,\npart.ts?token=private\n#EXT-X-ENDLIST\n")
		case "/key":
			keys++
			fmt.Fprint(w, "1234567890123456")
		case "/part.ts":
			segments++
			if r.Header.Get("Range") != "bytes=0-1023" {
				t.Error("probe requested more than a media prefix")
			}
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(make([]byte, 1024))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := &mediaClient{address: server.URL + "/index.m3u8?token=private"}
	step := probeMedia(context.Background(), client, "source", "id", json.RawMessage(`{"id":"chapter"}`))
	if step.Status != "passed" || step.MediaBytes != 1024 || keys != 1 || segments != 1 || client.releases != 1 {
		t.Fatalf("incomplete media check: %+v", step)
	}
	report, _ := json.Marshal(step)
	if strings.Contains(string(report), "private") || strings.Contains(string(report), server.URL) {
		t.Fatal("probe report exposed playback data")
	}
}

func TestMediaProbeDoesNotAcceptHTMLAsVideoAndReleasesFailedSessions(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "<html>private verification page</html>") }))
	defer server.Close()
	client := &mediaClient{address: server.URL + "/video.mp4"}
	step := probeMedia(context.Background(), client, "source", "id", json.RawMessage(`{"id":"chapter"}`))
	if step.Status != "failed" || step.Reason != "non_media_body" || client.releases != 1 {
		t.Fatalf("HTML counted as playable media: %+v", step)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	step = probeMedia(ctx, client, "source", "id", nil)
	if step.Status != "skipped" || step.Reason != "budget" {
		t.Fatal("cancelled probe attempted media", step)
	}
}
