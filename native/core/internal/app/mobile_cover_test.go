package app

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"net/http"
	"strings"
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

func TestHuangguoCoverHostValidation(t *testing.T) {
	for _, address := range []string{
		"https://pic.tuafjz.cn/upload/image.jpg?auth_key=fixture",
		"https://pic.zdmhyg.cn/upload/image.jpg",
	} {
		if got, ok := buildImageURL(address); !ok || got != address {
			t.Fatalf("supported cover rejected or modified: %q", got)
		}
		if imageReferer(address) != "https://huangguoai.com/" {
			t.Fatal("incorrect Huangguo referer")
		}
	}
	for _, address := range []string{
		"https://pic.tuafjz.cn.evil.example/image.jpg",
		"https://evilpic.tuafjz.cn/image.jpg",
		"https://tuafjz.cn/image.jpg",
		"http://pic.tuafjz.cn/image.jpg",
		"https://pic.tuafjz.cn:8080/image.jpg",
		"https://user@pic.tuafjz.cn/image.jpg",
	} {
		if _, ok := buildImageURL(address); ok {
			t.Fatalf("unsupported cover accepted: %s", address)
		}
	}
}

// Exercise the exact mobile catalog -> cover request contract, including saved
// relative URLs and bare legacy IDs. These must not enter provider-ID recovery.
func TestMobileLegacyCategoryCovers(t *testing.T) {
	var plain bytes.Buffer
	if err := png.Encode(&plain, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct{ category, path, host string }{
		{"🔥黄果原创", "cf230705/image/fixture-original.jpg", "zzzznnn.lkkwip.cn"},
		{"AI魔改", "k12p/c92a/fixture-remix.jpg", "zzzznnn.lkkwip.cn"},
		{"AI成人漫剧", "/cf230705/image/fixture-comic.jpg", "zzzznnn.lkkwip.cn"},
		{"AI成人短剧", "k12p/c92a/fixture-drama.jpg?key=fixture", "zzzznnn.lkkwip.cn"},
		{"上传路径", "upload_01/upload/fixture.jpg", "pic.zdmhyg.cn"},
	} {
		t.Run(item.category, func(t *testing.T) {
			c, err := NewMobileClient(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			encrypted := append([]byte(nil), plain.Bytes()...)
			decryptImageHeader(encrypted) // The legacy header cipher is symmetric XOR.
			if item.host == "pic.zdmhyg.cn" {
				padded := pkcs7Pad(plain.Bytes(), aes.BlockSize)
				encrypted = make([]byte, len(padded))
				block, _ := aes.NewCipher([]byte("f5d965df75336270"))
				cipher.NewCBCEncrypter(block, []byte("97b60394abc2fbe1")).CryptBlocks(encrypted, padded)
			}
			calls := 0
			c.downloader.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
				calls++
				want := "https://" + item.host + "/" + strings.TrimLeft(item.path, "/")
				if r.URL.String() != want {
					t.Fatalf("cover URL = %s, want %s (must not request details)", r.URL, want)
				}
				if r.Header.Get("Referer") != imageReferer(want) || r.Header.Get("User-Agent") == "" {
					t.Fatal("missing image headers")
				}
				return rankingHTTPResponse(r, 200, string(encrypted)), nil
			})
			row := mobileDramas([]Drama{{ID: "12345", Source: "cloudfront", Title: "fixture", ChannelName: item.category, Cover: item.path}})[0]
			if row["source"] != "huangguo" || row["category"] != item.category {
				t.Fatal("unexpected mobile catalog mapping")
			}
			request, _ := json.Marshal(map[string]any{"method": "cover", "id": row["id"], "url": row["cover"]})
			for range 2 {
				raw, err := c.Call(string(request))
				if err != nil {
					t.Fatal(err)
				}
				var result struct {
					Data        string `json:"data"`
					ContentType string `json:"contentType"`
				}
				if err := json.Unmarshal([]byte(raw), &result); err != nil {
					t.Fatal(err)
				}
				decoded, err := base64.StdEncoding.DecodeString(result.Data)
				if err != nil || !bytes.Equal(decoded, plain.Bytes()) || result.ContentType != "image/png" {
					t.Fatal("mobile cover did not return decoded PNG")
				}
			}
			if calls != 1 {
				t.Fatalf("cover cache made %d requests", calls)
			}
		})
	}
}

func TestMobileLegacyCoverRecovery(t *testing.T) {
	for _, initial := range []string{"", "https://zzzznnn.lkkwip.cn/expired.jpg"} {
		for _, mismatch := range []bool{false, true} {
			t.Run(fmt.Sprintf("missing=%t/mismatch=%t", initial == "", mismatch), func(t *testing.T) {
				c, err := NewMobileClient(t.TempDir())
				if err != nil {
					t.Fatal(err)
				}
				defer c.Close()
				c.downloader.cfg.APIBase = "https://legacy.example.test"
				c.downloader.cfg.Token = "fixture-token"
				c.downloader.cfg.InterfaceKey = fixtureLegacyProtocol.InterfaceKey
				c.downloader.cfg.ParamKey = fixtureLegacyProtocol.ParamKey
				c.downloader.cfg.ParamIV = fixtureLegacyProtocol.ParamIV
				var plain bytes.Buffer
				if err := png.Encode(&plain, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
					t.Fatal(err)
				}
				var details, images int
				c.downloader.client.Transport = rankingTransport(func(r *http.Request) (*http.Response, error) {
					switch r.URL.Path {
					case "/expired.jpg":
						return rankingHTTPResponse(r, 403, "expired"), nil
					case "/api/app/playlet/detail/12345":
						details++
						id := "12345"
						if mismatch {
							id = "67890"
						}
						return legacyFixtureResponse(r, Drama{ID: id, Cover: "cf230705/image/recovered.jpg"}), nil
					case "/cf230705/image/recovered.jpg":
						images++
						if r.URL.Host != "zzzznnn.lkkwip.cn" {
							t.Fatal("wrong recovered cover host")
						}
						return rankingHTTPResponse(r, 200, plain.String()), nil
					default:
						t.Errorf("unexpected request: %s", r.URL.Path)
						return rankingHTTPResponse(r, 404, "unexpected"), nil
					}
				})
				request, _ := json.Marshal(map[string]string{"method": "cover", "id": "12345", "url": initial})
				raw, err := c.Call(string(request))
				if mismatch {
					if err == nil || images != 0 {
						t.Fatal("mismatched detail accepted")
					}
					return
				}
				if err != nil {
					t.Fatal(err)
				}
				var response struct {
					Data string `json:"data"`
				}
				if err := json.Unmarshal([]byte(raw), &response); err != nil {
					t.Fatal(err)
				}
				decoded, err := base64.StdEncoding.DecodeString(response.Data)
				if err != nil || !bytes.Equal(decoded, plain.Bytes()) || details != 1 || images != 1 {
					t.Fatal("legacy saved cover recovery failed")
				}
			})
		}
	}
}
