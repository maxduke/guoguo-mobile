// SPDX-License-Identifier: GPL-3.0-only
// Playback-only Argus 551/Ladon, adapted from jackotom/hongguo-drama
// 782fb21 src/native/playback-signature.js. See UPSTREAM.md for provenance.
package app

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/bits"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

type hongguoPlayerProto []byte

func (p *hongguoPlayerProto) number(field uint64, value uint32) {
	*p = binary.AppendUvarint(*p, field<<3)
	*p = binary.AppendUvarint(*p, uint64(value))
}

func (p *hongguoPlayerProto) bytes(field uint64, value []byte) {
	*p = binary.AppendUvarint(*p, field<<3|2)
	*p = binary.AppendUvarint(*p, uint64(len(value)))
	*p = append(*p, value...)
}

func hongguoPlayerArgus(query string, body []byte, stamp, random uint32) string {
	values, _ := url.ParseQuery(query)
	aid := firstNonEmpty(values.Get("aid"), "1967")
	queryHash := hongguoSM3([]byte(query))
	bodyHash := [16]byte{}
	if len(body) > 0 {
		bodyHash = md5.Sum(body)
	}
	stubHash := hongguoSM3(bodyHash[:])
	var p, counters, device hongguoPlayerProto
	p.number(1, 1077940818)
	p.number(2, 2)
	p.number(3, random)
	p.bytes(4, []byte(aid))
	p.bytes(5, []byte(values.Get("device_id")))
	p.bytes(6, []byte("1611921764"))
	p.bytes(7, []byte(values.Get("version_name")))
	p.bytes(8, []byte("v04.04.05-ov-android"))
	p.number(9, 134744640)
	p.bytes(10, make([]byte, 8))
	p.number(11, 0)
	p.number(12, stamp<<1)
	p.bytes(13, stubHash[:6])
	p.bytes(14, queryHash[:6])
	for _, field := range []uint64{1, 2, 3} {
		counters.number(field, 1)
	}
	counters.number(7, 0xc792eccc)
	p.bytes(15, counters)
	p.bytes(16, nil)
	p.bytes(20, []byte("none"))
	p.number(21, 738)
	device.bytes(1, []byte("NX551J"))
	device.number(2, 8196)
	device.number(4, 0x80e0d800)
	p.bytes(23, device)
	p.number(25, 2)
	plain := hongguoCommentPad(p)
	key := hongguoSignHex("fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304")
	var keys [72]uint64
	for i := range 4 {
		keys[i] = binary.LittleEndian.Uint64(key[i*8:])
	}
	for i := 4; i < len(keys); i++ {
		tmp := bits.RotateLeft64(keys[i-1], -3) ^ keys[i-3]
		tmp ^= bits.RotateLeft64(tmp, -1)
		bit := uint64(0x3dc94c3a046d678b) >> ((i - 4) % 62) & 1
		keys[i] = ^keys[i-4] ^ tmp ^ bit ^ 3
	}
	for at := 0; at < len(plain); at += 16 {
		x, y := binary.LittleEndian.Uint64(plain[at:]), binary.LittleEndian.Uint64(plain[at+8:])
		for _, k := range keys {
			x, y = y, x^(bits.RotateLeft64(y, 1)&bits.RotateLeft64(y, 8))^bits.RotateLeft64(y, 2)^k
		}
		binary.LittleEndian.PutUint64(plain[at:], x)
		binary.LittleEndian.PutUint64(plain[at+8:], y)
	}
	magic := hongguoSignHex("f2f7fcfff2f7fcff")
	framed := append(append(append([]byte(nil), magic...), plain...), hongguoSignHex("eafb2cfe8568519154")...)
	for i := 8; i < len(framed); i++ {
		framed[i] ^= magic[i%8]
	}
	for i, j := 0, len(framed)-1; i < j; i, j = i+1, j-1 {
		framed[i], framed[j] = framed[j], framed[i]
	}
	framed = hongguoCommentPad(append(framed, 'a', 'o'))
	block, _ := aes.NewCipher(hongguoSignHex("d31e3718288a1027baab59f146a09a9c"))
	cipher.NewCBCEncrypter(block, hongguoSignHex("ea180a0336ed352fcd24e4d50018ae54")).CryptBlocks(framed, framed)
	return base64.StdEncoding.EncodeToString(append([]byte{0xf2, 0x81}, framed...))
}

func signHongguoPlayerRequest(request *http.Request, body []byte, now time.Time) error {
	query := request.URL.Query()
	if query.Get("device_id") == "" || query.Get("version_name") == "" {
		return errors.New("红果播放签名缺少设备或版本信息")
	}
	var entropy [8]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return errors.New("无法准备红果播放请求签名")
	}
	stamp := uint32(now.Unix())
	query.Set("ts", strconv.FormatUint(uint64(stamp), 10))
	query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
	request.URL.RawQuery = query.Encode()
	request.Header.Set("X-Khronos", query.Get("ts"))
	request.Header.Set("X-SS-Req-Ticket", strconv.FormatInt(now.Unix()*1000, 10))
	request.Header.Set("X-Argus", hongguoPlayerArgus(request.URL.RawQuery, body, stamp, binary.LittleEndian.Uint32(entropy[:])))
	request.Header.Set("X-Ladon", hongguoAppLadon(stamp, binary.LittleEndian.Uint32(entropy[4:]), "1611921764", query.Get("aid")))
	if len(body) > 0 {
		stub := md5.Sum(body)
		request.Header.Set("X-SS-STUB", hex.EncodeToString(stub[:]))
	}
	return nil
}
