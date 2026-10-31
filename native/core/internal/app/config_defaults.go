package app

const (
	defaultAPIBase = "https://dr6skssi3nxbk.cloudfront.net"
	defaultCDNURL  = "https://sjljsla.lkkwip.cn"
	userAgent      = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1"
	xUserAgent     = "BuildID=com.abc.Butterfly;SysType=ios;DevID=00000000000000000000000000000;Ver=1.0.0;DevType=iPhone;DeviceBrand=APPLE;DeviceModel=iPhone;SystemName=iOS;SystemVersion=18.7;Terminal=1;IsH5=1;Sid=00000000000000000000000000000000"
)

type Config struct {
	YeguoAPIURL        string `json:"yeguoAPIURL,omitempty"`
	HuangjuURL         string `json:"huangjuURL,omitempty"`
	HuangjuAPIURL      string `json:"huangjuAPIURL,omitempty"`
	YeguoURL           string `json:"yeguoURL,omitempty"`
	DSDURL             string `json:"dsdURL,omitempty"`
	dataDir            string
	APIBase            string `json:"apiBase"`
	CDNURL             string `json:"cdnURL"`
	Token              string `json:"token"`
	AESKeyHex          string `json:"aesKeyHex"`
	InterfaceKey       string `json:"interfaceKey"`
	ParamKey           string `json:"paramKey"`
	ParamIV            string `json:"paramIV"`
	OutputDir          string `json:"outputDir"`
	RequestConcurrency int    `json:"requestConcurrency"`
	RequestIntervalMS  int    `json:"requestIntervalMs"`
	MaxPagesPerSort    int    `json:"maxPagesPerSort"`
	PageSize           int    `json:"pageSize"`
	Retries            int    `json:"retries"`
	InsecureTLS        bool   `json:"insecureTLS"`
	ProxyURL           string `json:"proxyURL,omitempty"`
	HuangguoAIURL      string `json:"huangguoAIURL,omitempty"`
	HuangguoVideoURL   string `json:"huangguoVideoURL,omitempty"`
	HuangdouURL        string `json:"huangdouURL,omitempty"`
	HongguoURL         string `json:"hongguoURL,omitempty"`
	// Mobile playback has a separate bounded policy from catalog/download retries.
	hongguoPlayerAttempts int
}

func defaultConfig() Config {
	return Config{
		APIBase:            defaultAPIBase,
		CDNURL:             defaultCDNURL,
		OutputDir:          defaultOutputDir(),
		RequestConcurrency: 2,
		RequestIntervalMS:  500,
		MaxPagesPerSort:    20,
		PageSize:           50,
		Retries:            3,
		InsecureTLS:        false,
	}
}

func defaultOutputDir() string {
	return "短剧下载"
}
