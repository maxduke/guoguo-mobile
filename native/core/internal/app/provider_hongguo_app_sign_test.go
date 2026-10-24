package app

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"testing"
	"time"
)

func TestHongguoAppSigningUpstreamVectors(t *testing.T) {
	// Independent Node oracle, pinned by blob SHA in UPSTREAM.md: twelve upstream
	// cases cover both body forms and all four cipher tables; two bind local profiles.
	data, err := os.ReadFile("testdata/hongguo_signing.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []struct {
		TS                           uint32  `json:"ts"`
		URL                          string  `json:"url"`
		Body                         *string `json:"body"`
		Hash, Gorgon, Helios, Medusa string
		DeviceID                     string `json:"deviceId"`
		Version                      string `json:"version"`
	}
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	if len(fixtures) != 14 {
		t.Fatal("upstream signing vectors are missing")
	}
	for i, fixture := range fixtures {
		t.Run(strconv.Itoa(i), func(t *testing.T) {
			address, err := url.Parse(fixture.URL)
			if err != nil {
				t.Fatal(err)
			}
			query := address.RawQuery
			var body []byte
			bodyHash := [16]byte{}
			if fixture.Body != nil {
				body = []byte(*fixture.Body)
				bodyHash = md5.Sum(body)
			}
			queryHash := hongguoSM3([]byte(query))
			if (hongguoSignHashIV(queryHash[:], bodyHash[:], fixture.TS)&15)%3 != 0 {
				t.Fatal("upstream fixture no longer selects hash branch 0")
			}
			if got := hex.EncodeToString(hongguoSignHash(queryHash[:], bodyHash[:], fixture.TS)); got != fixture.Hash {
				t.Errorf("hash mismatch: %s", got)
			}
			if got := hongguoAppGorgon(query, body, fixture.TS, 42131); got != fixture.Gorgon {
				t.Error("Gorgon differs from upstream")
			}
			seed := uint32(17)
			random := func() uint32 { seed = seed*1664525 + 1013904223; return seed }
			if got := hongguoAppHelios(fixture.TS, random()); got != fixture.Helios {
				t.Error("Helios differs from upstream")
			}
			signer := hongguoAppSigner{
				deviceID: firstNonEmpty(fixture.DeviceID, "1905892595378490"),
				version:  firstNonEmpty(fixture.Version, "7.1.3.32"),
				now:      time.Unix(int64(fixture.TS), 0), random: random,
			}
			if got := signer.medusa(query, body, fixture.TS); got != fixture.Medusa {
				t.Error("Medusa differs from upstream")
			}
		})
	}
}

func TestHongguoAppSignatureBindsPreparedQueryAndBody(t *testing.T) {
	now := time.Unix(1800500000, 123000000)
	for _, body := range [][]byte{nil, []byte(`{"series_id":"700001"}`)} {
		request := httptest.NewRequest("POST", "https://api5-normal-sinfonlineb.fqnovel.com/api?device_id=700001&version_name=7.3.5.32&query=%E7%9F%AD%E5%89%A7", nil)
		if err := signHongguoRequest(request, body, now); err != nil {
			t.Fatal(err)
		}
		query := request.URL.Query()
		ticket, err := strconv.ParseInt(query.Get("_rticket"), 10, 64)
		if err != nil || ticket < now.UnixMilli() || ticket >= now.UnixMilli()+128 || query.Get("ts") != "1800500000" || request.Header.Get("X-SS-Req-Ticket") != query.Get("_rticket") {
			t.Fatal("signature and prepared request tickets disagree")
		}
		for _, name := range []string{"X-Gorgon", "X-Khronos", "X-Ladon", "X-Argus", "X-Helios", "X-Medusa"} {
			if request.Header.Get(name) == "" {
				t.Errorf("missing app signature header %s", name)
			}
		}
		bodyHash := [16]byte{}
		if body != nil {
			bodyHash = md5.Sum(body)
			if request.Header.Get("X-SS-STUB") != fmt.Sprintf("%X", bodyHash) {
				t.Error("body stub does not match the serialized payload")
			}
		} else if request.Header.Get("X-SS-STUB") != "" {
			t.Error("bodyless request acquired a body stub")
		}
		hash := hongguoSM3([]byte(request.URL.RawQuery))
		if (hongguoSignHashIV(hash[:], bodyHash[:], uint32(now.Unix()))&15)%3 != 0 {
			t.Error("prepared request selected an unsupported signature branch")
		}
	}
}
