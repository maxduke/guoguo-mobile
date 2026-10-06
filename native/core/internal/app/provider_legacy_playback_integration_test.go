package app

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLegacySourceKeyThroughMobileProxyLocalFFmpeg(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("local FFmpeg is unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=3", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18", "-threads", "1", "-f", "mpegts", "pipe:1")
	var log bytes.Buffer
	command.Stderr = &log
	segment, err := command.Output()
	if err != nil {
		t.Fatalf("generate local video fixture: %v %s", err, log.String())
	}
	sourceKey := []byte("0123456789abcdef")
	block, err := aes.NewCipher(sourceKey)
	if err != nil {
		t.Fatal(err)
	}
	plain := append([]byte(nil), segment...)
	segment = pkcs7Pad(segment, aes.BlockSize)
	cipher.NewCBCEncrypter(block, make([]byte, aes.BlockSize)).CryptBlocks(segment, segment)
	playlist := "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-KEY:METHOD=AES-128,URI=\"/api/app/vid/sec\",IV=0x00000000000000000000000000000000\n#EXTINF:3.0,\n/fixture.ts\n#EXT-X-ENDLIST\n"
	var keyRequests, segmentRequests atomic.Int32
	d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		var body []byte
		switch request.URL.Path {
		case "/api/app/vid/h5/m3u8/generated-video":
			return rankingHTTPResponse(request, http.StatusOK, playlist), nil
		case "/api/app/vid/sec":
			keyRequests.Add(1)
			body = sourceKey
		case "/fixture.ts":
			segmentRequests.Add(1)
			body = segment
		default:
			t.Errorf("unexpected request: %s", request.URL.Path)
			return nil, errors.New("only generated fixture resources are allowed")
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(body)), ContentLength: int64(len(body)), Header: http.Header{"Content-Type": {"application/octet-stream"}}, Request: request}, nil
	})
	d.cfg.Retries = 1
	d.cfg.Token = "own-fixture-token"
	d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.InterfaceKey, fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	task := Task{DramaID: "legacy-drama", Chapter: Chapter{ID: "episode-1", VideoURL: "generated-video"}}
	media, key, err := d.resolvePlaybackMedia(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := d.newHLSProxy(ctx, media, key)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	read := func(address string) []byte {
		response, err := http.Get(address)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, err := io.ReadAll(response.Body)
		if err != nil || response.StatusCode != http.StatusOK {
			t.Fatalf("proxy read: %v HTTP %d", err, response.StatusCode)
		}
		return data
	}
	rewritten := string(read(proxy.root))
	match := hlsURIAttribute.FindStringSubmatch(rewritten)
	if len(match) != 2 {
		t.Fatal("proxy omitted source key")
	}
	fetchedKey := read(match[1])
	if !bytes.Equal(fetchedKey, sourceKey) {
		t.Fatal("proxy changed source key")
	}
	var address string
	for _, line := range strings.Split(rewritten, "\n") {
		if line != "" && !strings.HasPrefix(line, "#") {
			address = line
			break
		}
	}
	encrypted := read(address)
	if !bytes.Equal(encrypted, segment) {
		t.Fatal("proxy changed encrypted media")
	}
	decoder, err := aes.NewCipher(fetchedKey)
	if err != nil {
		t.Fatal(err)
	}
	cipher.NewCBCDecrypter(decoder, make([]byte, aes.BlockSize)).CryptBlocks(encrypted, encrypted)
	if !bytes.Equal(encrypted[:len(plain)], plain) {
		t.Fatal("source key did not decrypt media")
	}
	input := filepath.Join(t.TempDir(), "source.ts")
	if err := os.WriteFile(input, encrypted[:len(plain)], 0600); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "download.mp4")
	command = exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-i", input, "-c", "copy", "-y", output)
	if diagnostic, err := command.CombinedOutput(); err != nil {
		t.Fatalf("read mobile HLS proxy: %v %s", err, diagnostic)
	}
	data, err := os.ReadFile(output)
	if err != nil || len(data) < 100*1024 || !bytes.Contains(data, []byte("ftyp")) || !bytes.Contains(data, []byte("moov")) {
		t.Fatalf("invalid remuxed MP4: %v, bytes=%d", err, len(data))
	}
	if keyRequests.Load() == 0 || segmentRequests.Load() == 0 || d.cfg.AESKeyHex != "" {
		t.Fatal("mobile proxy did not use the source-managed key")
	}
}
