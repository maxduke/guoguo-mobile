package app

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func guanguoFixtureEnvelope(t *testing.T, addresses map[string]string) (string, string) {
	t.Helper()
	key, iv := bytes.Repeat([]byte{7}, 32), bytes.Repeat([]byte{3}, aes.BlockSize)
	plain, err := json.Marshal(addresses)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(key)
	padded := pkcs7Pad(plain, aes.BlockSize)
	ciphertext := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(ciphertext, padded)
	return base64.StdEncoding.EncodeToString(append(iv, ciphertext...)), base64.StdEncoding.EncodeToString(key)
}

func TestGuanguoH5MetadataAndSelectedEpisodeKeepIdentity(t *testing.T) {
	const id = "110000042659853849"
	calls, device := 0, ""
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		query := r.URL.Query()
		if r.Method != http.MethodGet || r.URL.Path != "/drama/play/h5/detail" || query.Get("oneId") != id || query.Get("os_type") != "2" || r.Referer() != guanguoH5Referer {
			t.Error("request did not follow the H5 identity contract")
		}
		if device == "" {
			device = query.Get("deviceId")
		}
		if len(device) != 32 || device != query.Get("deviceId") {
			t.Error("device identity changed within the source session")
		}
		episode, _ := strconv.Atoi(query.Get("playOrder"))
		encoded, key := guanguoFixtureEnvelope(t, map[string]string{
			"super":  fmt.Sprintf("https://media.example.org/%d-super.mp4", episode),
			"high":   fmt.Sprintf("https://media.example.org/%d-high.mp4", episode),
			"normal": fmt.Sprintf("https://media.example.org/%d-normal.mp4", episode),
		})
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "data": map[string]any{
			"oneId": id, "title": "样本", "episodeCount": 81, "subjectTags": []string{"战神"}, "h5PlayUrl": encoded, "h5PlayKey": key,
		}})
	})
	d.providerHosts[sourceGuanguo] = server.URL
	drama, chapters, err := d.fetchGuanguoDetail(context.Background(), id)
	if err != nil || len(chapters) != 81 || drama.ID != "guanguo:"+id || calls != 1 {
		t.Fatalf("metadata requested every episode or lost identity: %d %v", calls, err)
	}
	if chapters[1].ID != "guanguo:"+id+":2" || chapters[1].VideoURL != "" {
		t.Fatal("chapter cache persisted expiring playback data or changed its ID")
	}
	media, err := d.resolveDuanjuMedia(context.Background(), Task{DramaID: drama.ID, Chapter: chapters[1]})
	if err != nil || media.URL != "https://media.example.org/2-super.mp4" || media.Quality != 0 || len(media.Variants) != 2 || calls != 2 {
		t.Fatalf("selected episode/quality was not resolved independently: %+v %v", media, err)
	}
	wrong := chapters[1]
	wrong.CurrentEpisode = rawEpisode(3)
	if _, err := d.resolveDuanjuMedia(context.Background(), Task{DramaID: drama.ID, Chapter: wrong}); err == nil || calls != 2 {
		t.Fatal("mismatched chapter identity reached the network")
	}
}

func TestGuanguoH5RejectsWrongIdentityAndMalformedEnvelopes(t *testing.T) {
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(r, 200, `{"code":200,"data":{"oneId":"999","title":"other","episodeCount":2}}`), nil
	})
	if _, _, err := d.fetchGuanguoDetail(context.Background(), "123"); err == nil {
		t.Fatal("metadata for a different work was accepted")
	}
	encoded, key := guanguoFixtureEnvelope(t, map[string]string{"super": "file:///tmp/video.mp4", "high": "javascript:alert(1)"})
	for _, data := range []map[string]any{
		{"h5PlayUrl": encoded, "h5PlayKey": key},
		{"h5PlayUrl": "bad", "h5PlayKey": key},
		{"h5PlayUrl": encoded, "h5PlayKey": "bad"},
		{"h5PlayUrl": strings.Repeat("a", 256*1024+1), "h5PlayKey": key},
	} {
		if _, err := decodeGuanguoMedia(data); err == nil {
			t.Fatal("invalid playback envelope or unsafe media URL was accepted")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := d.fetchGuanguoDetail(ctx, "123"); err == nil {
		t.Fatal("cancelled H5 request was accepted")
	}
}
