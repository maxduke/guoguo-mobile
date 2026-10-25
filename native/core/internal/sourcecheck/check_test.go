package sourcecheck

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type fixture struct {
	requests []map[string]any
	change   func(map[string]any, map[string]any)
}

func (f *fixture) Call(raw string) (string, error) {
	var request map[string]any
	json.Unmarshal([]byte(raw), &request)
	f.requests = append(f.requests, request)
	source, _ := request["source"].(string)
	drama := map[string]any{"id": source + ":secret", "source": source, "title": "secret title"}
	value := map[string]any{"_diagnostic": map[string]any{"networkAttempts": 1, "cacheHits": 0, "httpStatus": 200}}
	switch request["method"] {
	case "catalog":
		value["items"] = []any{drama}
	case "categories":
		value["items"] = []any{map[string]any{"id": "", "name": "全部"}}
	case "boards":
		value["items"] = []any{map[string]any{"id": "first", "source": source}, map[string]any{"id": "second", "source": source}, map[string]any{"id": "third", "source": source}}
	case "ranking":
		value["items"] = []any{map[string]any{"drama": drama}}
		if request["refresh"] != true {
			value["_diagnostic"] = map[string]any{"networkAttempts": 0, "cacheHits": 1}
		}
	case "search":
		value["items"] = []any{}
	case "detail":
		value["item"] = drama
	case "chapters":
		value["chapters"] = []any{map[string]any{"id": "one"}}
	default:
		return "", errors.New("unexpected media request")
	}
	if f.change != nil {
		f.change(request, value)
	}
	encoded, err := json.Marshal(value)
	return string(encoded), err
}

func TestCheckColdRefreshCacheEmptySearchAndNoMedia(t *testing.T) {
	f := &fixture{}
	result := Check(context.Background(), f, Capability{Source: "huangguo", Search: true, SearchScope: "huangguoai"}, "secret query", false)
	if len(result.Steps) != 11 {
		t.Fatalf("steps: %+v", result.Steps)
	}
	for _, step := range result.Steps {
		if step.Status != "passed" {
			t.Fatalf("step: %+v", step)
		}
	}
	for _, request := range f.requests {
		if request["timeoutMs"].(float64) != 12000 || request["traceId"] == "" {
			t.Fatal("unbounded request")
		}
		if request["method"] == "cover" || request["method"] == "resolve" || request["method"] == "downloadPlan" {
			t.Fatal("requested media")
		}
	}
	raw, _ := json.Marshal(result)
	if strings.Contains(string(raw), "secret") {
		t.Fatal("report leaked identifiers/query")
	}
}

func TestCheckInvalidContentAndUnobservedRefresh(t *testing.T) {
	for _, test := range []struct {
		method, want string
		patch        func(map[string]any)
	}{
		{"catalog", "empty_content", func(v map[string]any) { v["items"] = []any{} }},
		{"catalog", "invalid_identity_or_rows", func(v map[string]any) { v["items"] = nil }},
		{"catalog", "invalid_identity_or_rows", func(v map[string]any) {
			v["items"] = []any{map[string]any{"id": "id", "title": "title", "source": "wrong"}}
		}},
		{"ranking", "refresh_not_observed", func(v map[string]any) { v["_diagnostic"] = map[string]any{"networkAttempts": 0} }},
		{"boards", "invalid_boards", func(v map[string]any) { v["items"] = []any{} }},
		{"chapters", "invalid_chapters", func(v map[string]any) {
			v["chapters"] = []any{map[string]any{"id": "same"}, map[string]any{"id": "same"}}
		}},
	} {
		t.Run(test.method+test.want, func(t *testing.T) {
			f := &fixture{change: func(request, value map[string]any) {
				if request["method"] == test.method {
					test.patch(value)
				}
			}}
			result := Check(context.Background(), f, Capability{Source: "huangju", Search: true}, "query", false)
			found := false
			for _, step := range result.Steps {
				if step.Reason == test.want && step.Status == "failed" {
					found = true
				}
			}
			if !found {
				t.Fatalf("failure not reported: %+v", result.Steps)
			}
		})
	}
}

type failingClient struct{}

func (failingClient) Call(raw string) (string, error) {
	if strings.Contains(raw, "requestDiagnostic") {
		return `{"diagnostic":{"failure":"dns","networkAttempts":1}}`, nil
	}
	return "", errors.New("https://secret/path?token=secret")
}
func TestCheckFailureLookupBudgetAndLocalSearch(t *testing.T) {
	result := Check(context.Background(), failingClient{}, Capability{Source: "huangdou", SearchScope: "local"}, "query", false)
	for _, step := range result.Steps {
		if step.Status == "failed" && step.Reason != "dns" {
			t.Fatalf("diagnostic lookup failed: %+v", step)
		}
	}
	if result.Steps[2].Reason != "local_filter" {
		t.Fatalf("local search: %+v", result.Steps)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f := &fixture{}
	result = Check(ctx, f, Capability{Source: "huangju", Categories: true, Search: true}, "query", false)
	if len(f.requests) != 0 {
		t.Fatal("request after budget exhausted")
	}
	for _, step := range result.Steps {
		if step.Status != "skipped" {
			t.Fatalf("budget: %+v", step)
		}
	}
}
