package app

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"net/http"
	"testing"
)

func TestMobileSavedDramaCoverRecovery(t *testing.T) {
	var plain bytes.Buffer
	if err := png.Encode(&plain, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for _, source := range []string{sourceHuangdou, sourceHuangguoAI} {
		for _, expired := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/expired=%t", source, expired), func(t *testing.T) {
				c, err := NewMobileClient(t.TempDir())
				if err != nil {
					t.Fatal(err)
				}
				defer c.Close()
				details, images := 0, 0
				c.downloader.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
					switch r.URL.Path {
					case "/expired":
						return rankingHTTPResponse(r, 403, "expired"), nil
					case "/api/drama/detail":
						details++
						return rankingHTTPResponse(r, 200, `{"data":{"id":"target","name":"fixture","img_y":"https://pic.zdmhyg.cn/art"}}`), nil
					case "/detail/target/":
						details++
						return rankingHTTPResponse(r, 200, `<img data-src="https://pic.zdmhyg.cn/wrong"><div class="hg-web-detail__poster"><img src="placeholder.png" data-src="https://pic.zdmhyg.cn/art"></div>`), nil
					case "/art":
						images++
						return rankingHTTPResponse(r, 200, plain.String()), nil
					default:
						t.Errorf("unexpected request path: %s", r.URL.Path)
						return rankingHTTPResponse(r, 404, ""), nil
					}
				})
				for range 2 {
					request := map[string]string{"method": "cover", "id": providerDramaID(source, "target")}
					if expired {
						request["url"] = "https://pic.zdmhyg.cn/expired"
					}
					raw, _ := json.Marshal(request)
					response, err := c.Call(string(raw))
					if err != nil {
						t.Fatal(err)
					}
					var data struct {
						Data string `json:"data"`
					}
					if err := json.Unmarshal([]byte(response), &data); err != nil {
						t.Fatal(err)
					}
					decoded, err := base64.StdEncoding.DecodeString(data.Data)
					if err != nil || !bytes.Equal(decoded, plain.Bytes()) {
						t.Fatal("cover differs")
					}
				}
				if details != 1 || images != 1 {
					t.Fatalf("cache not shared: details=%d images=%d", details, images)
				}
			})
		}
	}
}
