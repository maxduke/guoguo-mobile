package app

import (
	"crypto/tls"
	"net/http"
	"path/filepath"
	"sync"
	"time"
)

type Downloader struct {
	huangjuOnce            sync.Once
	huangju                *huangjuAPIClient
	yeguoOnce              sync.Once
	yeguo                  *yeguoAPIClient
	dsdCatalog             dsdCatalogState
	maoguoCatalog          maoguoCatalogCache
	huangguoAIRoutes       []string
	huangguoAIRouteChecked bool
	huangdouDetails        map[string]huangdouDetailEntry
	huangdouDetailPending  map[string]*huangdouDetailCall
	cfg                    Config
	client                 *http.Client
	providerMu             sync.Mutex
	providerHosts          map[string]string
	apiMu                  sync.Mutex
	apiBase                string
	limiter                *requestLimiter
	proxyRouter            *proxyRouter
	hongguoOnce            sync.Once
	hongguo                *hongguoAppClient
	legacyOnce             sync.Once
	legacy                 *legacyAPIClient
	rankings               rankingCache
	diagnostics            *diagnosticLog
}

func NewDownloader(cfg Config) *Downloader {
	if cfg.OutputDir == "" {
		cfg.OutputDir = defaultOutputDir()
	}
	if cfg.RequestConcurrency <= 0 {
		cfg.RequestConcurrency = 2
	}
	if cfg.RequestIntervalMS <= 0 {
		cfg.RequestIntervalMS = 500
	}
	if absolute, err := filepath.Abs(cfg.dataDirectory()); err == nil {
		cfg.dataDir = absolute
	}
	if absolute, err := filepath.Abs(cfg.OutputDir); err == nil {
		cfg.OutputDir = absolute
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: cfg.InsecureTLS}
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 20 * time.Second
	router := &proxyRouter{}
	router.configure(cfg.ProxyURL)
	transport.Proxy = router.proxy
	resolver := newSafeDNSDialer(transport)
	transport.DialContext = resolver.DialContext
	downloader := &Downloader{cfg: cfg, client: &http.Client{Transport: newCDNTransport(transport, resolver), Timeout: 45 * time.Second}, providerHosts: map[string]string{}, limiter: newRequestLimiter(cfg.RequestConcurrency, time.Duration(cfg.RequestIntervalMS)*time.Millisecond), proxyRouter: router, diagnostics: newDiagnosticLog(cfg.dataDirectory())}
	downloader.client.Transport = newImageTransport(newHuangguoBrowserTransport(downloader.client.Transport, downloader), transport)
	return downloader
}
