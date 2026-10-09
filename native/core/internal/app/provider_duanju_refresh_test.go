package app

import (
	"context"
	"crypto/aes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDuanjuRemovedProvidersHaveNoRegistration(t *testing.T) {
	for _, source := range []string{"wangguo", "faguo", "duanjuwangzhan", "短剧网站", "168", "xzyx168", "www.xzyx168.com"} {
		if isDuanjuProviderSource(source) || duanjuSupportsSearch(source) {
			t.Fatalf("removed provider still registered: %s", source)
		}
	}
	for _, host := range []string{"www.xzyx168.com", "xzyx168.com"} {
		if got := duanjuSourceForHost(host); got != "" {
			t.Fatalf("removed host maps to %s", got)
		}
	}
}

func TestDuanjuNiuguoTypeIDCategories(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/list" || r.URL.Query().Get("class") != "" || r.URL.Query().Get("page") != "2" {
			t.Errorf("wrong niuguo request: %s", r.URL)
		}
		if _, exists := niuguoTypeNames[r.URL.Query().Get("type_id")]; !exists {
			t.Errorf("wrong type ID: %s", r.URL)
		}
		writeNiuguoFixture(t, w, r, fmt.Sprintf(`{"data":[{"vod_id":77,"vod_name":"%s"}]}`, niuguoTypeNames[r.URL.Query().Get("type_id")]))
	})
	d.providerHosts[sourceNiuguo] = server.URL
	for _, category := range duanjuStaticCategories[sourceNiuguo] {
		if niuguoTypeNames[category.ID] != category.Name {
			t.Fatalf("wrong category mapping: %+v", category)
		}
		items, more, err := d.fetchNiuguoCatalogPage(context.Background(), 2, category.ID)
		if err != nil || !more || len(items) != 1 || items[0].DisplayTitle() != category.Name {
			t.Fatalf("category %s: items=%v more=%v err=%v", category.ID, items, more, err)
		}
	}
	if items, _, err := d.fetchNiuguoCatalogPage(context.Background(), 2, ""); err != nil || len(items) != 1 || items[0].DisplayTitle() != "短剧" {
		t.Fatalf("default type mapping: %+v %v", items, err)
	}
	if _, _, err := d.fetchNiuguoCatalogPage(context.Background(), 2, "999"); err == nil {
		t.Fatal("invalid category silently changed to short drama")
	}
}

func TestDuanjuWuguoCategoryAndSearchPagination(t *testing.T) {
	var requests []string
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.URL.Path)
		if strings.Contains(r.URL.Path, "/page/3") {
			_, _ = w.Write([]byte(`<html><body></body></html>`))
			return
		}
		_, _ = w.Write([]byte(`<div class="BrowseList_listItem"><a href="/detail/77.html" title="剧集"></a></div>`))
	})
	d.providerHosts[sourceWuguo] = server.URL
	for _, page := range []int{1, 2, 3} {
		items, more, err := d.fetchDuanjuCatalogPage(context.Background(), sourceWuguo, page, "")
		if err != nil || more != (page < 3) || len(items) != boolCount(page < 3) {
			t.Fatalf("page %d: %+v %v %v", page, items, more, err)
		}
		want := fmt.Sprintf("/index.php/vod/search/class/都市/page/%d.html", page)
		if requests[len(requests)-1] != want {
			t.Fatalf("catalog path=%s want=%s", requests[len(requests)-1], want)
		}
	}
	_, _, err := d.searchDuanjuPage(context.Background(), sourceWuguo, "逆袭", 2)
	if err != nil || requests[len(requests)-1] != "/index.php/vod/search/page/2/wd/逆袭.html" {
		t.Fatalf("independent search path: %v %v", requests, err)
	}
	if _, _, err := d.fetchDuanjuCatalogPage(context.Background(), sourceWuguo, 1, "/type/duanju.html"); err == nil {
		t.Fatal("stale category path accepted")
	}
}

func boolCount(b bool) int {
	if b {
		return 1
	}
	return 0
}

func TestDuanjuFanguoCatalogAndSearchUsePageIndex(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		page := q.Get("pageIndex")
		if r.URL.Path != "/xifan/search/getSearchList" || (q.Get("keyword") != "都市" && q.Get("keyword") != "关键词") || q.Get("offset") != "0" {
			t.Errorf("wrong fanguo request: %s", r.URL)
		}
		if page != "1" && page != "2" {
			t.Errorf("missing pageIndex: %s", r.URL)
		}
		fmt.Fprintf(w, `{"result":{"hasMore":%t,"elements":[{"contents":[{"duanjuVo":{"duanjuId":"%s","source":"legacy","title":"剧集"}},{"duanjuVo":{"duanjuId":"%s","source":"legacy","title":"重复"}}]}]}}`, page == "1", page, page)
	})
	d.providerHosts[sourceFanguo] = server.URL
	for _, search := range []bool{false, true} {
		for page := 1; page <= 2; page++ {
			var items []Drama
			var more bool
			var err error
			if search {
				items, more, err = d.searchDuanjuPage(context.Background(), sourceFanguo, "关键词", page)
			} else {
				items, more, err = d.fetchDuanjuCatalogPage(context.Background(), sourceFanguo, page, "")
			}
			if err != nil || len(items) != 1 || more != (page == 1) || items[0].SourceID != strconv.Itoa(page)+"#legacy" {
				t.Fatalf("search=%v page=%d: %+v more=%v err=%v", search, page, items, more, err)
			}
		}
	}
	if _, _, err := d.searchDuanjuPage(context.Background(), sourceFanguo, " ", 1); err == nil {
		t.Fatal("blank keyword accepted")
	}
}

func TestDuanjuMaoguoCategoriesAndNonSequentialCursor(t *testing.T) {
	var requests []string
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		requests = append(requests, q.Get("next_id"))
		sign := "operation=1playlet_privacy=1tag_id=" + q.Get("tag_id")
		if q.Get("next_id") != "" {
			sign = "next_id=" + q.Get("next_id") + sign
		}
		if q.Get("sign") != duanjuMD5(sign+duanjuMaoguoKey) {
			t.Errorf("wrong signature: %s", r.URL)
		}
		if r.URL.Path != "/api/v1/playlet/index" {
			t.Errorf("wrong category endpoint: %s", r.URL)
		}
		if q.Get("tag_id") == "0" {
			_, _ = w.Write([]byte(`{"data":{"tag_items":[{"tag_id":0,"tag_name":"推荐"},{"tag_id":-7,"tag_name":"新剧"},{"tag_id":-7,"tag_name":"重复"},{"tag_id":"bad","tag_name":"无效"}]}}`))
			return
		}
		if q.Get("tag_id") != "-7" {
			t.Errorf("negative category overwritten: %s", r.URL)
		}
		switch q.Get("next_id") {
		case "":
			_, _ = w.Write([]byte(`{"data":{"next_id":901,"list":[{"id":"1","title":"一"}]}}`))
		case "901":
			_, _ = w.Write([]byte(`{"data":{"next_id":"45003","list":[{"id":"2","title":"二"}]}}`))
		case "45003":
			_, _ = w.Write([]byte(`{"data":{"next_id":0,"list":[{"id":"3","title":"三"}]}}`))
		default:
			t.Errorf("invented cursor: %s", r.URL)
		}
	})
	d.providerHosts[sourceMaoguo] = server.URL
	categories, err := d.fetchDuanjuCategories(context.Background(), sourceMaoguo)
	if err != nil || len(categories) != 2 || categories[1].ID != "-7" || !validNativeCategory(sourceMaoguo, "-7") {
		t.Fatalf("categories=%+v err=%v", categories, err)
	}
	for page := 1; page <= 3; page++ {
		items, more, err := d.fetchDuanjuCatalogPage(context.Background(), sourceMaoguo, page, "-7")
		if err != nil || len(items) != 1 || more != (page < 3) || items[0].SourceID != strconv.Itoa(page) {
			t.Fatalf("page %d: %+v %v %v", page, items, more, err)
		}
	}
	before := len(requests)
	if items, more, err := d.fetchMaoguoCatalogPage(context.Background(), 4, "-7"); err != nil || len(items) != 0 || more || len(requests) != before {
		t.Fatalf("terminal page repeated: %+v %v %v", items, more, err)
	}
	if _, _, err := d.fetchMaoguoCatalogPage(context.Background(), 2, "-8"); err == nil || len(requests) != before {
		t.Fatal("cursor crossed category boundary")
	}
}

func TestDuanjuMaoguoCursorTerminationAndDuplicates(t *testing.T) {
	for _, tc := range []struct {
		name, first, second string
		expectError         bool
	}{
		{"numeric zero", `0`, `0`, false}, {"string zero", `"0"`, `"0"`, false}, {"empty cursor", `""`, `""`, false}, {"missing cursor", `null`, `null`, false},
		{"repeated cursor", `"901"`, `"901"`, true}, {"repeated page", `"901"`, `"902"`, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
				calls++
				next, id := tc.first, "1"
				if r.URL.Query().Get("next_id") != "" {
					next = tc.second
					if tc.name != "repeated page" {
						id = "2"
					}
				}
				fmt.Fprintf(w, `{"data":{"next_id":%s,"list":[{"id":"%s","title":"样本"}]}}`, next, id)
			})
			d.providerHosts[sourceMaoguo] = server.URL
			_, more, err := d.fetchMaoguoCatalogPage(context.Background(), 1, "")
			if err != nil || more != tc.expectError {
				t.Fatalf("first page: more=%v err=%v", more, err)
			}
			_, more, err = d.fetchMaoguoCatalogPage(context.Background(), 2, "")
			if (err != nil) != tc.expectError || more {
				t.Fatalf("second page: more=%v err=%v", more, err)
			}
			if !tc.expectError && calls != 1 {
				t.Fatalf("terminal cursor requested again: %d", calls)
			}
		})
	}
}

func TestDuanjuMaoguoCancellationAndDownloaderIsolation(t *testing.T) {
	var calls atomic.Int32
	entered := make(chan struct{}, 1)
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Query().Get("next_id") != "" {
			entered <- struct{}{}
			<-r.Context().Done()
			return
		}
		_, _ = w.Write([]byte(`{"data":{"next_id":"999","list":[{"id":"1","title":"剧"}]}}`))
	})
	d.providerHosts[sourceMaoguo] = server.URL
	if _, _, err := d.fetchMaoguoCatalogPage(context.Background(), 1, "0"); err != nil {
		t.Fatal(err)
	}
	other := &Downloader{providerHosts: map[string]string{sourceMaoguo: server.URL}}
	if _, _, err := other.fetchMaoguoCatalogPage(context.Background(), 2, "0"); err == nil || calls.Load() != 1 {
		t.Fatal("cursor leaked between downloaders")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, _, err := d.fetchMaoguoCatalogPage(ctx, 2, "0"); done <- err }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	waiting, cancelWaiting := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancelWaiting()
	if _, _, err := d.fetchMaoguoCatalogPage(waiting, 2, "0"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("waiting request ignored cancellation: %v", err)
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("inflight cancellation: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled request hung")
	}
	if calls.Load() != 2 {
		t.Fatalf("canceled request reached server: %d", calls.Load())
	}
}

func TestDuanjuXingguoCatalogFiftyAndLegacyIdentity(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("pageSize") != "50" || r.URL.Query().Get("resourceId") != "1287" {
			t.Errorf("wrong catalog request: %s", r.URL)
		}
		count := 50
		if r.URL.Query().Get("pageNum") == "2" {
			count = 1
		}
		rows := make([]map[string]any, count)
		for i := range rows {
			rows[i] = map[string]any{"id": strconv.Itoa(i + 1), "name": "样本", "introduction": "旧简介"}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"datalist": rows}})
	})
	d.providerHosts[sourceXingguo] = server.URL
	for page := 1; page <= 2; page++ {
		items, more, err := d.fetchXingguoCatalogPage(context.Background(), page, "")
		if err != nil || more != (page == 1) || len(items) == 0 || items[0].SourceID != "1@旧简介" {
			t.Fatalf("page %d: %+v %v %v", page, items, more, err)
		}
	}
	if _, _, err := d.fetchXingguoCatalogPage(context.Background(), 1, "walk"); err == nil {
		t.Fatal("full ID scan unexpectedly enabled")
	}
}

func writeNiuguoFixture(t *testing.T, w http.ResponseWriter, r *http.Request, body string) {
	t.Helper()
	block, err := aes.NewCipher(niuguoDecryptKey(r.URL.RequestURI()))
	if err != nil {
		t.Errorf("fixture cipher: %v", err)
		return
	}
	padded := pkcs7Pad([]byte(body), aes.BlockSize)
	encrypted := make([]byte, len(padded))
	for offset := 0; offset < len(padded); offset += aes.BlockSize {
		block.Encrypt(encrypted[offset:offset+aes.BlockSize], padded[offset:offset+aes.BlockSize])
	}
	_, _ = w.Write([]byte(base64.StdEncoding.EncodeToString(encrypted)))
}

func TestDuanjuMaoguoPreservesLargeNumericCursors(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		cursor := r.URL.Query().Get("next_id")
		if cursor == "" {
			_, _ = w.Write([]byte(`{"data":{"next_id":9007199254740993,"list":[{"id":"1","title":"第一页"}]}}`))
			return
		}
		if cursor != "9007199254740993" {
			t.Errorf("numeric cursor lost precision: %s", cursor)
		}
		_, _ = w.Write([]byte(`{"data":{"next_id":"","list":[{"id":"2","title":"第二页"}]}}`))
	})
	d.providerHosts[sourceMaoguo] = server.URL
	for page := 1; page <= 2; page++ {
		items, more, err := d.fetchMaoguoCatalogPage(context.Background(), page, "")
		if err != nil || len(items) != 1 || more != (page == 1) {
			t.Fatalf("page %d: %+v %v %v", page, items, more, err)
		}
	}
}

func TestDuanjuMaoguoRefreshInvalidatesLaterCursorChain(t *testing.T) {
	var refreshing atomic.Bool
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Query().Get("next_id") {
		case "":
			_, _ = w.Write([]byte(`{"data":{"next_id":"100","list":[{"id":"1","title":"一"}]}}`))
		case "100":
			next := "200"
			if refreshing.Load() {
				next = "500"
			}
			fmt.Fprintf(w, `{"data":{"next_id":"%s","list":[{"id":"2","title":"二"}]}}`, next)
		case "200":
			_, _ = w.Write([]byte(`{"data":{"next_id":"300","list":[{"id":"3","title":"三"}]}}`))
		case "500":
			_, _ = w.Write([]byte(`{"data":{"next_id":0,"list":[{"id":"3","title":"三"}]}}`))
		default:
			t.Errorf("stale cursor requested: %s", r.URL)
		}
	})
	d.providerHosts[sourceMaoguo] = server.URL
	for page := 1; page <= 3; page++ {
		if _, _, err := d.fetchMaoguoCatalogPage(context.Background(), page, ""); err != nil {
			t.Fatal(err)
		}
	}
	refreshing.Store(true)
	if _, _, err := d.fetchMaoguoCatalogPage(context.Background(), 2, ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.fetchMaoguoCatalogPage(context.Background(), 4, ""); err == nil {
		t.Fatal("refresh retained a stale later-page cursor")
	}
	items, more, err := d.fetchMaoguoCatalogPage(context.Background(), 3, "")
	if err != nil || len(items) != 1 || more {
		t.Fatalf("new cursor chain: %+v %v %v", items, more, err)
	}
}

func TestDuanjuFanguoRejectsMissingNonfinalPage(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"result":{"hasMore":true,"elements":[]}}`))
	})
	d.providerHosts[sourceFanguo] = server.URL
	if _, _, err := d.searchDuanjuPage(context.Background(), sourceFanguo, "关键词", 2); err == nil {
		t.Fatal("missing nonfinal results falsely completed search")
	}
}
