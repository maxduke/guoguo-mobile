package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestHuangguoLinesRejectUnpublishedOriginsBeforeNetwork(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		return nil, errors.New("must not request")
	})
	d.huangguoAIRoutes = []string{"https://line.example.org"}
	for _, candidate := range []string{
		"http://line.example.org", "https://127.0.0.1", "https://192.168.1.1", "https://user:password@line.example.org",
		"https://line.example.org/path", "https://line.example.org/?token=private", "https://line.example.org:8443", "https://unpublished.example.org",
	} {
		if _, err := d.probeHuangguoLine(context.Background(), candidate); err == nil {
			t.Errorf("probed untrusted line %s", candidate)
		}
		if _, err := d.selectHuangguoLine(context.Background(), candidate); err == nil {
			t.Errorf("selected untrusted line %s", candidate)
		}
	}
	if calls.Load() != 0 {
		t.Fatal("invalid line reached the network")
	}
}

func TestHuangguoLineProbeChecksAPIAndNeverSelectsOrClaimsMedia(t *testing.T) {
	for _, valid := range []bool{true, false} {
		t.Run(map[bool]string{true: "api", false: "homepage-only"}[valid], func(t *testing.T) {
			d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
				if huangguoEnvelopePath(t, request) != "/api/videos?page=1&size=1" {
					t.Error("probe did not check actual catalog API")
				}
				if !valid {
					return rankingHTTPResponse(request, 200, "<html>reachable homepage</html>"), nil
				}
				return huangguoAPIResponse(request, huangguoAPIPageFixture), nil
			})
			d.huangguoAIRoutes = []string{"https://line.example.org"}
			d.providerHosts[sourceHuangguoAI] = "https://previous.example.org"
			result, err := d.probeHuangguoLine(context.Background(), "https://line.example.org")
			if err != nil || result["apiValid"] != valid || result["mediaChecked"] != false || result["httpStatus"] != 200 || d.huangguoLine != "" || d.providerHosts[sourceHuangguoAI] != "https://previous.example.org" {
				t.Fatalf("probe changed routing or overstated validation: %+v %v", result, err)
			}
		})
	}
}

func TestHuangguoLineSelectionPersistsWithoutChangingRecordsOrIdentities(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	d := c.downloader
	const selected = "https://line.example.org"
	d.huangguoAIRoutes = []string{selected}
	c.known = []Drama{{ID: "huangguoai:501", Source: sourceHuangguoAI, Title: "保留作品"}}
	file := filepath.Join(d.cfg.dataDirectory(), "records.json")
	if err := os.WriteFile(file, []byte("record fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{selected, "", selected} {
		result, err := d.selectHuangguoLine(context.Background(), line)
		if err != nil || result["selected"] != line {
			t.Fatal("selection failed", result, err)
		}
		reopened, err := NewMobileClient(d.cfg.dataDirectory())
		if err != nil {
			t.Fatal(err)
		}
		got := reopened.downloader.huangguoLine
		reopened.Close()
		if got != line {
			t.Fatalf("selection did not survive restart: %q", got)
		}
	}
	if raw, _ := os.ReadFile(file); string(raw) != "record fixture" || len(c.known) != 1 || c.known[0].ID != "huangguoai:501" {
		t.Fatal("line setting altered records or identity")
	}
}

func TestHuangguoLineFailedSaveKeepsCurrentSelection(t *testing.T) {
	d := rankingTestDownloader(t, nil)
	d.huangguoLine = "https://previous.example.org"
	d.huangguoAIRoutes = []string{"https://next.example.org"}
	if err := os.Mkdir(filepath.Join(d.cfg.dataDirectory(), "huangguo-line.json"), 0700); err != nil {
		t.Fatal(err)
	}
	_, err := d.selectHuangguoLine(context.Background(), "https://next.example.org")
	if err == nil || strings.Contains(err.Error(), d.cfg.dataDirectory()) || d.huangguoLine != "https://previous.example.org" {
		t.Fatal("failed save installed selection or exposed path", err)
	}
	leftovers, _ := filepath.Glob(filepath.Join(d.cfg.dataDirectory(), ".huangguo-line-*.tmp"))
	if len(leftovers) != 0 {
		t.Fatal("failed save leaked temporary preferences")
	}
}

func TestHuangguoLineLateRequestCannotOverwriteNewSelection(t *testing.T) {
	started, finish := make(chan struct{}), make(chan struct{})
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		huangguoEnvelopePath(t, request)
		if request.URL.Host == "old.example.org" {
			close(started)
			select {
			case <-finish:
			case <-request.Context().Done():
				return nil, request.Context().Err()
			}
		} else if request.URL.Host != "next.example.org" {
			t.Error("unexpected route")
		}
		return huangguoAPIResponse(request, huangguoAPIPageFixture), nil
	})
	d.huangguoLine = "https://old.example.org"
	d.huangguoAIRoutes = []string{"https://old.example.org", "https://next.example.org"}
	done := make(chan error, 1)
	go func() { _, _, err := d.searchHuangguoAI(context.Background(), "测试", 1); done <- err }()
	<-started
	_, selectErr := d.selectHuangguoLine(context.Background(), "https://next.example.org")
	close(finish)
	if err := <-done; err != nil || selectErr != nil {
		t.Fatal("in-flight request or selection failed", err, selectErr)
	}
	if d.huangguoLine != "https://next.example.org" {
		t.Fatal("late response reverted user selection")
	}
	if _, _, err := d.searchHuangguoAI(context.Background(), "测试", 1); err != nil {
		t.Fatal(err)
	}
}

func TestMobileHuangguoLineCommandsUseTheExistingBridge(t *testing.T) {
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.downloader.huangguoAIRoutes = []string{"https://line.example.org"}
	for _, request := range []string{`{"method":"huangguoLines"}`, `{"method":"huangguoLineSelect","url":"https://line.example.org"}`} {
		raw, err := c.Call(request)
		var result struct {
			Items    []huangguoLine `json:"items"`
			Selected string         `json:"selected"`
		}
		if err != nil || json.Unmarshal([]byte(raw), &result) != nil || len(result.Items) != 1 {
			t.Fatal("line command not reachable through bridge", raw, err)
		}
	}
}
