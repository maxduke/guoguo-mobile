package app

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"net/http"
	"sync"
	"testing"
)

func TestCoverProtocolRelativeAndLegacyMediaURL(t *testing.T) {
	for _, test := range []struct{ id, input, want string }{
		{"123", "//pic.zdmhyg.cn/upload/cover.jpg?token=a%2Fb", "https://pic.zdmhyg.cn/upload/cover.jpg?token=a%2Fb"},
		{"123", defaultCDNURL + "/upload/cover.jpg", "https://pic.zdmhyg.cn/upload/cover.jpg"},
		{"123", defaultCDNURL + "/cf230705/image/cover.jpg", "https://zzzznnn.lkkwip.cn/cf230705/image/cover.jpg"},
		{"huangdou:123", defaultCDNURL + "/upload/cover.jpg", defaultCDNURL + "/upload/cover.jpg"},
	} {
		if got := mobileCoverURL(test.id, test.input); got != test.want {
			t.Errorf("%s: got %q, want %q", test.id, got, test.want)
		}
	}
	if _, ok := buildImageURL("//127.0.0.1/private.jpg"); ok {
		t.Fatal("protocol-relative private address accepted")
	}
}

func TestSourceCoverReferers(t *testing.T) {
	var plain bytes.Buffer
	if err := png.Encode(&plain, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ source, address, referer string }{
		{"cloudfront", "https://pic.zdmhyg.cn/upload/art.jpg", "https://huangguoai.ai/"},
		{sourceHuangdou, "https://tideember.cc/art.jpg", "https://tideember.cc/home"},
		{sourceHuangdou, "https://xqjurgek.top/art.jpg", "https://xqjurgek.top/home"},
		{sourceHuangdou, "https://cdn.example.org/art.jpg", huangdouBaseURL + "/home"},
		{sourceHuangguoAI, "https://cdn.example.org/art.jpg", "https://huangguoai.ai/"},
		{sourceXingguo, "https://cdn.example.org/art.jpg", "https://xingguo.example.org/"},
	} {
		t.Run(test.source+test.address, func(t *testing.T) {
			d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
				if got := r.Header.Get("Referer"); got != test.referer {
					t.Errorf("Referer = %q, want %q", got, test.referer)
				}
				return rankingHTTPResponse(r, 200, plain.String()), nil
			})
			d.cfg.HuangguoAIURL = huangguoAIBaseURL
			d.providerHosts[sourceXingguo] = "https://xingguo.example.org"
			ctx := context.WithValue(context.Background(), coverSourceKey{}, test.source)
			if _, err := d.fetchCoverImage(ctx, test.address, decodeImageBytes, false); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSourceCoverRefererConcurrentHostUpdates(t *testing.T) {
	d := rankingTestDownloader(t, nil)
	var group sync.WaitGroup
	group.Go(func() {
		for range 1000 {
			d.providerMu.Lock()
			d.providerHosts[sourceHuangguoAI] = huangguoAIBaseURL
			d.providerMu.Unlock()
		}
	})
	ctx := context.WithValue(context.Background(), coverSourceKey{}, sourceXingguo)
	for range 1000 {
		if d.coverReferer(ctx, "https://cdn.example.org/art.jpg") == "" {
			t.Error("missing source referer")
		}
	}
	group.Wait()
}

func TestProviderCoverUpgradesHTTPWithoutWeakeningValidation(t *testing.T) {
	input := "http://img.novel.wsljf.xyz/novel-platform-prod/cover.jpg?key=a%2Fb"
	if got := providerCoverAddress(input, ""); got != "https://img.novel.wsljf.xyz/novel-platform-prod/cover.jpg?key=a%2Fb" {
		t.Fatalf("HTTP catalog artwork lost: %q", got)
	}
	for _, input := range []string{"http://127.0.0.1/art", "http://user@cdn.example.org/art", "http://cdn.example.org:8080/art"} {
		if got := providerCoverAddress(input, ""); got != "" {
			t.Fatalf("unsafe artwork accepted: %q", got)
		}
	}
}
