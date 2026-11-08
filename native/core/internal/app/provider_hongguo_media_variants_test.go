package app

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"testing"
)

const hongguoSyntheticSpade = "mr8T+Vu+EvdZvhL1X7kR90G6DvVfpSbcXaUm3luiJdyloGR1dVpzNA=="

func TestHongguoMediaNormalizesVariantFields(t *testing.T) {
	for _, nested := range []bool{false, true} {
		t.Run(fmt.Sprint(nested), func(t *testing.T) {
			row := map[string]any{"main_url": "https://media.example.test/full.mp4"}
			meta := map[string]any{"codec_type": "h264", "definition": "2160p", "vwidth": json.Number("1080"), "vheight": json.Number("1920")}
			if nested {
				row["video_meta"] = meta
				row["encrypt_info"] = map[string]any{"encrypt": true, "spade_a": hongguoSyntheticSpade}
			} else {
				for k, v := range meta {
					row[k] = v
				}
				row["encrypt"] = true
				row["spade_a"] = hongguoSyntheticSpade
			}
			media, err := selectHongguoAppMedia(map[string]any{"video_duration": 56.007, "video_list": []any{row}})
			if err != nil || media.Quality != 1080 || hex.EncodeToString(media.CENCKey) != "00112233445566778899aabbccddeeff" {
				t.Fatal("lost actual dimensions or key", err, media.Quality)
			}
		})
	}
}

func TestHongguoMediaEncryptionFlags(t *testing.T) {
	for _, nested := range []bool{false, true} {
		for _, flag := range []any{false, 0, float64(0), json.Number("0"), json.Number("0.0"), json.Number("0e0"), "0", "false", " FALSE "} {
			t.Run(fmt.Sprintf("clear/%t/%T/%v", nested, flag, flag), func(t *testing.T) {
				row := map[string]any{"main_url": "https://media.example.test/plain.mp4", "codec_type": "h264"}
				if nested {
					row["encrypt_info"] = map[string]any{"encrypt": flag}
				} else {
					row["encrypt"] = flag
				}
				media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}})
				if err != nil || len(media.CENCKey) != 0 {
					t.Fatal("explicit clear flag rejected", err)
				}
			})
		}
		for _, flag := range []any{true, 1, float64(1), json.Number("1"), "1", "true", "unknown", nil} {
			t.Run(fmt.Sprintf("missing-key/%t/%T/%v", nested, flag, flag), func(t *testing.T) {
				row := map[string]any{"main_url": "https://media.example.test/encrypted.mp4", "codec_type": "h264"}
				if nested {
					row["encrypt_info"] = map[string]any{"encrypt": flag}
				} else {
					row["encrypt"] = flag
				}
				if media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}}); err == nil || media.URL != "" {
					t.Fatal("missing key treated as plaintext")
				}
			})
		}
	}
	for _, method := range []string{"", "none", "NONE"} {
		row := map[string]any{"main_url": "https://media.example.test/plain.mp4", "codec_type": "h264", "encrypt_info": map[string]any{"encrypt": false, "encryption_method": method}}
		if _, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}}); err != nil {
			t.Fatal("explicit unencrypted method rejected", method, err)
		}
	}
	for _, metadata := range []map[string]any{
		{}, {"encrypt": false, "encrypt_info": map[string]any{"encrypt": true}},
		{"encrypt": false, "encrypt_info": map[string]any{"encryption_method": "cenc-aes-ctr"}},
		{"encrypt": false, "spade_a": "invalid"},
	} {
		row := map[string]any{"main_url": "https://media.example.test/unknown.mp4", "codec_type": "h264"}
		for k, v := range metadata {
			row[k] = v
		}
		if media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}}); err == nil || media.URL != "" {
			t.Fatal("incomplete/conflicting encryption accepted")
		}
	}
}

func TestHongguoMediaRejectsUnsupportedTopLevelCodec(t *testing.T) {
	for _, codec := range []string{"bytevc2", "BVC2", "av1", "vp9", "unknown"} {
		row := map[string]any{"main_url": "https://media.example.test/bad.mp4", "codec_type": codec, "encrypt": false}
		if media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}}); err == nil || media.URL != "" {
			t.Fatal("unsupported codec accepted", codec)
		}
	}
	row := map[string]any{"main_url": "https://media.example.test/conflict.mp4", "codec_type": "h264", "video_meta": map[string]any{"codec_type": "bytevc2"}, "encrypt": false}
	if _, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}}); err == nil {
		t.Fatal("nested ByteVC2 hidden by top-level codec")
	}
	for _, codec := range []string{"h264", "avc", "avc1", "hevc", "h265", "hvc1", "hev1", "bytevc1"} {
		row := map[string]any{"main_url": "https://media.example.test/good.mp4", "codec_type": codec, "encrypt": false}
		if _, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}}); err != nil {
			t.Fatal("compatible codec rejected", codec, err)
		}
	}
}

func TestHongguoMediaPreservesEqualQualityAlternatives(t *testing.T) {
	model := map[string]any{"video_list": []any{
		map[string]any{"codec_type": "hevc", "definition": "1080p", "encrypt": true, "spade_a": hongguoSyntheticSpade, "main_url": "https://media.example.test/hevc.mp4"},
		map[string]any{"codec_type": "avc", "definition": "1080p", "encrypt": true, "spade_a": hongguoSyntheticSpade, "main_url": "https://media.example.test/avc.mp4", "backup_url": "https://media.example.test/backup.mp4", "backup_url_list": []any{"https://media.example.test/avc.mp4", "file:///private/secret", 42, "https://user:password@media.example.test/secret", "https://media.example.test/backup-2.mp4"}},
		map[string]any{"codec_type": "h264", "definition": "720p", "encrypt": false, "main_url": "https://media.example.test/low.mp4"},
	}}
	media, err := selectHongguoAppMedia(model)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"avc.mp4", "backup.mp4", "backup-2.mp4", "hevc.mp4", "low.mp4"}
	if len(media.Variants) != len(want) {
		t.Fatal("lost distinct same-quality backups", len(media.Variants))
	}
	for i, v := range media.Variants {
		if v.URL != "https://media.example.test/"+want[i] {
			t.Fatal("unstable fallback order", i, v.URL)
		}
		if i < 4 && hex.EncodeToString(v.CENCKey) != "00112233445566778899aabbccddeeff" {
			t.Fatal("backup lost key")
		}
	}
	fixed, err := mobilePlaybackChoices(media, nil, 1080)
	if err != nil || len(fixed.media) != 4 {
		t.Fatal("manual quality lost alternatives", err)
	}
	for _, v := range fixed.media {
		if v.Quality != 1080 {
			t.Fatal("manual quality downgraded")
		}
	}
	auto, err := mobilePlaybackChoices(media, nil, 0)
	if err != nil || len(auto.media) != 5 || auto.media[4].Quality != 720 {
		t.Fatal("auto quality lost lower rendition", err)
	}
}

func TestHongguoMediaBackupOnlyAndVariantBounds(t *testing.T) {
	backups := []any{"javascript:alert(1)", "https://media.example.test/backup.mp4"}
	row := map[string]any{"codec_type": "h264", "encrypt": false, "backup_url_list": backups}
	media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}})
	if err != nil || media.URL != "https://media.example.test/backup.mp4" {
		t.Fatal("usable backup-only model rejected", err)
	}
	var rows []any
	for _, codec := range []string{"h264", "hevc"} {
		for n := 0; n < 30; n++ {
			rows = append(rows, map[string]any{"codec_type": codec, "definition": "1080p", "encrypt": false, "main_url": fmt.Sprintf("https://media.example.test/%s-%d.mp4", codec, n)})
		}
	}
	media, err = selectHongguoAppMedia(map[string]any{"video_list": rows})
	if err != nil || len(media.Variants) != 8 {
		t.Fatal("unbounded variants or codec lost", err, len(media.Variants))
	}
	if media.Variants[4].URL != "https://media.example.test/hevc-0.mp4" {
		t.Fatal("same-quality HEVC exhausted by AVC backups")
	}
}

func TestHongguoMediaQualityUsesActualDimensionsBeforeLabels(t *testing.T) {
	for _, test := range []struct {
		name   string
		fields map[string]any
		want   int
	}{
		{"landscape", map[string]any{"width": 1920, "height": 1080, "quality_desc": "4K"}, 1080},
		{"top-level precedes nested", map[string]any{"vwidth": 720, "vheight": 1280, "video_meta": map[string]any{"vwidth": 1080, "vheight": 1920, "definition": "2160p"}}, 720},
		{"nested width height", map[string]any{"video_meta": map[string]any{"width": 1080, "height": 1920}}, 1080},
		{"invalid top-level pair", map[string]any{"vwidth": -1, "vheight": 1920, "video_meta": map[string]any{"vwidth": 720, "vheight": 1280}}, 720},
		{"label-only legacy rendition", map[string]any{"definition": "720p"}, 720},
		{"unconfirmed quality", map[string]any{}, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			row := map[string]any{"codec_type": "h264", "encrypt": false, "main_url": "https://media.example.test/quality.mp4"}
			for key, value := range test.fields {
				row[key] = value
			}
			media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{row}})
			if err != nil || media.Quality != test.want {
				t.Fatal("incorrect rendition quality", media.Quality, err)
			}
		})
	}
}

func TestHongguoMediaInvalidEncryptedRenditionDoesNotHideUsableQuality(t *testing.T) {
	media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{
		map[string]any{"codec_type": "h264", "definition": "1080p", "encrypt": true, "main_url": "https://media.example.test/missing-key.mp4"},
		map[string]any{"codec_type": "hevc", "definition": "720p", "encrypt": false, "main_url": "https://media.example.test/clear.mp4"},
	}})
	if err != nil || media.Quality != 720 || len(media.Variants) != 1 {
		t.Fatal("incomplete high-quality model displaced valid media", err)
	}
}
