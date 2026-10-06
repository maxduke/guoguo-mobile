package app

import (
	"encoding/binary"
)

const maxCoverBytes = 20 << 20

func isHEICImage(data []byte) bool {
	if len(data) < 16 || string(data[4:8]) != "ftyp" {
		return false
	}
	size := uint64(binary.BigEndian.Uint32(data))
	if size < 16 || size > uint64(len(data)) || size > 256 {
		return false
	}
	for offset := 8; offset+4 <= int(size); offset += 4 {
		if offset == 12 {
			continue
		}
		switch string(data[offset : offset+4]) {
		case "heic", "heix", "hevc", "hevx":
			return true
		}
	}
	return false
}
