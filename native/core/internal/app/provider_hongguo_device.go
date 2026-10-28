// Protocol adaptation of hongguoTV DeviceRegister.kt and PlaybackDeviceSession.kt,
// GPL-3.0-only. Source revisions and attribution: native/core/UPSTREAM.md.
package app

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha512"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const hongguoDeviceRegisterURL = "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"
const hongguoDeviceMaxBody = 64 * 1024

var errHongguoDeviceRegistration = errors.New("红果播放设备注册失败，请稍后重试")

type hongguoPlayerDeviceCall struct {
	done     chan struct{}
	identity hongguoPlayerIdentity
	err      error
}

// Share one registration between foreground playback and episode prefetch.
// Waiting callers can cancel independently; a canceled owner publishes no identity.
func (downloader *Downloader) hongguoPlaybackDevice(ctx context.Context) (hongguoPlayerIdentity, error) {
	client := downloader.hongguoClient()
	for {
		if err := ctx.Err(); err != nil {
			return hongguoPlayerIdentity{}, err
		}
		client.mu.Lock()
		if client.player.deviceID != "" {
			identity := client.player
			client.mu.Unlock()
			return identity, nil
		}
		if pending := client.playerPending; pending != nil {
			client.mu.Unlock()
			traceShared(ctx)
			select {
			case <-ctx.Done():
				return hongguoPlayerIdentity{}, ctx.Err()
			case <-pending.done:
				if ctx.Err() != nil {
					return hongguoPlayerIdentity{}, ctx.Err()
				}
				if errors.Is(pending.err, context.Canceled) || errors.Is(pending.err, context.DeadlineExceeded) {
					continue
				}
				return pending.identity, pending.err
			}
		}
		pending := &hongguoPlayerDeviceCall{done: make(chan struct{})}
		client.playerPending = pending
		client.mu.Unlock()

		identity, err := downloader.registerHongguoPlaybackDevice(ctx)
		client.mu.Lock()
		if ctx.Err() != nil {
			identity, err = hongguoPlayerIdentity{}, ctx.Err()
		}
		if err == nil {
			client.player = identity
		}
		pending.identity, pending.err = identity, err
		client.playerPending = nil
		close(pending.done)
		client.mu.Unlock()
		return identity, err
	}
}

// Keep account/site cookies out of both registration and playback. Fixed API
// endpoints must not forward registration payloads or device cookies on redirects.
func hongguoAnonymousClient(client *http.Client) *http.Client {
	anonymous := *client
	anonymous.Jar = nil
	anonymous.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &anonymous
}

func (downloader *Downloader) registerHongguoPlaybackDevice(ctx context.Context) (hongguoPlayerIdentity, error) {
	cdid, err := newHongguoDeviceUUID()
	if err != nil {
		return hongguoPlayerIdentity{}, errHongguoDeviceRegistration
	}
	now := time.Now()
	body, err := hongguoDeviceRegistrationPayload(cdid, now)
	if err != nil {
		return hongguoPlayerIdentity{}, errHongguoDeviceRegistration
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoDeviceRegisterURL, bytes.NewReader(body))
	if err != nil {
		return hongguoPlayerIdentity{}, errHongguoDeviceRegistration
	}
	for name, value := range map[string]string{
		"User-Agent": hongguoAppUserAgent, "Content-Type": "application/octet-stream;tt-data=a",
		"Log-Encode-Type": "gzip", "X-SS-DP": "8662", "X-SS-Req-Ticket": strconv.FormatInt(now.UnixMilli(), 10),
		"X-VC-Bdturing-Sdk-Version": "4.0.3.cn", "Lc": "101", "Sdk-Version": "2", "Passport-Sdk-Version": "5051452",
		"X-Neptune": "-8|50:51:59:30:40:47:49:39", "X-SS-STUB": fmt.Sprintf("%X", md5.Sum(body)),
	} {
		request.Header.Set(name, value)
	}
	response, err := downloader.doPreparedCatalogRequestWithClient(request, 20*time.Second, nil, hongguoAnonymousClient(downloader.client))
	if err != nil {
		if ctx.Err() != nil {
			return hongguoPlayerIdentity{}, ctx.Err()
		}
		return hongguoPlayerIdentity{}, fmt.Errorf("%w: %w", errHongguoDeviceRegistration, publicError(err))
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return hongguoPlayerIdentity{}, fmt.Errorf("%w（HTTP %d）", errHongguoDeviceRegistration, response.StatusCode)
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, hongguoDeviceMaxBody+1))
	if err != nil || len(content) == 0 || len(content) > hongguoDeviceMaxBody {
		return hongguoPlayerIdentity{}, errHongguoDeviceRegistration
	}
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	var result map[string]any
	var extra any
	if decoder.Decode(&result) != nil || result == nil || decoder.Decode(&extra) != io.EOF {
		return hongguoPlayerIdentity{}, errHongguoDeviceRegistration
	}
	identity := hongguoPlayerIdentity{
		deviceID: mapString(result, "device_id_str", "device_id"), installID: mapString(result, "install_id_str", "install_id"), cdid: cdid,
	}
	for _, id := range []string{identity.deviceID, identity.installID} {
		if len(id) > 30 || !hongguoNumericID.MatchString(id) || id[0] == '0' {
			return hongguoPlayerIdentity{}, errHongguoDeviceRegistration
		}
	}
	cookies := make(map[string]string)
	for _, cookie := range response.Cookies() {
		if cookie.MaxAge < 0 || len(cookie.Value) > 4096 {
			delete(cookies, cookie.Name)
		} else {
			cookies[cookie.Name] = cookie.Value
		}
	}
	cookieRequest := &http.Request{Header: make(http.Header)}
	for _, name := range []string{"install_id", "ttreq", "store-region", "store-region-src"} {
		if value := cookies[name]; value != "" {
			cookieRequest.AddCookie(&http.Cookie{Name: name, Value: value})
		}
	}
	identity.cookie = cookieRequest.Header.Get("Cookie")
	return identity, nil
}

func newHongguoDeviceUUID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6], value[8] = value[6]&0x0f|0x40, value[8]&0x3f|0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[:4], value[4:6], value[6:8], value[8:10], value[10:]), nil
}

func hongguoDeviceRegistrationPayload(cdid string, now time.Time) ([]byte, error) {
	clientID, err := newHongguoDeviceUUID()
	if err != nil {
		return nil, err
	}
	requestID, err := newHongguoDeviceUUID()
	if err != nil {
		return nil, err
	}
	device := hongguoAppDeviceQuery()
	jsonBody, err := json.Marshal(map[string]any{
		"magic_tag": "ss_app_log", "_gen_time": now.UnixMilli(),
		"header": map[string]any{
			"display_name": "红果免费短剧", "aid": 8662, "package": "com.phoenix.read", "channel": device.Get("channel"),
			"update_version_code": json.Number(hongguoAppVersionCode), "manifest_version_code": json.Number(hongguoAppVersionCode),
			"version_code": json.Number(hongguoAppVersionCode), "app_version": hongguoAppVersion, "app_version_minor": hongguoAppVersion,
			"sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo", "sdk_target_version": 29, "git_hash": "3a88f4e",
			"os": "Android", "os_version": device.Get("os_version"), "os_api": json.Number(device.Get("os_api")),
			"device_model": device.Get("device_type"), "device_brand": device.Get("device_brand"), "device_manufacturer": device.Get("device_brand"),
			"cpu_abi": "arm64-v8a", "release_build": "b5e187f", "density_dpi": json.Number(device.Get("dpi")), "display_density": "mdpi",
			"resolution": strings.ReplaceAll(device.Get("resolution"), "*", "x"), "language": "zh", "timezone": 8, "access": "wifi",
			"not_request_sender": 0, "carrier": "CHINA MOBILE", "mcc_mnc": "46000", "rom": "eng.root.20231116.160340", "rom_version": "W528JS release-keys",
			"cdid": cdid, "sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": strings.ReplaceAll(clientID, "-", "")[:16],
			"clientudid": clientID, "ipv6_list": []string{}, "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800,
			"sim_region": "cn", "sim_serial_number": []string{}, "oaid_may_support": false, "req_id": requestID, "device_platform": "android",
			"custom":                map[string]any{"account_region_src": "fallback", "host_bit": 64, "account_region": "cn", "dragon_device_type": "pad"},
			"pre_installed_channel": "", "apk_first_install_time": now.UnixMilli(), "is_system_app": 0, "sdk_flavor": "china", "guest_mode": 0,
		},
	})
	if err != nil {
		return nil, err
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(jsonBody); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	var seed [32]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return nil, err
	}
	seedHash := sha512.Sum512(seed[:])
	salt := hongguoSignHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	derived := sha512.Sum512(append(seedHash[:], salt...))
	checksum := sha512.Sum512(compressed.Bytes())
	plain := append(checksum[:], compressed.Bytes()...)
	padding := aes.BlockSize - len(plain)%aes.BlockSize
	plain = append(plain, bytes.Repeat([]byte{byte(padding)}, padding)...)
	block, err := aes.NewCipher(derived[:16])
	if err != nil {
		return nil, err
	}
	encrypted := make([]byte, len(plain))
	cipher.NewCBCEncrypter(block, derived[16:32]).CryptBlocks(encrypted, plain)
	return append(append([]byte{0x74, 0x63, 5, 0x10, 0, 0}, seed[:]...), encrypted...), nil
}
