// Constrained inline-model recovery adapted from hongguo-drama PR #92,
// GPL-3.0-only. Source and local limits: native/core/UPSTREAM.md.
package app

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

func hongguoModelDuration(model map[string]any) (float64, bool) {
	n, err := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0) && n > 0 && n < float64(math.MaxInt64)/float64(time.Second)
}
func hongguoModelVideoID(model map[string]any) string {
	id, ok := model["video_id"].(string)
	if !ok || len(id) > 128 || strings.TrimSpace(id) != id {
		return ""
	}
	return id
}
func (d *Downloader) resolveHongguoAppModel(ctx context.Context, entry map[string]any, attempted *bool) (providerMedia, error) {
	model, err := decodeHongguoAppModel(entry)
	if err != nil {
		traceHongguoFailure(ctx, "invalid_model")
		return providerMedia{}, err
	}
	media, parseErr := selectHongguoAppMedia(model)
	if parseErr == nil {
		return media, nil
	}
	traceHongguoFailure(ctx, "invalid_model")
	if *attempted || hongguoModelVideoID(model) == "" {
		return providerMedia{}, parseErr
	}
	duration, valid := hongguoModelDuration(model)
	if !valid {
		return providerMedia{}, parseErr
	}
	floor := 0
	for _, value := range hongguoModelVariants(model) {
		row, _ := value.(map[string]any)
		if _, ok := hongguoAppCodecPriority(row); !ok {
			continue
		}
		if _, err := hongguoAppVariantKey(row); !errors.Is(err, errHongguoEncryptionMetadataMissing) {
			continue
		}
		width, height := hongguoAppVariantDimensions(row)
		if width <= 0 || height <= 0 {
			continue
		}
		for _, address := range hongguoAppVariantAddresses(row) {
			if isProviderHTTPMediaURL(address) {
				floor = max(floor, min(width, height))
				break
			}
		}
	}
	if floor == 0 {
		return providerMedia{}, parseErr
	}
	address := hongguoModelFallbackAddress(model["fallback_api"])
	if !hongguoAllowedModelURL(address) {
		return providerMedia{}, parseErr
	}
	*attempted = true
	traceHongguoStage(ctx, "model_fallback")
	fallback, err := d.fetchHongguoFallbackModel(ctx, address)
	if err != nil {
		return providerMedia{}, err
	}
	fallbackDuration, valid := hongguoModelDuration(fallback)
	if !valid || hongguoModelVideoID(fallback) != hongguoModelVideoID(model) || math.Abs(fallbackDuration-duration) > 0.5 {
		traceHongguoFailure(ctx, "fallback_invalid")
		return providerMedia{}, errors.New("红果备用模型的视频身份或完整时长无法确认")
	}
	recovered := make(map[string]any, len(fallback))
	for key, value := range fallback {
		recovered[key] = value
	}
	var rows []any
	seed := mapString(fallback, "key_seed")
	for _, value := range hongguoModelVariants(fallback) {
		row, _ := value.(map[string]any)
		width, height := hongguoAppVariantDimensions(row)
		if width <= 0 || height <= 0 || min(width, height) < floor {
			continue
		}
		var addresses []any
		for _, address := range hongguoAppVariantAddresses(row) {
			if seed != "" {
				var err error
				address, err = decodeHongguoSpadeURL(address, seed)
				if err != nil {
					continue
				}
			}
			if hongguoAllowedMediaURL(address) {
				addresses = append(addresses, address)
			}
		}
		if len(addresses) == 0 {
			continue
		}
		clone := make(map[string]any, len(row))
		for key, value := range row {
			clone[key] = value
		}
		clone["main_url"], clone["backup_url"], clone["backup_url_list"] = addresses[0], "", addresses[1:]
		rows = append(rows, clone)
	}
	recovered["video_list"] = rows
	media, err = selectHongguoAppMedia(recovered)
	if err != nil {
		traceHongguoFailure(ctx, "fallback_invalid")
	} else {
		traceHongguoFailure(ctx, "")
	}
	return media, err
}

func hongguoModelFallbackAddress(value any) string {
	if values, ok := value.([]any); ok {
		if len(values) == 0 {
			return ""
		}
		value = values[0]
	}
	if text, ok := value.(string); ok {
		var wrapper map[string]any
		if json.Unmarshal([]byte(text), &wrapper) == nil && wrapper != nil {
			return mapString(wrapper, "fallback_api")
		}
		return strings.TrimSpace(text)
	}
	if wrapper, ok := value.(map[string]any); ok {
		return mapString(wrapper, "fallback_api")
	}
	return ""
}
func hongguoAllowedURL(address string, domains ...string) bool {
	if len(address) > 8192 {
		return false
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil || parsed.Fragment != "" || parsed.Port() != "" && parsed.Port() != "443" {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	for _, domain := range domains {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}
func hongguoAllowedModelURL(address string) bool {
	return hongguoAllowedURL(address, "fqnovel.com", "snssdk.com")
}
func hongguoAllowedMediaURL(address string) bool {
	return hongguoAllowedURL(address, "qznovelvod.com", "fqnovelvod.com", "douyinvod.com")
}

func (d *Downloader) fetchHongguoFallbackModel(ctx context.Context, address string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, errors.New("红果备用模型地址无效")
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json")
	response, err := d.doPreparedCatalogRequestWithClient(request, 8*time.Second, nil, hongguoAnonymousClient(d.client))
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		var backoff *requestBackoff
		if errors.As(err, &backoff) {
			return nil, hongguoHTTPRefusal(ctx, backoff.status, err)
		}
		traceHongguoFailure(ctx, "fallback_request_failed")
		return nil, errors.New("红果备用模型请求失败")
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	traceUpdate(ctx, func(v *mobileDiagnostic) { v.ResponseBytes = int64(len(content)) })
	if response.StatusCode != http.StatusOK {
		return nil, hongguoHTTPRefusal(ctx, response.StatusCode, errors.New("红果备用模型接口暂不可用"))
	}
	traceHongguoFailure(ctx, "fallback_invalid")
	if err != nil || len(content) > providerMaxBodyBytes {
		return nil, errors.New("红果备用模型返回无效数据")
	}
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	var result map[string]any
	var extra any
	if decoder.Decode(&result) != nil || result == nil || decoder.Decode(&extra) != io.EOF {
		return nil, errors.New("红果备用模型返回格式异常")
	}
	for _, envelope := range []map[string]any{result, nestedMap(result, "video_info")} {
		if code := firstNonEmpty(mapString(envelope, "code", "Code", "status_code"), mapString(nestedMap(envelope, "BaseResp"), "StatusCode")); code != "" && code != "0" {
			traceHongguoFailure(ctx, "business_rejected")
			return nil, errors.New("红果备用模型暂未提供本集资源")
		}
	}
	return nestedMap(result, "video_info", "data"), nil
}

func decodeHongguoSpadeURL(encoded, seed string) (string, error) {
	fail := errors.New("红果备用媒体地址格式无效")
	if len(encoded) > 16384 || len(seed) > 128 {
		return "", fail
	}
	raw, err := decodeHongguoBase64(strings.NewReplacer("-", "+", "_", "/").Replace(encoded))
	if err != nil || len(raw) < 20 || raw[0] != 0xa8 || raw[2] != 1 || raw[3] != 0 || (len(raw)-4)%aes.BlockSize != 0 {
		return "", fail
	}
	material, err := decodeHongguoBase64(strings.NewReplacer("-", "+", "_", "/").Replace(seed))
	if err != nil || len(material) == 0 || len(material) > 64 {
		return "", fail
	}
	first := sha512.Sum512(material)
	salt := hongguoSignHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	derived := sha512.Sum512(append(first[:], salt...))
	block, err := aes.NewCipher(derived[:16])
	if err != nil {
		return "", fail
	}
	plain := make([]byte, len(raw)-4)
	cipher.NewCBCDecrypter(block, derived[16:32]).CryptBlocks(plain, raw[4:])
	if plain[len(plain)-1] == 0 {
		plain = bytes.TrimRight(plain, "\x00")
	} else {
		plain, err = pkcs7Unpad(plain, aes.BlockSize)
		if err != nil {
			return "", fail
		}
	}
	return string(plain), nil
}
