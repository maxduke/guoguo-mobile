// probe exercises the same embedded API used on devices, without a UI server.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"juku/mobile"
	"net/http"
	"os"
	"time"
)

func main() {
	source := flag.String("source", "hongguo", "hongguo, huangdou or huangguo")
	mediaProbe := flag.Bool("media", false, "resolve one episode and fetch only its first 1024 bytes")
	flag.Parse()
	dir, err := os.MkdirTemp("", "guoguo-probe-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	c, err := mobile.NewClient(dir)
	if err != nil {
		panic(err)
	}
	defer c.Close()
	request, _ := json.Marshal(map[string]string{"method": "catalog", "source": *source})
	result, err := c.Call(string(request))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var rows struct {
		Items   []json.RawMessage `json:"items"`
		Warning string            `json:"warning"`
	}
	if err := json.Unmarshal([]byte(result), &rows); err != nil {
		panic(err)
	}
	fmt.Printf("source=%s items=%d warning=%s\n", *source, len(rows.Items), rows.Warning)
	if !*mediaProbe || len(rows.Items) == 0 {
		return
	}
	var drama struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(rows.Items[0], &drama); err != nil {
		panic(err)
	}
	request, _ = json.Marshal(map[string]any{"method": "chapters", "id": drama.ID})
	detail, err := c.Call(string(request))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var chapters struct {
		Chapters []json.RawMessage `json:"chapters"`
	}
	if err := json.Unmarshal([]byte(detail), &chapters); err != nil {
		panic(err)
	}
	if len(chapters.Chapters) == 0 {
		fmt.Fprintln(os.Stderr, "no episodes")
		os.Exit(1)
	}
	request, _ = json.Marshal(map[string]any{"method": "resolve", "id": drama.ID, "chapter": chapters.Chapters[0]})
	resolved, err := c.Call(string(request))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var media struct {
		URL        string            `json:"url"`
		Headers    map[string]string `json:"headers"`
		ContentKey string            `json:"contentKey"`
		HLS        bool              `json:"hls"`
	}
	if err := json.Unmarshal([]byte(resolved), &media); err != nil {
		panic(err)
	}
	req, err := http.NewRequest(http.MethodGet, media.URL, nil)
	if err != nil {
		panic("invalid media URL")
	}
	for name, value := range media.Headers {
		req.Header.Set(name, value)
	}
	req.Header.Set("Range", "bytes=0-1023")
	response, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "media request failed (URL omitted)")
		os.Exit(1)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1024))
	if err != nil || response.StatusCode >= 300 {
		fmt.Fprintf(os.Stderr, "media fetch failed: HTTP %d\n", response.StatusCode)
		os.Exit(1)
	}
	fmt.Printf("episodes=%d mediaHTTP=%d bytes=%d hls=%t encrypted=%t\n", len(chapters.Chapters), response.StatusCode, len(data), media.HLS, media.ContentKey != "")
}
