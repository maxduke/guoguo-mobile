// Protocol adaptation of hongguoTV Signer.kt (drpys 22261ad), GPL-3.0-only.
// See native/core/UPSTREAM.md for source revisions and compatibility fixtures.
package app

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"math"
	"math/bits"
	"strconv"
	"time"
)

type hongguoAppSigner struct {
	deviceID string
	version  string
	now      time.Time
	random   func() uint32
}

func hongguoSignLE(value uint32) []byte { return binary.LittleEndian.AppendUint32(nil, value) }
func hongguoSignBE(value uint32) []byte { return binary.BigEndian.AppendUint32(nil, value) }

func hongguoSignHex(value string) []byte {
	decoded, err := hex.DecodeString(value)
	if err != nil {
		panic("invalid Hongguo signing constant")
	}
	return decoded
}

func hongguoSignIV(initial uint32, data []byte) uint32 {
	value := initial
	for i, b := range data {
		if i&1 == 0 {
			value = value>>4 ^ value ^ value<<6 ^ uint32(b)
		} else {
			value = ^(value>>7 ^ value ^ (uint32(b) | value<<12))
		}
	}
	return value
}

func hongguoSignHashIV(query, body []byte, stamp uint32) uint32 {
	return hongguoSignIV(hongguoSignIV(hongguoSignIV(0x20230928, query), body), hongguoSignLE(stamp))
}

func hongguoSignChecksum(data []byte) uint32 {
	check := uint32(0x20220420)
	for i := range 12 {
		if i&1 == 0 {
			previous := check>>3 ^ check
			check = uint32(data[i]) ^ check<<7 ^ previous
		} else {
			previous := check>>5 ^ check
			check = ^(uint32(data[i]) | check<<11) ^ previous
		}
	}
	return (check | 4) ^ 0x1000000
}

// The request ticket is selected before signing so only supported hash branch 0
// reaches this transform. The table and rotations are wire-protocol constants.
func hongguoSignHash(query, body []byte, stamp uint32) []byte {
	index := (hongguoSignHashIV(query, body, stamp) & 15) / 3
	iv := [...]uint32{0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1}[index]
	count := iv + stamp
	var table [64]uint32
	for i, value := range hongguoAppHashTable {
		table[i] = bits.RotateLeft32(value, -int((count+1)&255))
	}
	data := append(append(append([]byte(nil), query...), body...), hongguoSignLE(stamp)...)
	for _, value := range []uint32{0xfa, 0x45, 0x61, 0xd7} {
		data = append(data, byte((value|value<<8)>>((count+2)&7)))
	}
	data = append(data, hongguoSignHex("00000000000001a0")...)
	var words [128]uint32
	for i := range 16 {
		words[i] = binary.BigEndian.Uint32(data[i*4:])
	}
	for i := range 112 {
		x, y := words[i+1], words[i+14]
		words[i+16] = words[i] + words[i+9] + (bits.RotateLeft32(x, 14) ^ bits.RotateLeft32(x, 25) ^ x>>3) + (bits.RotateLeft32(y, 13) ^ bits.RotateLeft32(y, 15) ^ y>>10)
	}
	initial := [8]uint32{0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264}
	for i, value := range initial {
		initial[i] = bits.RotateLeft32(value, -int(count))
	}
	chosen := [6][11]int{
		{101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3}, {96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4},
		{96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5}, {99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6},
		{96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4}, {100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5},
	}[index]
	d := initial
	for i := range chosen[0] {
		base := iv + uint32(i)
		n1 := ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]
		n2 := bits.RotateLeft32(d[chosen[1]], 26) ^ bits.RotateLeft32(d[chosen[1]], 21) ^ bits.RotateLeft32(d[chosen[1]], 7)
		n4 := words[base&127] + n1 + n2 + table[base&63] + d[chosen[5]]
		n5 := bits.RotateLeft32(d[chosen[2]], 30) ^ bits.RotateLeft32(d[chosen[2]], 19) ^ bits.RotateLeft32(d[chosen[2]], 10)
		n6 := d[chosen[2]]&d[chosen[6]] | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]])
		old, last := d[chosen[9]], d[7]
		copy(d[1:], d[:7])
		d[0] = last
		d[chosen[10]], d[chosen[8]] = n5+n6+n4, old+n4
	}
	var combined []byte
	for i := range d {
		combined = binary.BigEndian.AppendUint32(combined, d[i]+initial[i])
	}
	folded := make([]byte, 16, 20)
	for i := range folded {
		folded[i] = combined[i] ^ combined[i+16]
	}
	return binary.LittleEndian.AppendUint32(folded, hongguoSignChecksum(folded))
}

func hongguoAppGorgon(query string, body []byte, stamp uint32, random uint16) string {
	queryHash := md5.Sum([]byte(query))
	input := append([]byte(nil), queryHash[:4]...)
	bodyHash := [16]byte{}
	if body != nil {
		bodyHash = md5.Sum(body)
	}
	input = append(input, bodyHash[:4]...)
	input = append(input, make([]byte, 4)...)
	input = append(input, hongguoSignLE(67503104)...)
	input = append(input, hongguoSignBE(stamp)...)
	key := [8]byte{0x4a, 0x40, 0x16, byte(random >> 8), 0x47, 0x6c, 1, byte(random)}
	var box [256]byte
	for i := range box {
		box[i] = byte(i)
	}
	j := byte(0)
	for i := range box {
		j += box[i] + key[i&7]
		box[i] = box[j]
	}
	j = 0
	out := make([]byte, len(input))
	for n, value := range input {
		i := n + 1
		j += box[i]
		y := box[j]
		box[i] = y
		out[n] = value ^ box[y+y]
	}
	for i := range out {
		out[i] = ^(bits.Reverse8(out[(i+1)%len(out)]^bits.RotateLeft8(out[i], 4)) ^ 20)
	}
	return hex.EncodeToString(append([]byte{0x84, 4, byte(random), byte(random >> 8), 0x40, 1}, out...))
}

type hongguoSignProto []byte

func (p *hongguoSignProto) sint(field uint64, value int64) {
	*p = binary.AppendUvarint(*p, field<<3)
	*p = binary.AppendUvarint(*p, uint64(value<<1)^uint64(value>>63))
}

func (p *hongguoSignProto) bytes(field uint64, value []byte) {
	if len(value) > 0 {
		*p = binary.AppendUvarint(*p, field<<3|2)
		*p = binary.AppendUvarint(*p, uint64(len(value)))
		*p = append(*p, value...)
	}
}

func (p *hongguoSignProto) text(field uint64, value string) { p.bytes(field, []byte(value)) }

func (p *hongguoSignProto) float(field uint64, value float32) {
	*p = binary.AppendUvarint(*p, field<<3|5)
	*p = binary.LittleEndian.AppendUint32(*p, math.Float32bits(value))
}

func (s hongguoAppSigner) deviceProto() []byte {
	var p hongguoSignProto
	p.sint(1, 1)
	p.sint(2, 2)
	p.text(3, "8662")
	p.text(4, s.deviceID)
	p.text(5, "Ai6svO3PyrwDOUSmO6ZcResxu")
	p.text(6, "!noperm!")
	for _, field := range []uint64{7, 8} {
		p.sint(field, -888888)
	}
	p.sint(9, 3)
	p.sint(10, -888888)
	p.text(11, "!notset!")
	p.text(12, "Asia/Shanghai,8")
	p.text(13, "zh_CN")
	p.sint(14, 4)
	for i, value := range []float32{255.24993896484375, 35.58599090576172, 3.467449188232422, 3.467449188232422, 255.1754913330078, 42.17544174194336} {
		p.float(uint64(16+i), value)
	}
	p.text(22, "16")
	p.sint(23, 41)
	p.sint(24, 36)
	for _, field := range []uint64{25, 26, 27} {
		p.sint(field, 1728388016635)
	}
	p.sint(28, 1728388016637)
	p.sint(29, -1)
	for i, value := range []string{"25053RT47C", "Redmi", "25053RT47C", "25053RT47C", "Xiaomi", "Redmi", "Redmi"} {
		p.text(uint64(30+i), value)
	}
	p.sint(38, 31)
	return p
}

func hongguoSignXor(data, key []byte) []byte {
	encoded := make([]byte, len(data))
	for i, value := range data {
		at := i * 4 & 28
		d0, d1 := key[at], key[at+1]
		mixed := bits.RotateLeft8(value, 4) + d0
		mixed = bits.RotateLeft8(^mixed^d1, 3)
		encoded[len(data)-i-1] = ^((mixed + d1) ^ d0)
	}
	last, first := encoded[len(encoded)-1]^encoded[len(encoded)-2], encoded[0]
	encoded[0] = ^last + first
	encoded[1] += encoded[0] ^ encoded[len(encoded)-1] ^ 254
	encoded[2] += (last - first) ^ bits.RotateLeft8(encoded[1], 3) ^ 2
	for i := range len(encoded) - 4 {
		temp := bits.RotateLeft8(encoded[i+2], 3) ^ encoded[i+1] ^ byte(i+3)
		encoded[i+3] += ^temp
	}
	encoded[len(encoded)-1] ^= encoded[len(encoded)-2]
	encoded[0] ^= encoded[1]
	for _, value := range encoded[1:] {
		encoded[0] += value
	}
	return encoded
}

func (s hongguoAppSigner) medusa(query string, body []byte, stamp uint32) string {
	bodyHash := [16]byte{}
	if body != nil {
		bodyHash = md5.Sum(body)
	}
	querySM3 := hongguoSM3([]byte(query))
	queryBodyTS := hongguoSignHash(querySM3[:], bodyHash[:], stamp)
	var nested, environment, timing, message hongguoSignProto
	for i, value := range []int64{111, 10, 694367} {
		nested.sint(uint64(i+1), value)
	}
	nested.sint(5, 586952199)
	messageRandom := s.random()
	environment.sint(1, int64(uint64(s.random())*21>>32)+100)
	environment.sint(2, 146331399)
	environment.sint(3, 146331396)
	environment.sint(5, 7)
	environment.text(6, "v04.06.04.03-bugfix")
	environment.sint(7, int64(uint64(s.random())*2000>>32)+10001)
	environment.bytes(12, s.deviceProto())
	timing.sint(1, s.now.Unix())
	timing.sint(2, -2)
	timing.sint(4, 200)
	environment.bytes(13, timing)
	environment.text(14, s.version)
	queryHash := hongguoSM3(append(append([]byte(query), bodyHash[:]...), "none"...))
	message.bytes(1, hongguoSignHex("f7e85ffad7d7dc3bd62ac87057cf6118"))
	message.sint(2, 3)
	message.sint(3, int64(messageRandom))
	message.text(4, "8662")
	message.text(5, s.deviceID)
	message.text(6, "1588093228")
	message.text(7, s.version)
	message.text(8, "v04.06.04-ml-android")
	message.sint(9, 67503104)
	message.bytes(10, hongguoSignHex("4001000000000000"))
	message.sint(12, int64(stamp))
	message.bytes(13, queryBodyTS)
	message.bytes(14, querySM3[:6])
	message.bytes(15, nested)
	message.text(16, "AXYQOS6n2m60x1fVZHIrH3iol")
	message.sint(17, int64(stamp))
	message.bytes(19, queryHash[:])
	message.text(20, "none")
	message.sint(21, 312)
	message.bytes(23, environment)
	message.text(24, `{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}`)
	r := s.random()
	signKey := hongguoSignHex("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
	hash := hongguoSM3(append(append(append([]byte(nil), signKey...), hongguoSignLE(r)...), signKey...))
	d1 := r >> 16 & 255
	seed := hongguoSignLE(^((d1<<11 | r>>24) ^ d1>>5 ^ d1))
	transformed := append(hongguoSignHex("4001000000000000"), hongguoSignXor(message, hash[:])...)
	for i, j := 0, len(transformed)-1; i < j; i, j = i+1, j-1 {
		transformed[i], transformed[j] = transformed[j], transformed[i]
	}
	for i := range transformed {
		transformed[i] ^= seed[^i&3]
	}
	check := uint32(querySM3[0]&63)<<14 | 0x18000001 | uint32(queryBodyTS[0]&63)<<8
	packed := append([]byte{0x35}, hongguoSignLE(s.random())...)
	packed = append(packed, hongguoSignLE(check)...)
	packed = append(packed, transformed...)
	packed = append(packed, byte(r>>16), byte(r>>24))
	encrypted := hongguoSignEncrypt(packed, stamp)
	version := hongguoSignHex("03000000f7e85ffad7d7dc3bd62ac87057cf6118")
	var prefix []byte
	for i := 0; i < len(version); i += 4 {
		prefix = binary.LittleEndian.AppendUint32(prefix, binary.LittleEndian.Uint32(version[i:])^stamp)
	}
	prefix = append(prefix, byte(r), byte(r>>8), 0, 1)
	return base64.StdEncoding.EncodeToString(append(prefix, encrypted...))
}

func hongguoAppHelios(stamp, random uint32) string {
	prefix := hongguoSignLE(random)
	hash := md5.Sum(append(append([]byte(nil), prefix...), "8662"...))
	ascii := []byte(hex.EncodeToString(hash[:]))
	left, right := binary.LittleEndian.Uint64(ascii), binary.LittleEndian.Uint64(ascii[8:])
	queue := []uint64{binary.LittleEndian.Uint64(ascii[16:]), binary.LittleEndian.Uint64(ascii[24:])}
	var keys [34]uint64
	for i := range keys {
		keys[i] = left
		mixed := (bits.RotateLeft64(right, -8) + left) ^ uint64(i)
		queue = append(queue, mixed)
		left = mixed ^ bits.RotateLeft64(left, 3)
		right, queue = queue[0], queue[1:]
	}
	data := hongguoCommentPad([]byte(strconv.FormatUint(uint64(stamp), 10) + "-1588093228-8662"))
	for offset := 0; offset < len(data); offset += 16 {
		left, right := binary.LittleEndian.Uint64(data[offset:]), binary.LittleEndian.Uint64(data[offset+8:])
		for _, key := range keys {
			right = key ^ (left + bits.RotateLeft64(right, -8))
			left = right ^ bits.RotateLeft64(left, 3)
		}
		binary.LittleEndian.PutUint64(data[offset:], left)
		binary.LittleEndian.PutUint64(data[offset+8:], right)
	}
	return base64.StdEncoding.EncodeToString(append(prefix, data...))
}
