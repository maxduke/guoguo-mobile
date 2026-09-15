package mobile

import (
	"encoding/json"
	"testing"
)

func TestBridgeRejectsInvalidRequests(t *testing.T) {
	c, err := NewClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for _, raw := range []string{`{`, `{"method":"catalog","source":"other"}`, `{"method":"chapters"}`, `{"method":"resolve"}`, `{"method":"search","source":"huangdou"}`, `{"method":"unknown"}`} {
		if _, err := c.Call(raw); err == nil {
			t.Fatalf("accepted invalid request %s", raw)
		}
	}
}

func TestBoardsStayWithinSource(t *testing.T) {
	c, err := NewClient(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for _, source := range []string{"hongguo", "huangdou", "huangguo"} {
		raw, err := c.Call(`{"method":"boards","source":"` + source + `"}`)
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Items []struct {
				Source string `json:"source"`
			} `json:"items"`
		}
		if err := json.Unmarshal([]byte(raw), &result); err != nil {
			t.Fatal(err)
		}
		if len(result.Items) == 0 {
			t.Fatal("missing boards")
		}
		for _, board := range result.Items {
			if board.Source != source {
				t.Fatal("cross-source board")
			}
		}
	}
}
