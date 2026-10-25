// Package sourcecheck checks the embedded text API, independently of builds.
package sourcecheck

import (
	"context"
	"encoding/json"
	"strconv"
	"sync/atomic"
	"time"
)

type Client interface{ Call(string) (string, error) }
type Capability struct {
	Source            string `json:"source"`
	Categories        bool   `json:"categories"`
	Search            bool   `json:"search"`
	SearchScope       string `json:"searchScope"`
	BackgroundCatalog bool   `json:"backgroundCatalog"`
}
type Step struct {
	Operation       string `json:"operation"`
	Status          string `json:"status"`
	Reason          string `json:"reason,omitempty"`
	ElapsedMS       int64  `json:"elapsedMs"`
	Items           int    `json:"items"`
	NetworkAttempts *int   `json:"networkAttempts"`
	CacheHits       int    `json:"cacheHits"`
	HTTPStatus      int    `json:"httpStatus"`
	MediaBytes      int    `json:"mediaBytes,omitempty"`
	MediaKind       string `json:"mediaKind,omitempty"`
}
type Result struct {
	Source      string `json:"source"`
	SearchScope string `json:"searchScope"`
	Steps       []Step `json:"steps"`
}
type row struct{ ID, Source, Title string }
type diagnostic struct {
	NetworkAttempts *int   `json:"networkAttempts"`
	CacheHits       int    `json:"cacheHits"`
	HTTPStatus      int    `json:"httpStatus"`
	Failure         string `json:"failure"`
}
type response struct {
	Items      json.RawMessage   `json:"items"`
	Item       row               `json:"item"`
	Chapters   []json.RawMessage `json:"chapters"`
	Diagnostic diagnostic        `json:"_diagnostic"`
	Warning    string            `json:"warning"`
	Stale      bool              `json:"stale"`
}

var serial atomic.Uint64

func call(ctx context.Context, client Client, source, operation, method string, request map[string]any) (Step, response) {
	step := Step{Operation: operation, Status: "failed"}
	if ctx.Err() != nil {
		step.Status, step.Reason = "skipped", "budget"
		return step, response{}
	}
	timeout := 12 * time.Second
	if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) < timeout {
		timeout = time.Until(deadline)
	}
	id := "check-" + strconv.FormatUint(serial.Add(1), 10)
	request["method"], request["source"], request["traceId"] = method, source, id
	request["timeoutMs"] = max(100, timeout.Milliseconds())
	encoded, _ := json.Marshal(request)
	started := time.Now()
	raw, err := client.Call(string(encoded))
	step.ElapsedMS = time.Since(started).Milliseconds()
	var value response
	if err != nil {
		step.Reason = "other"
		// Fetch only the core's closed diagnostic schema, never print raw errors.
		lookup, _ := json.Marshal(map[string]string{"method": "requestDiagnostic", "traceId": id})
		if raw, lookupErr := client.Call(string(lookup)); lookupErr == nil {
			var result struct {
				Diagnostic diagnostic `json:"diagnostic"`
			}
			if json.Unmarshal([]byte(raw), &result) == nil {
				value.Diagnostic = result.Diagnostic
			}
		}
	} else if json.Unmarshal([]byte(raw), &value) != nil {
		step.Reason = "invalid_response"
	} else {
		step.Status = "passed"
		if value.Warning != "" || value.Stale {
			step.Status, step.Reason = "partial", "fallback_or_warning"
		}
	}
	step.NetworkAttempts, step.CacheHits, step.HTTPStatus = value.Diagnostic.NetworkAttempts, value.Diagnostic.CacheHits, value.Diagnostic.HTTPStatus
	if step.Status == "failed" {
		switch value.Diagnostic.Failure {
		case "cancelled", "verification", "dns", "timeout", "backoff", "http", "connection", "other":
			step.Reason = value.Diagnostic.Failure
		}
	}
	return step, value
}

func rows(value response, ranking bool, source string) ([]row, bool) {
	if len(value.Items) == 0 || string(value.Items) == "null" {
		return nil, false
	}
	var items []row
	if ranking {
		var ranked []struct{ Drama row }
		if json.Unmarshal(value.Items, &ranked) != nil {
			return nil, false
		}
		for _, item := range ranked {
			items = append(items, item.Drama)
		}
	} else if json.Unmarshal(value.Items, &items) != nil {
		return nil, false
	}
	for _, item := range items {
		if item.ID == "" || item.Title == "" || item.Source != source {
			return nil, false
		}
	}
	return items, true
}

func checkRows(step *Step, value response, source string, ranking, allowEmpty bool) []row {
	if step.Status == "failed" || step.Status == "skipped" {
		return nil
	}
	items, valid := rows(value, ranking, source)
	step.Items = len(items)
	if !valid {
		step.Status, step.Reason = "failed", "invalid_identity_or_rows"
	} else if len(items) == 0 && !allowEmpty {
		step.Status, step.Reason = "failed", "empty_content"
	}
	return items
}

// Check uses a fresh client per source. Search emptiness is a valid result; an
// empty default directory or malformed identities cannot count as availability.
func Check(ctx context.Context, client Client, capability Capability, query string, includeMedia bool) Result {
	source := capability.Source
	result := Result{Source: source, SearchScope: capability.SearchScope, Steps: []Step{}}
	if capability.Categories {
		step, value := call(ctx, client, source, "categories", "categories", map[string]any{})
		var categories []struct{ ID, Name string }
		if step.Status == "passed" && (json.Unmarshal(value.Items, &categories) != nil || len(categories) == 0) {
			step.Status, step.Reason = "failed", "invalid_categories"
		}
		for _, category := range categories {
			if category.Name == "" {
				step.Status, step.Reason = "failed", "invalid_categories"
			}
		}
		step.Items = len(categories)
		result.Steps = append(result.Steps, step)
	}
	step, value := call(ctx, client, source, "catalog_cold", "catalog", map[string]any{"page": 1})
	items := checkRows(&step, value, source, false, false)
	result.Steps = append(result.Steps, step)
	boardStep, boardValue := call(ctx, client, source, "boards", "boards", map[string]any{})
	var boards []struct{ ID, Source string }
	if boardStep.Status == "passed" && (json.Unmarshal(boardValue.Items, &boards) != nil || len(boards) == 0) {
		boardStep.Status, boardStep.Reason = "failed", "invalid_boards"
	}
	for _, board := range boards {
		if board.ID == "" || board.Source != source {
			boardStep.Status, boardStep.Reason = "failed", "invalid_boards"
		}
	}
	boardStep.Items = len(boards)
	result.Steps = append(result.Steps, boardStep)
	// Cover the default column for every source, plus all three Huangguo boards.
	if len(boards) > 0 && boardStep.Status == "passed" {
		limit := 1
		if source == "huangguo" {
			limit = min(3, len(boards))
		}
		for index, board := range boards[:limit] {
			step, value := call(ctx, client, source, "ranking_refresh_"+strconv.Itoa(index+1), "ranking", map[string]any{"board": board.ID, "refresh": true, "page": 1})
			checkRows(&step, value, source, true, false)
			if step.Status == "passed" && (step.NetworkAttempts == nil || *step.NetworkAttempts == 0) {
				step.Status, step.Reason = "failed", "refresh_not_observed"
			}
			result.Steps = append(result.Steps, step)
			if step.Status == "passed" {
				warm, cached := call(ctx, client, source, "ranking_cached_"+strconv.Itoa(index+1), "ranking", map[string]any{"board": board.ID, "page": 1})
				checkRows(&warm, cached, source, true, false)
				if warm.Status == "passed" && (warm.CacheHits == 0 || warm.NetworkAttempts == nil || *warm.NetworkAttempts != 0) {
					warm.Status, warm.Reason = "failed", "cache_not_observed"
				}
				result.Steps = append(result.Steps, warm)
			}
		}
	}
	if capability.Search {
		step, value := call(ctx, client, source, "search", "search", map[string]any{"query": query, "page": 1})
		checkRows(&step, value, source, false, true)
		result.Steps = append(result.Steps, step)
	} else {
		result.Steps = append(result.Steps, Step{Operation: "search", Status: "skipped", Reason: "local_filter"})
	}
	if len(items) > 0 {
		step, detail := call(ctx, client, source, "detail", "detail", map[string]any{"id": items[0].ID})
		if step.Status != "failed" && step.Status != "skipped" && (detail.Item.ID != items[0].ID || detail.Item.Source != source || detail.Item.Title == "") {
			step.Status, step.Reason = "failed", "invalid_identity_or_rows"
		}
		result.Steps = append(result.Steps, step)
		step, chapters := call(ctx, client, source, "chapters", "chapters", map[string]any{"id": items[0].ID})
		if step.Status != "failed" && step.Status != "skipped" {
			step.Items = len(chapters.Chapters)
			seen := map[string]bool{}
			if len(chapters.Chapters) == 0 {
				step.Status, step.Reason = "failed", "no_episodes"
			}
			for _, chapter := range chapters.Chapters {
				var identity struct{ ID string }
				if json.Unmarshal(chapter, &identity) != nil || identity.ID == "" || seen[identity.ID] {
					step.Status, step.Reason = "failed", "invalid_chapters"
				}
				seen[identity.ID] = true
			}
		}
		result.Steps = append(result.Steps, step)
		if includeMedia {
			if step.Status == "passed" && len(chapters.Chapters) > 0 {
				result.Steps = append(result.Steps, probeMedia(ctx, client, source, items[0].ID, chapters.Chapters[0]))
			} else {
				result.Steps = append(result.Steps, Step{Operation: "media_sample", Status: "skipped", Reason: "no_episodes"})
			}
		}
	} else {
		for _, operation := range []string{"detail", "chapters"} {
			result.Steps = append(result.Steps, Step{Operation: operation, Status: "skipped", Reason: "no_catalog_sample"})
		}
		if includeMedia {
			result.Steps = append(result.Steps, Step{Operation: "media_sample", Status: "skipped", Reason: "no_catalog_sample"})
		}
	}
	return result
}
