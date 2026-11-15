package app

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func TestHongguoPlayerSigningUpstreamVectors(t *testing.T) {
	// Generated independently by the pinned upstream Node signer, including
	// signed int32 entropy, large timestamps and the actual gzip wire body.
	raw, err := os.ReadFile("testdata/hongguo_player_signing.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Query, Body string
		TS          uint32
		RandField   int64
		Headers     map[string]string
	}
	if err := json.Unmarshal(raw, &cases); err != nil || len(cases) != 18 {
		t.Fatal("missing independent player vectors", err)
	}
	for i, c := range cases {
		body, err := base64.StdEncoding.DecodeString(c.Body)
		if err != nil {
			t.Fatal(err)
		}
		if got := hongguoPlayerArgus(c.Query, body, c.TS, uint32(c.RandField)); got != c.Headers["x-argus"] {
			t.Errorf("case %d: Argus differs from upstream", i)
		}
		if got := hongguoAppLadon(c.TS, 0x04030201, "1611921764", "8662"); got != c.Headers["x-ladon"] {
			t.Errorf("case %d: Ladon differs from upstream", i)
		}
		if len(body) > 0 {
			digest := md5.Sum(body)
			if hex.EncodeToString(digest[:]) != c.Headers["x-ss-stub"] {
				t.Fatal("wire body no longer matches upstream stub")
			}
		}
	}
}
