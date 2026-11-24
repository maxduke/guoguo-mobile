package app

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func (p *hppInvocation) fetch(input map[string]any) map[string]any {
	fail := func(message string) map[string]any { panic(p.vm.NewTypeError(message)) }
	if p.denied || p.ctx.Err() != nil || p.calls >= 18 || p.bytes >= 16<<20 {
		return fail("站源请求已结束")
	}
	p.calls++
	remote, err := url.Parse(mapString(input, "url"))
	if err != nil || !validImageURL(remote) {
		return fail("站源请求地址无效")
	}
	values := remote.Query()
	for name, value := range nestedMap(input, "query") {
		values.Set(name, nativeText(value))
	}
	if input["query"] != nil {
		remote.RawQuery = values.Encode()
	}
	method := strings.ToUpper(firstNonEmpty(mapString(input, "method"), http.MethodGet))
	if method != http.MethodGet && method != http.MethodHead && method != http.MethodPost {
		return fail("站源请求方式不受支持")
	}
	body := mapString(input, "body")
	contentType := ""
	if inputBody := nestedMap(input, "body"); inputBody != nil {
		if data, ok := inputBody["json"]; ok {
			encoded, err := json.Marshal(data)
			if err != nil {
				return fail("站源请求参数无效")
			}
			body, contentType = string(encoded), "application/json"
		} else if text, ok := inputBody["text"].(string); ok {
			body = text
		}
	}
	if len(body) > 128<<10 || len(remote.String()) > 8192 {
		return fail("站源请求参数过长")
	}
	ctx := context.WithValue(p.ctx, hppPublicRequestKey{}, true)
	request, err := http.NewRequestWithContext(ctx, method, remote.String(), strings.NewReader(body))
	if err != nil {
		return fail("站源请求无效")
	}
	request.Header.Set("User-Agent", userAgent)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	for name, value := range nestedMap(input, "headers") {
		switch http.CanonicalHeaderKey(name) {
		case "Accept", "Accept-Language", "Content-Type", "Origin", "Referer", "User-Agent", "Range", "X-Requested-With":
			text := nativeText(value)
			if len(text) <= 1024 && !strings.ContainsAny(text, "\r\n\x00") {
				request.Header.Set(name, text)
			}
		}
	}
	client := p.client
	if mapString(input, "credentials") == "omit" {
		client.Jar = nil
	}
	response, err := p.d.doPreparedCatalogRequestWithClient(request, 8*time.Second, nil, &client)
	if err != nil {
		return fail("站源连接失败")
	}
	defer response.Body.Close()
	remaining := min(4<<20, 16<<20-p.bytes)
	raw, err := io.ReadAll(io.LimitReader(response.Body, int64(remaining)+1))
	p.bytes += len(raw)
	if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden ||
		response.StatusCode == http.StatusTooManyRequests || catalogResponseBlockReason(response, raw) != "" {
		p.denied = true
		return fail("站源拒绝请求或要求验证")
	}
	if err != nil || len(raw) > remaining {
		return fail("站源响应读取失败或过大")
	}
	var data any = string(raw)
	if mapString(input, "responseType") == "json" {
		if err := json.Unmarshal(raw, &data); err != nil {
			return fail("站源数据格式无效")
		}
	}
	final := remote.String()
	if response.Request != nil {
		final = response.Request.URL.String()
	}
	headers := map[string]string{}
	for _, key := range []string{"Content-Type", "Location", "Content-Range"} {
		if value := response.Header.Get(key); value != "" {
			headers[strings.ToLower(key)] = value
		}
	}
	return map[string]any{
		"ok":      response.StatusCode >= 200 && response.StatusCode < 300,
		"status":  response.StatusCode,
		"data":    data,
		"url":     final,
		"headers": headers,
	}
}
