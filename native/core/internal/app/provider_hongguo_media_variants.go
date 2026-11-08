// Selective model-field and backup handling adapted from hongguo-drama,
// GPL-3.0-only. Pinned sources and local contracts: native/core/UPSTREAM.md.
package app

import (
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
)

const hongguoAddressesPerQualityCodec = 4

var errHongguoEncryptionMetadataMissing = errors.New("红果媒体未明确提供加密信息")

func hongguoAppCodecPriority(variant map[string]any) (int, bool) {
	meta := nestedMap(variant, "video_meta")
	top, nested := strings.ToLower(mapString(variant, "codec_type")), strings.ToLower(mapString(meta, "codec_type"))
	gear := strings.ToLower(mapString(variant, "gear_des_key"))
	if top == "bytevc2" || top == "bvc2" || nested == "bytevc2" || nested == "bvc2" || strings.Contains(gear, "bytevc2") || strings.Contains(gear, "bvc2") {
		return 0, false
	}
	switch firstNonEmpty(top, nested) {
	case "h264", "avc", "avc1":
		return 0, true
	case "hevc", "h265", "hvc1", "hev1", "bytevc1":
		return 1, true
	}
	return 0, false
}

func hongguoAppVariantKey(variant map[string]any) ([]byte, error) {
	encryption := nestedMap(variant, "encrypt_info")
	spade := firstNonEmpty(mapString(variant, "spade_a"), mapString(encryption, "spade_a"))
	if spade != "" {
		return hongguoContentKey(spade)
	}
	// Never turn encrypted, unknown or contradictory metadata into plaintext.
	clear := false
	for _, fields := range []map[string]any{variant, encryption} {
		if method := strings.ToLower(mapString(fields, "encryption_method")); method != "" && method != "none" {
			return nil, errors.New("红果媒体缺少有效密钥")
		}
		if _, present := fields["encrypt"]; !present {
			continue
		}
		if !hongguoAppPlaintextFlag(fields["encrypt"]) {
			return nil, errors.New("红果媒体缺少有效密钥")
		}
		clear = true
	}
	if !clear {
		return nil, errHongguoEncryptionMetadataMissing
	}
	return nil, nil
}

func hongguoAppPlaintextFlag(value any) bool {
	switch flag := value.(type) {
	case bool:
		return !flag
	case int:
		return flag == 0
	case float64:
		return flag == 0
	case json.Number:
		number, err := flag.Float64()
		return err == nil && number == 0
	case string:
		flag = strings.ToLower(strings.TrimSpace(flag))
		return flag == "0" || flag == "false"
	}
	return false
}

func hongguoAppVariantDimensions(variant map[string]any) (int, int) {
	meta := nestedMap(variant, "video_meta")
	for _, pair := range [][2]string{
		{mapString(variant, "vwidth"), mapString(variant, "vheight")},
		{mapString(variant, "width"), mapString(variant, "height")},
		{mapString(meta, "vwidth"), mapString(meta, "vheight")},
		{mapString(meta, "width"), mapString(meta, "height")},
	} {
		width, e1 := strconv.Atoi(pair[0])
		height, e2 := strconv.Atoi(pair[1])
		if e1 == nil && e2 == nil && width > 0 && height > 0 {
			return width, height
		}
	}
	return 0, 0
}

func hongguoAppVariantQuality(variant map[string]any) int {
	if width, height := hongguoAppVariantDimensions(variant); width > 0 && height > 0 {
		return min(width, height)
	}
	meta := nestedMap(variant, "video_meta")
	definition := firstNonEmpty(mapString(variant, "definition", "quality_desc"), mapString(meta, "definition", "quality_desc"))
	quality, _ := strconv.Atoi(hongguoQualityNumber.FindString(definition))
	return quality
}

func hongguoAppVariantAddresses(variant map[string]any) []string {
	addresses := []string{mapString(variant, "main_url"), mapString(variant, "backup_url")}
	for _, value := range anyList(variant["backup_url_list"]) {
		if address, ok := value.(string); ok {
			addresses = append(addresses, strings.TrimSpace(address))
		}
	}
	return addresses
}

func hongguoModelVariants(model map[string]any) []any {
	if rows, ok := model["video_list"].(map[string]any); ok {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		// Preserve deterministic model ordering, as in the ordinary parser.
		sort.Strings(keys)
		out := make([]any, 0, len(rows))
		for _, key := range keys {
			out = append(out, rows[key])
		}
		return out
	}
	return anyList(model["video_list"])
}
