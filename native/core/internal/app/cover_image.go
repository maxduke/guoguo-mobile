package app

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"net/http"
	"net/url"
	"strings"
)

func normalizeDramaCover(drama *Drama) {
	drama.OnlineDate = normalizeDate(drama.OnlineDate)
	drama.Views = normalizeViews(drama.Views)
	if p := bestDramaCover(*drama); p != "" {
		drama.Cover = p
	}
}

func bestDramaCover(dr Drama) string {
	for _, v := range []any{dr.CoverURL, dr.CoverURLSnake, dr.Cover, dr.ImageURL, dr.ImageURLSnake, dr.Image, dr.Img, dr.Pic, dr.Picture, dr.Poster, dr.Thumb, dr.Thumbnail} {
		if p := coverPathFromAny(v); p != "" {
			return p
		}
	}
	return ""
}

func coverPathFromAny(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		s := strings.TrimSpace(x)
		if s == "" {
			return ""
		}
		if strings.HasPrefix(s, "/api/ui/image") {
			if u, err := url.Parse(s); err == nil {
				if raw := strings.TrimSpace(u.Query().Get("url")); raw != "" {
					return raw
				}
			}
		}
		if strings.HasPrefix(s, "//") {
			return "https:" + s
		}
		if u, err := url.Parse(s); err == nil && u.IsAbs() {
			return u.String()
		}
		return strings.TrimLeft(s, "/")
	case map[string]any:
		for _, key := range []string{"url", "src", "path", "cover", "coverUrl", "cover_url", "image", "pic", "poster"} {
			if s := coverPathFromAny(x[key]); s != "" {
				return s
			}
		}
	}
	return ""
}

func buildImageURL(imgPath string) (string, bool) {
	imgPath = strings.TrimSpace(imgPath)
	if strings.HasPrefix(imgPath, "//") {
		imgPath = "https:" + imgPath
	}
	if imgPath == "" {
		return "", false
	}
	if u, err := url.Parse(imgPath); err == nil && u.IsAbs() {
		if !validImageURL(u) {
			return "", false
		}
		return u.String(), true
	}
	imgPath = strings.TrimLeft(imgPath, "/")
	if imgPath == "" || strings.Contains(imgPath, "..") || strings.Contains(imgPath, "://") {
		return "", false
	}
	if strings.HasPrefix(imgPath, "upload_01/") || strings.HasPrefix(imgPath, "upload/") {
		return "https://pic.zdmhyg.cn/" + imgPath, true
	}
	return "https://zzzznnn.lkkwip.cn/" + imgPath, true
}

func allowedImageHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	switch host {
	case "zzzznnn.lkkwip.cn", "pic.zdmhyg.cn", "huangguoai.com", "www.huangguoai.com", "huangguo.video", "cdn.huangguo.video", "tideember.cc", "xqjurgek.top", "d3rorc0p4i1kyz.cloudfront.net":
		return true
	default:
		return isHuangguoImageHost(host) || isHongguoImageHost(host)
	}
}

func imageReferer(remoteURL string) string {
	if u, err := url.Parse(remoteURL); err == nil {
		if isHuangguoImageHost(u.Hostname()) {
			return huangguoAIBaseURL + "/"
		}
		switch u.Hostname() {
		case "pic.zdmhyg.cn", "huangguoai.com", "www.huangguoai.com":
			return huangguoAIBaseURL + "/"
		case "huangguo.video", "cdn.huangguo.video":
			return "https://huangguo.video/"
		case "tideember.cc", "xqjurgek.top":
			return u.Scheme + "://" + u.Host + "/home"
		case "d3rorc0p4i1kyz.cloudfront.net":
			return huangdouBaseURL + "/home"
		}
		if isHongguoImageHost(u.Hostname()) {
			return hongguoBaseURL + "/"
		}
	}
	return "https://d2pypzndaqisk.cloudfront.net/"
}

func decodeImageBytes(buf []byte, remoteURL string) []byte {
	if isKnownImage(buf) {
		return buf
	}
	if decoded := decryptHuangguoImage(buf); isKnownImage(decoded) || isHEICImage(decoded) {
		return trimHuangguoImagePadding(decoded)
	}
	copyBuf := append([]byte(nil), buf...)
	decryptImageHeader(copyBuf)
	if isKnownImage(copyBuf) {
		return copyBuf
	}
	return buf
}

func decryptHuangguoImage(buf []byte) []byte {
	if bytes.HasPrefix(buf, []byte("Salted__")) {
		if len(buf) <= 16 {
			return nil
		}
		buf = buf[16:]
	}
	if len(buf) == 0 || len(buf) > maxCoverBytes {
		return nil
	}
	block, err := aes.NewCipher([]byte("f5d965df75336270"))
	if err != nil {
		return nil
	}
	out := make([]byte, (len(buf)+aes.BlockSize-1)/aes.BlockSize*aes.BlockSize)
	copy(out, buf)
	cipher.NewCBCDecrypter(block, []byte("97b60394abc2fbe1")).CryptBlocks(out, out)
	return out[:len(buf)]
}

func trimHuangguoImagePadding(buf []byte) []byte {
	if len(buf) > 0 {
		pad := int(buf[len(buf)-1])
		if pad > 0 && pad <= aes.BlockSize && pad <= len(buf) {
			valid := true
			for _, b := range buf[len(buf)-pad:] {
				if int(b) != pad {
					valid = false
					break
				}
			}
			if valid {
				buf = buf[:len(buf)-pad]
			}
		}
	}
	return buf
}

func decryptImageHeader(buf []byte) {
	key := []byte("2019ysapp7527")
	limit := len(buf)
	if limit > 100 {
		limit = 100
	}
	for i := 0; i < limit; i++ {
		buf[i] ^= key[i%len(key)]
	}
}

func imageContentType(buf []byte) string {
	if len(buf) >= 12 && buf[0] == 'R' && buf[1] == 'I' && buf[2] == 'F' && buf[3] == 'F' && buf[8] == 'W' && buf[9] == 'E' && buf[10] == 'B' && buf[11] == 'P' {
		return "image/webp"
	}
	if len(buf) >= 8 && buf[0] == 0x89 && buf[1] == 0x50 && buf[2] == 0x4e && buf[3] == 0x47 {
		return "image/png"
	}
	if len(buf) >= 3 && buf[0] == 0x47 && buf[1] == 0x49 && buf[2] == 0x46 {
		return "image/gif"
	}
	if len(buf) >= 2 && buf[0] == 0xff && buf[1] == 0xd8 {
		return "image/jpeg"
	}
	return http.DetectContentType(buf)
}

func isKnownImage(buf []byte) bool {
	return imageContentType(buf) == "image/jpeg" || imageContentType(buf) == "image/png" || imageContentType(buf) == "image/gif" || imageContentType(buf) == "image/webp"
}
