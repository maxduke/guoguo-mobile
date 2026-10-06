package app

import (
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
)

type proxyRouter struct {
	mu          sync.RWMutex
	resolve     func(*http.Request) (*url.URL, error)
	description string
}

func (router *proxyRouter) configure(raw string) {
	resolve, description := networkProxy(raw)
	router.mu.Lock()
	router.resolve = resolve
	router.description = description
	router.mu.Unlock()
}

func (router *proxyRouter) proxy(request *http.Request) (*url.URL, error) {
	router.mu.RLock()
	resolve := router.resolve
	router.mu.RUnlock()
	if resolve == nil {
		return nil, nil
	}
	return resolve(request)
}

func configuredProxy(raw string) (*url.URL, error) {
	if raw == "" || raw == "auto" || raw == "direct" {
		return nil, nil
	}
	endpoint, err := url.Parse(raw)
	if err != nil || endpoint.Hostname() == "" || endpoint.Scheme != "http" && endpoint.Scheme != "https" && endpoint.Scheme != "socks5" && endpoint.Scheme != "socks5h" || endpoint.RawQuery != "" || endpoint.Fragment != "" || endpoint.Path != "" && endpoint.Path != "/" {
		return nil, errors.New("proxyURL 必须是 auto、direct 或 HTTP/HTTPS/SOCKS5 代理地址")
	}
	return endpoint, nil
}

func networkProxy(raw string) (func(*http.Request) (*url.URL, error), string) {
	if raw == "direct" {
		return nil, "直连（手动设置）"
	}
	if endpoint, err := configuredProxy(raw); err != nil {
		return func(*http.Request) (*url.URL, error) { return nil, err }, "代理配置无效"
	} else if endpoint != nil {
		return func(request *http.Request) (*url.URL, error) {
			if proxyBypassed(request.URL.Hostname(), nil) {
				return nil, nil
			}
			return endpoint, nil
		}, "手动代理 " + endpoint.Scheme + "://" + endpoint.Host
	}
	description := "直连（未发现代理）"
	if firstNonEmpty(os.Getenv("HTTPS_PROXY"), os.Getenv("https_proxy"), os.Getenv("HTTP_PROXY"), os.Getenv("http_proxy")) != "" {
		description = "环境变量代理"
	}
	return func(request *http.Request) (*url.URL, error) {
		if proxyBypassed(request.URL.Hostname(), nil) {
			return nil, nil
		}
		environment := "HTTP_PROXY"
		if request.URL.Scheme == "https" {
			environment = "HTTPS_PROXY"
		}
		if firstNonEmpty(os.Getenv(environment), os.Getenv(strings.ToLower(environment))) != "" {
			return http.ProxyFromEnvironment(request)
		}
		return nil, nil
	}, description
}

func proxyBypassed(host string, exceptions []string) bool {
	host = strings.ToLower(host)
	address := net.ParseIP(host)
	if host == "localhost" || address != nil && address.IsLoopback() {
		return true
	}
	for _, entry := range exceptions {
		entry = strings.ToLower(strings.TrimSpace(entry))
		if entry == "*" || entry == "<local>" && !strings.Contains(host, ".") {
			return true
		}
		if _, network, err := net.ParseCIDR(entry); err == nil && address != nil && network.Contains(address) {
			return true
		}
		if strings.HasPrefix(entry, "*.") || strings.HasPrefix(entry, ".") {
			suffix := strings.TrimPrefix(strings.TrimPrefix(entry, "*"), ".")
			if host == suffix || strings.HasSuffix(host, "."+suffix) {
				return true
			}
		} else if entry != "" && host == entry {
			return true
		}
	}
	return false
}
