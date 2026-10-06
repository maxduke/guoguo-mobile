package app

import (
	"context"
	"fmt"
	"net/http"
	"testing"
)

const coverAddressFixture = "https://p3-reading-sign.fqnovelpic.com/synthetic-cover-address?fixture=1"

func TestHongguoCoverRepairValidatesDramaIdentity(t *testing.T) {
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(request, 200, fmt.Sprintf(`{"data":{"video_data":{"series_id_str":"7000000000000000002","series_cover":%q}}}`, coverAddressFixture)), nil
	})
	patch, err := d.fetchDramaSortMetadata(context.Background(), Drama{ID: "hongguo:7000000000000000001", OnlineDate: "2026-09-01", Heat: "1", Views: "0"})
	if err == nil || bestDramaCover(patch) != "" {
		t.Fatal("cover repair accepted another drama's address")
	}
}
