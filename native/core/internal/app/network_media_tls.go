package app

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

// Only explicitly resolved Huangguo media may retry certificate failures.
// Redirects leave this scope unless they retain the original media origin.
type huangguoMediaTransport struct {
	secure   http.RoundTripper
	origin   *url.URL
	once     sync.Once
	mu       sync.Mutex
	fallback http.RoundTripper
}

func (transport *huangguoMediaTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := transport.secure.RoundTrip(request)
	if err == nil || request.Context().Err() != nil || request.URL.Scheme != "https" || providerMediaOrigin(request.URL) != providerMediaOrigin(transport.origin) || !mediaCertificateError(err) {
		return response, err
	}
	if response != nil && response.Body != nil {
		response.Body.Close()
	}
	transport.once.Do(func() {
		transport.mu.Lock()
		defer transport.mu.Unlock()
		transport.fallback = cloneMediaTransport(transport.secure)
	})
	if transport.fallback == nil {
		return nil, err
	}
	return transport.fallback.RoundTrip(request)
}
func (transport *huangguoMediaTransport) CloseIdleConnections() {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	if closer, ok := transport.fallback.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}
func mediaCertificateError(err error) bool {
	var verification *tls.CertificateVerificationError
	var unknown x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	if errors.As(err, &verification) || errors.As(err, &unknown) || errors.As(err, &hostname) || errors.As(err, &invalid) {
		return true
	}
	// Browser/CDN transports redact URLs before returning errors.
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "x509:") || strings.Contains(text, "tls: failed to verify certificate")
}
func cloneMediaTransport(base http.RoundTripper) http.RoundTripper {
	switch transport := base.(type) {
	case *http.Transport:
		cloned := transport.Clone()
		if cloned.TLSClientConfig == nil {
			cloned.TLSClientConfig = &tls.Config{}
		}
		cloned.TLSClientConfig.InsecureSkipVerify = true // User-authorized Huangguo media fallback.
		return cloned
	case *cdnTransport:
		return newCDNTransport(cloneMediaTransport(transport.base).(*http.Transport), transport.resolver)
	case *imageTransport:
		return cloneMediaTransport(transport.base)
	case *huangguoBrowserTransport:
		cloned := &huangguoBrowserTransport{base: cloneMediaTransport(transport.base), router: transport.router, hosts: transport.hosts, insecure: true, record: transport.record, clients: make(map[string]browserHTTPClient)}
		cloned.newClient = cloned.createClient
		return cloned
	default:
		return nil
	}
}
func mediaHTTPClient(client *http.Client, media providerMedia) *http.Client {
	if !media.certificateFallback {
		return client
	}
	origin, err := url.Parse(firstNonEmpty(media.certificateOrigin, media.URL))
	if err != nil || origin.Scheme != "https" {
		return client
	}
	copy := *client
	base := copy.Transport
	if base == nil {
		base = http.DefaultTransport
	}
	copy.Transport = &huangguoMediaTransport{secure: base, origin: origin}
	return &copy
}
