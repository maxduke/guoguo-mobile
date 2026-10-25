package app

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
)

const guanguoH5Referer = "https://h5.drama.9ddm.com/"

func (d *Downloader) guanguoH5Detail(ctx context.Context, id string, episode int) (map[string]any, error) {
	if !webProviderNumericID.MatchString(id) || episode < 1 || episode > 10000 {
		return nil, errors.New("观果作品或分集无效，请刷新详情")
	}
	d.guanguoOnce.Do(func() { d.guanguoDeviceID = randomHex(16) })
	query := url.Values{"deviceId": {d.guanguoDeviceID}, "oneId": {id}, "os_type": {"2"}, "playOrder": {strconv.Itoa(episode)}}
	response, err := d.duanjuJSON(ctx, duanjuRequest{Source: sourceGuanguo,
		Address: d.duanjuBaseURL(sourceGuanguo) + "/drama/play/h5/detail?" + query.Encode(), Referer: guanguoH5Referer})
	if err != nil {
		return nil, err
	}
	data := duanjuFindMap(response, "data")
	if duanjuFindInt(response, "code") != 200 || len(data) == 0 {
		return nil, errors.New("观果详情接口返回空数据，请稍后重试")
	}
	if duanjuFindString(data, "oneId") != id {
		return nil, errors.New("观果返回了其他作品，请刷新详情")
	}
	total := duanjuFindInt(data, "episodeCount")
	if duanjuFindString(data, "title") == "" || total < episode || total > 10000 {
		return nil, errors.New("观果分集资料不完整，请刷新详情")
	}
	return data, nil
}

func (d *Downloader) fetchGuanguoDetail(ctx context.Context, id string) (Drama, []Chapter, error) {
	data, err := d.guanguoH5Detail(ctx, id, 1)
	if err != nil {
		return Drama{}, nil, err
	}
	drama := guanguoDramaFromNode(data, d.duanjuBaseURL(sourceGuanguo))
	drama.Tags = duanjuStringList(data["subjectTags"])
	drama.Category = duanjuCSV(drama.Tags)
	count := duanjuFindInt(data, "episodeCount")
	chapters := make([]Chapter, 0, count)
	for number := 1; number <= count; number++ {
		// Resolve only the selected episode. Persist stable IDs, never expiring
		// playback envelopes or another episode's URL in the chapter cache.
		chapters = append(chapters, duanjuChapter(sourceGuanguo, id, number, "", "", guanguoH5Referer, guanguoH5Referer))
	}
	return drama, chapters, nil
}

func decodeGuanguoMedia(data map[string]any) ([]providerMedia, error) {
	decode := func(value string) ([]byte, error) {
		if len(value) > 256*1024 {
			return nil, errors.New("观果播放资料过大")
		}
		decoded, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			decoded, err = base64.RawStdEncoding.DecodeString(value)
		}
		return decoded, err
	}
	key, err := decode(duanjuFindString(data, "h5PlayKey"))
	if err != nil {
		return nil, errors.New("观果播放密钥无效")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, errors.New("观果播放密钥无效")
	}
	envelope, err := decode(duanjuFindString(data, "h5PlayUrl"))
	if err != nil || len(envelope) <= aes.BlockSize || (len(envelope)-aes.BlockSize)%aes.BlockSize != 0 {
		return nil, errors.New("观果播放资料无效")
	}
	plain := make([]byte, len(envelope)-aes.BlockSize)
	cipher.NewCBCDecrypter(block, envelope[:aes.BlockSize]).CryptBlocks(plain, envelope[aes.BlockSize:])
	plain, err = pkcs7Unpad(plain, aes.BlockSize)
	var addresses map[string]string
	if err != nil || json.Unmarshal(plain, &addresses) != nil {
		return nil, errors.New("观果播放资料无法解码")
	}
	var media []providerMedia
	seen := map[string]bool{}
	// The H5 names rank alternatives but do not declare pixel dimensions.
	// Keep that order without inventing a 1080p/720p label for the UI.
	for _, name := range []string{"super", "high", "normal"} {
		address := strings.TrimSpace(addresses[name])
		parsed, parseErr := url.Parse(address)
		if parseErr != nil || parsed.User != nil || !isProviderHTTPMediaURL(address) || !duanjuLooksLikeMedia(address) || seen[address] {
			continue
		}
		seen[address] = true
		media = append(media, providerMedia{URL: address, Referer: guanguoH5Referer})
	}
	if len(media) == 0 {
		return nil, errors.New("观果未返回可播放分集")
	}
	return media, nil
}

func (d *Downloader) resolveGuanguoMedia(ctx context.Context, task Task) (providerMedia, error) {
	_, id, _ := splitProviderDramaID(task.DramaID)
	ordinal := strings.TrimPrefix(task.Chapter.ID, providerChapterID(sourceGuanguo, id, ""))
	number, err := strconv.Atoi(ordinal)
	if err != nil || task.Chapter.ID != providerChapterID(sourceGuanguo, id, strconv.Itoa(number)) || task.Chapter.EpisodeString(0) != ordinal {
		return providerMedia{}, errors.New("观果分集身份不一致，请刷新详情")
	}
	data, err := d.guanguoH5Detail(ctx, id, number)
	if err != nil {
		return providerMedia{}, err
	}
	options, err := decodeGuanguoMedia(data)
	if err != nil {
		return providerMedia{}, err
	}
	media, err := d.prepareWebProviderMedia(ctx, options[0], duanjuSourceName(sourceGuanguo))
	media.Variants = options[1:]
	return media, err
}
