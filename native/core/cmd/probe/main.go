// probe exercises the same embedded API used on devices, without a UI server.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"juku/mobile"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func main() {
	query := flag.String("query", "", "inspect source search")
	genre := flag.String("genre", "", "inspect Hongguo recommendations: short_play, comic_series, ai_series")
	source := flag.String("source", "hongguo", "source ID, including chaoguo, miguo and shuangguo")
	detailProbe := flag.Bool("detail", false, "fetch the first drama's details and chapters without reading media")
	mediaProbe := flag.Bool("media", false, "resolve one episode and fetch only its first 1024 bytes")
	decodeProbe := flag.Bool("decode", false, "prepare and decode one full episode using a locally installed ffmpeg")
	pages := flag.Int("pages", 1, "number of catalog pages to inspect")
	covers := flag.Bool("covers", false, "fetch and decode up to three cover images through the mobile facade")
	board := flag.String("board", "", "inspect a ranking board instead of the catalog")
	flag.Parse()
	if (*query != "" && (*board != "" || *genre != "")) || (*genre != "" && (*source != "hongguo" || *board != "" || *pages != 1)) {
		fmt.Fprintln(os.Stderr, "query cannot combine with board/genre; genre requires hongguo, one page and no board")
		os.Exit(2)
	}
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
	if *board != "" {
		request, _ = json.Marshal(map[string]string{"method": "ranking", "board": *board})
	}
	if *query != "" {
		request, _ = json.Marshal(map[string]string{"method": "search", "source": *source, "query": *query})
	}
	if *genre != "" {
		request, _ = json.Marshal(map[string]any{"method": "recommendations", "recommendation": map[string]string{"genre": *genre}})
	}
	result, err := c.Call(string(request))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var rows struct {
		Items   []json.RawMessage `json:"items"`
		Warning string            `json:"warning"`
		HasMore bool              `json:"hasMore"`
	}
	if err := json.Unmarshal([]byte(result), &rows); err != nil {
		panic(err)
	}
	if *board != "" {
		for i, raw := range rows.Items {
			var item struct {
				Drama json.RawMessage `json:"drama"`
			}
			if err := json.Unmarshal(raw, &item); err != nil {
				panic(err)
			}
			rows.Items[i] = item.Drama
		}
	}
	fmt.Printf("source=%s items=%d warning=%s\n", *source, len(rows.Items), rows.Warning)
	unique := map[string]bool{}
	count := func(items []json.RawMessage) {
		for _, raw := range items {
			var item struct {
				ID string `json:"id"`
			}
			_ = json.Unmarshal(raw, &item)
			unique[item.ID] = true
		}
	}
	count(rows.Items)
	fmt.Printf("page=1 unique=%d hasMore=%t\n", len(unique), rows.HasMore)
	more := rows.HasMore
	for page := 2; page <= *pages && more; page++ {
		request, _ = json.Marshal(map[string]any{"method": "catalog", "source": *source, "page": page})
		if *query != "" {
			request, _ = json.Marshal(map[string]any{"method": "search", "source": *source, "query": *query, "page": page})
		}
		if *board != "" {
			request, _ = json.Marshal(map[string]any{"method": "ranking", "board": *board, "page": page})
		}
		raw, callErr := c.Call(string(request))
		if callErr != nil {
			fmt.Fprintln(os.Stderr, callErr)
			os.Exit(1)
		}
		var next struct {
			Items   []json.RawMessage `json:"items"`
			HasMore bool              `json:"hasMore"`
			Warning string            `json:"warning"`
		}
		if err := json.Unmarshal([]byte(raw), &next); err != nil {
			panic(err)
		}
		if *board != "" {
			for i, raw := range next.Items {
				var item struct {
					Drama json.RawMessage `json:"drama"`
				}
				if err := json.Unmarshal(raw, &item); err != nil {
					panic(err)
				}
				next.Items[i] = item.Drama
			}
		}
		count(next.Items)
		more = next.HasMore
		fmt.Printf("page=%d returned=%d unique=%d hasMore=%t warning=%s\n", page, len(next.Items), len(unique), more, next.Warning)
	}
	if *covers {
		for index, raw := range rows.Items[:min(3, len(rows.Items))] {
			var item struct {
				Cover string `json:"cover"`
				ID    string `json:"id"`
			}
			_ = json.Unmarshal(raw, &item)
			request, _ = json.Marshal(map[string]string{"method": "cover", "url": item.Cover, "id": item.ID})
			value, err := c.Call(string(request))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			var result struct {
				Data        string `json:"data"`
				ContentType string `json:"contentType"`
			}
			if err := json.Unmarshal([]byte(value), &result); err != nil {
				panic(err)
			}
			bytes, err := base64.StdEncoding.DecodeString(result.Data)
			if err != nil {
				panic(err)
			}
			fmt.Printf("cover=%d bytes=%d type=%s\n", index+1, len(bytes), result.ContentType)
		}
	}
	if (!*detailProbe && !*mediaProbe && !*decodeProbe) || len(rows.Items) == 0 {
		return
	}
	var drama struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(rows.Items[0], &drama); err != nil {
		panic(err)
	}
	fmt.Printf("detailID=%s\n", drama.ID)
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
	fmt.Printf("detail=passed episodes=%d\n", len(chapters.Chapters))
	if !*mediaProbe && !*decodeProbe {
		return
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
	if *decodeProbe {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		output := filepath.Join(dir, "prepared.mp4")
		args := []string{"-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-rw_timeout", "20000000"}
		var headers string
		for name, value := range media.Headers {
			headers += name + ": " + value + "\r\n"
		}
		if headers != "" {
			args = append(args, "-headers", headers)
		}
		if media.ContentKey != "" {
			args = append(args, "-decryption_key", media.ContentKey)
		}
		if media.HLS {
			args = append(args, "-allowed_extensions", "ALL")
		}
		args = append(args, "-i", media.URL, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart", output)
		// Never echo arguments or native logs containing signed URLs and keys.
		if err := exec.CommandContext(ctx, "ffmpeg", args...).Run(); err != nil {
			fmt.Fprintln(os.Stderr, "media preparation failed (credentials omitted)")
			os.Exit(1)
		}
		if err := exec.CommandContext(ctx, "ffmpeg", "-v", "error", "-xerror", "-i", output, "-f", "null", "-").Run(); err != nil {
			fmt.Fprintln(os.Stderr, "prepared media decoding failed")
			os.Exit(1)
		}
		fmt.Println("fullEpisodePreparation=passed fullEpisodeDecode=passed")
	}
}
