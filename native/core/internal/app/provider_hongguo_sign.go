package app

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

func newHongguoDeviceID() string {
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 10)
	}
	return strconv.FormatUint(1_000_000_000_000_000_000+binary.BigEndian.Uint64(random[:])%8_000_000_000_000_000_000, 10)
}

func signHongguoRequest(request *http.Request, body []byte, now time.Time) error {
	query := request.URL.Query()
	if query.Get("device_id") == "" || query.Get("version_name") == "" {
		return errors.New("红果 App 签名缺少设备或版本信息")
	}
	var entropy [28]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return errors.New("无法准备红果 App 请求签名")
	}
	index := 0
	random := func() uint32 {
		value := binary.LittleEndian.Uint32(entropy[index:])
		index += 4
		return value
	}
	stamp := uint32(now.Unix())
	query.Set("ts", strconv.FormatUint(uint64(stamp), 10))
	bodyHash := [16]byte{}
	if body != nil {
		bodyHash = md5.Sum(body)
		request.Header.Set("X-SS-STUB", fmt.Sprintf("%X", bodyHash))
	}
	for offset := range 128 {
		query.Set("_rticket", strconv.FormatInt(now.UnixMilli()+int64(offset), 10))
		encoded := query.Encode()
		hash := hongguoSM3([]byte(encoded))
		if (hongguoSignHashIV(hash[:], bodyHash[:], stamp)&15)%3 != 0 {
			continue
		}
		request.URL.RawQuery = encoded
		signer := hongguoAppSigner{deviceID: query.Get("device_id"), version: query.Get("version_name"), now: now, random: random}
		request.Header.Set("X-Khronos", strconv.FormatUint(uint64(stamp), 10))
		request.Header.Set("X-SS-Req-Ticket", query.Get("_rticket"))
		request.Header.Set("X-TT-Request-Tag", "t=0;n=0")
		request.Header.Set("Passport-Sdk-Version", "50561")
		request.Header.Set("X-Ladon", base64.StdEncoding.EncodeToString(hongguoSignBE(stamp)))
		request.Header.Set("X-Argus", base64.StdEncoding.EncodeToString(hongguoSignLE(stamp)))
		request.Header.Set("X-Gorgon", hongguoAppGorgon(encoded, body, stamp, uint16(random()>>16)))
		request.Header.Set("X-Helios", hongguoAppHelios(stamp, random()))
		request.Header.Set("X-Medusa", signer.medusa(encoded, body, stamp))
		if body != nil {
			request.Header.Set("X-VC-Bdturing-Sdk-Version", "3.7.2.cn")
		}
		return nil
	}
	return errors.New("无法生成红果 App 请求签名")
}
