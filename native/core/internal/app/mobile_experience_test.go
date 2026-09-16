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
	"reflect"
	"testing"
)

func TestMobileCatalogRefreshAndRestartKeepPagination(t *testing.T) {
	calls := map[string][]int{}
	transport := rankingTransport(func(request *http.Request) (*http.Response, error) {
		var payload struct {
			Offset int `json:"offset"`
			Select struct {
				Genre []string `json:"genre"`
			} `json:"select_items"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		genre := payload.Select.Genre[0]
		calls[genre] = append(calls[genre], payload.Offset)
		genreIndex := 0
		for i, item := range hongguoAppGenres {
			if item.key == genre {
				genreIndex = i
			}
		}
		id := fmt.Sprintf("%d", 700000+genreIndex*100+payload.Offset)
		body, _ := json.Marshal(map[string]any{"data": map[string]any{
			"next_offset": payload.Offset + 18, "has_more": payload.Offset < 36, "session_id": "fixture",
			"video_data": []any{map[string]any{"series_id": id, "series_title": "fixture " + id, "series_cover": coverAddressFixture}},
		}})
		return rankingHTTPResponse(request, 200, string(body)), nil
	})
	c, err := NewMobileClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.downloader.client.Transport = transport
	call := func(client *MobileClient, page int, wantMore bool) {
		t.Helper()
		raw, err := client.Call(fmt.Sprintf(`{"method":"catalog","source":"hongguo","page":%d}`, page))
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Items   []any `json:"items"`
			HasMore bool  `json:"hasMore"`
		}
		if err := json.Unmarshal([]byte(raw), &result); err != nil {
			t.Fatal(err)
		}
		if len(result.Items) != 3 || result.HasMore != wantMore {
			t.Fatalf("unexpected page: %s", raw)
		}
	}
	call(c, 1, true)
	call(c, 2, true)
	call(c, 1, true)
	restarted, err := NewMobileClient(c.downloader.cfg.dataDirectory())
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	restarted.downloader.client.Transport = transport
	call(restarted, 3, false)
	for genre, offsets := range calls {
		if !reflect.DeepEqual(offsets, []int{0, 18, 0, 36}) {
			t.Fatalf("%s restarted pagination: %v", genre, offsets)
		}
	}
}

func TestMobileEncryptedCoverUsesHeadersAndCachesDecodedBytes(t *testing.T) {
	var plain bytes.Buffer
	if err := png.Encode(&plain, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	padding := aes.BlockSize - plain.Len()%aes.BlockSize
	padded := append(append([]byte(nil), plain.Bytes()...), bytes.Repeat([]byte{byte(padding)}, padding)...)
	encrypted := make([]byte, len(padded))
	block, _ := aes.NewCipher([]byte("f5d965df75336270"))
	cipher.NewCBCEncrypter(block, []byte("97b60394abc2fbe1")).CryptBlocks(encrypted, padded)
	for _, host := range []string{"pic.zdmhyg.cn", "pic.tuafjz.cn"} {
		t.Run(host, func(t *testing.T) {
			c, err := NewMobileClient(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			requests := 0
			c.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
				requests++
				if request.Header.Get("Referer") != "https://huangguoai.com/" || request.Header.Get("User-Agent") == "" {
					t.Fatal("missing cover headers")
				}
				return rankingHTTPResponse(request, 200, string(encrypted)), nil
			})
			for range 2 {
				raw, err := c.Call(fmt.Sprintf(`{"method":"cover","url":"https://%s/fixture"}`, host))
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
					t.Fatal("cover not decoded")
				}
			}
			if requests != 1 {
				t.Fatalf("cover cache made %d requests", requests)
			}
			if _, err := c.Call(`{"method":"cover","url":"https://unknown.example/fixture"}`); err == nil {
				t.Fatal("unrecognized image host accepted")
			}
		})
	}

}
