package app

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestMobileHuangguoCategoriesUseOfficialIDsWithoutLoadingTheCatalog(t *testing.T) {
	c := newSourceMobileClient(t)
	var calls atomic.Int32
	c.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		return rankingHTTPResponse(request, 500, "unexpected request"), nil
	})
	categories := newMobileSourceRows(t, callNewMobileSource(t, c, map[string]any{"method": "categories", "source": "huangguo"}), "items")
	if len(categories) != 5 || categories[0]["id"] != "" || calls.Load() != 0 {
		t.Fatal("categories fetched the aggregate catalog or lost their IDs", categories, calls.Load())
	}
	for index, id := range []string{"ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai"} {
		if categories[index+1]["id"] != id || categories[index+1]["name"] != huangguoAITypeName(id) {
			t.Fatal("source category was replaced by a local tag", categories[index+1])
		}
	}
	for _, capability := range c.sourceCapabilities() {
		if capability.Source == "huangguo" && (!capability.Categories || !capability.Search || capability.BackgroundCatalog || capability.SearchScope != sourceHuangguoAI) {
			t.Fatal("category capability changed aggregate prefetch or search scope", capability)
		}
	}
}

func TestMobileHuangguoCategoryPageKeepsAggregateCursorAndPageIdentity(t *testing.T) {
	c := newSourceMobileClient(t)
	c.huangguo = map[string]mobileHuangguoCursor{"cloudfront": {Next: 4}, sourceHuangguoVideo: {Next: 2, Done: true}}
	c.downloader.cfg.HuangguoAIURL = "https://category.example.org"
	var calls atomic.Int32
	c.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		if huangguoEnvelopePath(t, request) != "/api/videos/category/ai-manju?sort=hot&page=2&size=24" {
			// A selected line can support the original route without accepting the
			// newer list endpoint. Its business refusal cannot trigger a retry.
			return rankingHTTPResponse(request, 200, `{"status":0,"data":null}`), nil
		}
		return huangguoAPIResponse(request, strings.Replace(huangguoAPIPageFixture, `"page":1,"pages":2`, `"page":2,"pages":3`, 1)), nil
	})
	result := callNewMobileSource(t, c, map[string]any{"method": "catalog", "source": "huangguo", "category": "ai-manju", "page": 2})
	assertNewSourcePage(t, result, "huangguo", "huangguoai:501", true)
	if calls.Load() != 1 || c.huangguo["cloudfront"].Next != 4 || !c.huangguo[sourceHuangguoVideo].Done {
		t.Fatal("independent category browsing changed the aggregate cursor", c.huangguo)
	}
	row := newMobileSourceRows(t, result, "items")[0]
	if row["category"] != huangguoAITypeName("ai-manju") {
		t.Fatal("category provenance was lost", row)
	}
}

func TestMobileHuangguoEmptyCategoryIsAValidPage(t *testing.T) {
	c := newSourceMobileClient(t)
	c.downloader.cfg.HuangguoAIURL = "https://category.example.org"
	var calls atomic.Int32
	c.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		if huangguoEnvelopePath(t, request) != "/api/videos/category/ai-huanlian?sort=hot&page=1&size=24" {
			t.Error("empty category restarted on an old route")
		}
		return huangguoAPIResponse(request, `{"items":[],"pagination":{"page":1,"pages":0}}`), nil
	})
	result := callNewMobileSource(t, c, map[string]any{"method": "catalog", "source": "huangguo", "category": "ai-huanlian"})
	if len(newMobileSourceRows(t, result, "items")) != 0 || result["hasMore"] != false || calls.Load() != 1 {
		t.Fatalf("empty category: %+v, calls=%d", result, calls.Load())
	}
}

func TestMobileHuangguoCategoryValidationHappensBeforeNetwork(t *testing.T) {
	c := newSourceMobileClient(t)
	var calls atomic.Int32
	c.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		return rankingHTTPResponse(request, 500, "unexpected request"), nil
	})
	for _, query := range []struct {
		category string
		page     int
	}{{"../other", 1}, {"都市", 1}, {"recommend", 1}, {"ai-manju", -1}, {"ai-manju", 201}} {
		raw, _ := json.Marshal(map[string]any{"method": "catalog", "source": "huangguo", "category": query.category, "page": query.page})
		if _, err := c.Call(string(raw)); err == nil {
			t.Fatal("invalid category/page was accepted", query)
		}
	}
	if calls.Load() != 0 {
		t.Fatal("invalid category reached the network", calls.Load())
	}
}

func TestMobileHuangguoForegroundCategoryCancellationIsRequestScoped(t *testing.T) {
	c := newSourceMobileClient(t)
	c.downloader.cfg.HuangguoAIURL = "https://category.example.org"
	started := make(chan struct{})
	var calls atomic.Int32
	c.downloader.client.Transport = rankingTransport(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		close(started)
		<-request.Context().Done()
		return nil, request.Context().Err()
	})
	done := make(chan error, 1)
	go func() {
		_, err := c.Call(`{"method":"catalog","source":"huangguo","category":"ai-manju","page":2,"requestId":"topic-yellow-2"}`)
		done <- err
	}()
	<-started
	callNewMobileSource(t, c, map[string]any{"method": "cancelCatalog", "source": "huangguo", "category": "ai-manju", "page": 1, "requestId": "topic-yellow-2"})
	select {
	case err := <-done:
		t.Fatal("another page canceled this read", err)
	default:
	}
	callNewMobileSource(t, c, map[string]any{"method": "cancelCatalog", "source": "huangguo", "category": "ai-manju", "page": 2, "requestId": "topic-yellow-2"})
	select {
	case err := <-done:
		if err == nil || calls.Load() != 1 {
			t.Fatal("cancelled category restarted or published success", calls.Load(), err)
		}
	case <-time.After(time.Second):
		t.Fatal("leaving the topic page did not cancel its foreground read")
	}
}
