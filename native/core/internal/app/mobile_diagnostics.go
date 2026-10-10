package app

import (
	"context"
	"errors"
	"net"
	"regexp"
	"strings"
	"sync"
	"time"
)

const mobileDiagnosticLimit = 64

type mobileDiagnostic struct {
	Source          string    `json:"source"`
	Method          string    `json:"method"`
	At              time.Time `json:"at"`
	ElapsedMS       int64     `json:"elapsedMs"`
	Page            int       `json:"page"`
	Refresh         bool      `json:"refresh"`
	Background      bool      `json:"background"`
	NetworkAttempts int       `json:"networkAttempts"`
	CacheHits       int       `json:"cacheHits"`
	SharedWaits     int       `json:"sharedWaits"`
	HTTPStatus      int       `json:"httpStatus"`
	Result          string    `json:"result"`
	Failure         string    `json:"failure"`
	Stage           string    `json:"stage"`
}

type mobileTraceKey struct{}
type mobileTrace struct {
	mu     sync.Mutex
	value  mobileDiagnostic
	closed bool
}

func diagnosticMethod(method string) bool {
	switch method {
	case "catalog", "categories", "ranking", "boards", "recommendations", "search", "suggestions", "detail", "chapters":
		return true
	}
	return false
}

func diagnosticSource(request mobileRequest) string {
	source := request.Source
	if request.Method == "recommendations" {
		source = sourceHongguo
	} else if request.Method == "ranking" {
		if board, ok := findRankingBoard(request.Board); ok {
			source = board.Source
		}
	} else if request.ID != "" {
		if provider, _, valid := splitProviderDramaID(request.ID); valid {
			source = provider
		} else if rankingSourceID.MatchString(request.ID) {
			source = sourceHuangdou
		}
	}
	if matchesSourceFilter(source, "huangguo") {
		return "huangguo"
	}
	source = canonicalProviderSource(source)
	if source == sourceHongguo || source == sourceHuangdou || source == sourceHuangju || source == sourceYeguo || source == sourceDSD || isDuanjuProviderSource(source) {
		return source
	}
	return ""
}

func traceFrom(ctx context.Context) *mobileTrace {
	trace, _ := ctx.Value(mobileTraceKey{}).(*mobileTrace)
	return trace
}

func traceUpdate(ctx context.Context, update func(*mobileDiagnostic)) {
	if trace := traceFrom(ctx); trace != nil {
		trace.mu.Lock()
		defer trace.mu.Unlock()
		if !trace.closed {
			update(&trace.value)
		}
	}
}

func traceCache(ctx context.Context) {
	traceUpdate(ctx, func(value *mobileDiagnostic) { value.CacheHits++ })
}

func traceShared(ctx context.Context) {
	traceUpdate(ctx, func(value *mobileDiagnostic) { value.SharedWaits++ })
}

func traceNetwork(ctx context.Context) {
	traceUpdate(ctx, func(value *mobileDiagnostic) {
		value.NetworkAttempts++
		value.Stage = "network"
	})
}

var diagnosticHTTPStatus = regexp.MustCompile(`(?i)HTTP (\d{3})`)

func diagnosticFailure(err error) string {
	if err == nil {
		return ""
	}
	var dns *net.DNSError
	text := strings.ToLower(err.Error())
	switch {
	case errors.Is(err, context.Canceled), strings.Contains(text, "context canceled"), strings.Contains(text, "已取消"):
		return "cancelled"
	case strings.Contains(text, "浏览器验证"), strings.Contains(text, "cloudflare"), strings.Contains(text, "安全验证"):
		return "verification"
	case errors.As(err, &dns), strings.Contains(text, "no such host"), strings.Contains(text, "dns"), strings.Contains(text, "域名解析"), strings.Contains(text, "内网或保留网络"), strings.Contains(text, "公网地址"):
		return "dns"
	case errors.Is(err, context.DeadlineExceeded), strings.Contains(text, "timeout"), strings.Contains(text, "deadline exceeded"), strings.Contains(text, "超时"):
		return "timeout"
	case strings.Contains(text, "已暂停该域名请求"):
		return "backoff"
	case diagnosticHTTPStatus.MatchString(text):
		return "http"
	case strings.Contains(text, "eof"), strings.Contains(text, "connection"), strings.Contains(text, "tls"), strings.Contains(text, "连接"):
		return "connection"
	}
	return "other"
}

func (trace *mobileTrace) snapshot(err error, value any, close bool) mobileDiagnostic {
	trace.mu.Lock()
	defer trace.mu.Unlock()
	result := trace.value
	result.ElapsedMS = time.Since(result.At).Milliseconds()
	result.Result, result.Stage = "success", "complete"
	if err != nil {
		result.Result, result.Failure = "failed", diagnosticFailure(err)
		if result.Failure == "cancelled" {
			result.Result = "cancelled"
		}
		result.Stage = result.Failure
		if result.Failure == "other" {
			result.Stage = "request"
			if result.NetworkAttempts > 0 {
				result.Stage = "response"
			}
		}
	} else if data, ok := value.(map[string]any); ok {
		warning, _ := data["warning"].(string)
		if warning != "" || data["stale"] == true {
			result.Result = "partial"
			if warning != "" {
				result.Failure = diagnosticFailure(errors.New(warning))
			}
		}
	}
	if close {
		trace.closed = true
	}
	return result
}

var diagnosticID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func (c *MobileClient) saveDiagnostic(id string, value mobileDiagnostic) {
	if !diagnosticID.MatchString(id) {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if c.diagnostics == nil {
		c.diagnostics = map[string]mobileDiagnostic{}
	}
	if _, exists := c.diagnostics[id]; !exists {
		c.diagnosticOrder = append(c.diagnosticOrder, id)
	}
	c.diagnostics[id] = value
	for len(c.diagnosticOrder) > mobileDiagnosticLimit {
		delete(c.diagnostics, c.diagnosticOrder[0])
		c.diagnosticOrder = c.diagnosticOrder[1:]
	}
}
