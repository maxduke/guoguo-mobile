// Protocol-specific AES variant from hongguoTV AesV3.kt; GPL-3.0-only.
package app

import "encoding/base64"

var hongguoAppHashTable = [...]uint32{
	0xebb64faf, 0x7aadcc2, 0xcf3187bf, 0xe01138ff,
	0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
	0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51,
	0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
	0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00,
	0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
	0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83,
	0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
	0x617ce2a6, 0xe423417e, 0xa40e143, 0x544e4032,
	0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x5b23bb3,
	0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50,
	0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
	0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581,
	0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
	0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1,
	0x6ca86f6e, 0x284ba7, 0x8387cfa, 0x5fb37586,
}

var hongguoAppSBox = decodeHongguoSigningSBox("+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==")

func hongguoSignEncrypt(source []byte, stamp uint32) []byte {
	word := stamp & 3
	box := hongguoAppSBox[word*256 : (word+1)*256]
	con := [4][4]int{{1, 0, 2, 3}, {2, 0, 3, 1}, {0, 1, 3, 2}, {1, 0, 2, 3}}[word]
	order := [4][16]int{
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15},
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
	}[word]
	initial := [4]uint32{0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f}[word]
	key := hongguoSignHex("f1593376766ea98d34f31b057a9d5be4")
	var expanded [48]byte
	for i := range 16 {
		expanded[i] = hongguoSignLE(initial)[i&3] ^ key[i]
	}
	rounds := uint32(8)
	for i := 4; i < 12; i++ {
		at := 4 * (i - 1)
		a, b, c, d := expanded[at], expanded[at+1], expanded[at+2], expanded[at+3]
		if i&3 == 0 {
			temp := byte(initial>>(rounds&24)) ^ box[b]
			b, c, d, a = box[c], box[d], box[a], temp
		}
		rounds += 2
		expanded[at+4], expanded[at+5], expanded[at+6], expanded[at+7] = a^expanded[at-12], b^expanded[at-11], c^expanded[at-10], d^expanded[at-9]
	}
	block := func(value []byte) []byte {
		var rows [4][4]byte
		for i := range 16 {
			rows[i/4][i%4] = value[i]
		}
		addCon := func(offset int) {
			for i := range 4 {
				for j := range 4 {
					rows[i][j] ^= expanded[(offset+i)*4+con[j]]
				}
			}
		}
		addCon(0)
		for round := 1; round <= 2; round++ {
			for i := range 4 {
				for j := range 4 {
					rows[i][j] = box[rows[i][j]]
				}
			}
			before := rows
			for i := range 4 {
				rows[i] = before[con[i]]
			}
			before = rows
			for i, from := range order {
				rows[i/4][i%4] = before[from/4][from%4]
			}
			if round == 1 {
				for i := range 4 {
					old := rows[i]
					for j := range 4 {
						rows[i][j] = old[con[j]]
					}
				}
				xt := func(x byte) byte {
					if x&128 != 0 {
						return x<<1 ^ 0x1b
					}
					return x << 1
				}
				for i := range 4 {
					t, u := rows[0][i]^rows[1][i]^rows[2][i]^rows[3][i], rows[0][i]
					rows[0][i] ^= t ^ xt(rows[0][i]^rows[1][i])
					rows[1][i] ^= t ^ xt(rows[1][i]^rows[2][i])
					rows[2][i] ^= t ^ xt(rows[2][i]^rows[3][i])
					rows[3][i] ^= t ^ xt(rows[3][i]^u)
				}
			}
			addCon(round * 4)
		}
		out := make([]byte, 16)
		for i := range 16 {
			out[i] = rows[i/4][i%4] ^ expanded[(4+i/4)*4+i%4]
		}
		return out
	}
	plain := make([]byte, 32)
	for i := range 31 {
		at := i * 8
		plain[i] = source[at]>>4&2 | source[at+1]&64 | source[at+2]>>2&1 | source[at+3]<<3&128 | source[at+4]>>1&4 | source[at+5]<<3&16 | source[at+6]<<5&32 | source[at+7]>>4&8
	}
	plain[31] = 1
	iv := hongguoSignHex("1fe109a4125283f418de9e051a969e12")
	for i := range 16 {
		plain[i] ^= iv[i]
	}
	first := block(plain[:16])
	for i := range 16 {
		plain[i+16] ^= first[i]
	}
	key = append(first, block(plain[16:])...)
	out := append([]byte(nil), source...)
	for i := range 31 {
		at, k := i*8, key[i]
		out[at] = out[at]&0xdf | k<<4&32
		out[at+1] = out[at+1]&0xbf | k&64
		out[at+2] = out[at+2]&0xfb | k<<2&4
		out[at+3] = out[at+3]&0xef | k>>3&16
		out[at+4] = out[at+4]&0xf7 | (k+k)&8
		out[at+5] = out[at+5]&0xfd | k>>3&2
		out[at+6] = out[at+6]&0xfe | k>>5&1
		out[at+7] = out[at+7]&0x7f | k<<4&128
	}
	return append([]byte{key[31]}, out...)
}

func decodeHongguoSigningSBox(encoded string) []byte {
	box, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(box) != 1024 {
		panic("invalid Hongguo signing table")
	}
	return box
}
