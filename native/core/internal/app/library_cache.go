package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type libraryCache struct {
	Dramas     []Drama                         `json:"dramas"`
	LoadedAt   time.Time                       `json:"loadedAt"`
	LastError  string                          `json:"lastError,omitempty"`
	HongguoApp *hongguoCatalogState            `json:"hongguoApp,omitempty"`
	Huangguo   map[string]mobileHuangguoCursor `json:"huangguo,omitempty"`
}

func libraryCachePath(outputDir string) string {
	return filepath.Join(outputDir, "library.json")
}

func readLibraryCache(outputDir string) (libraryCache, error) {
	var cache libraryCache
	path := libraryCachePath(outputDir)
	body, err := os.ReadFile(path)
	if err != nil {
		return cache, err
	}
	if err := json.Unmarshal(body, &cache); err != nil {
		return cache, fmt.Errorf("本地剧库缓存损坏 %s: %w", path, err)
	}
	return cache, nil
}

func writeLibraryCache(outputDir string, cache libraryCache) error {
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return err
	}
	file, err := os.CreateTemp(outputDir, ".library-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	encoder := json.NewEncoder(file)
	if err := encoder.Encode(cache); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), libraryCachePath(outputDir))
}

func (d *Downloader) RefreshDramas(ctx context.Context, source string) ([]Drama, error) {
	cached, _ := readLibraryCache(d.cfg.dataDirectory())
	d.restoreHongguoCatalog(cached.HongguoApp)
	ctx = withKnownHongguoDramas(ctx, cached.Dramas)
	fresh, loadErr := d.fetchAllDramas(ctx, source)
	merged := mergeSourceDramas(cached.Dramas, fresh, loadErr, source)
	if len(fresh) == 0 && len(merged) == 0 {
		return nil, loadErr
	}
	cache := libraryCache{Dramas: merged, LoadedAt: time.Now(), HongguoApp: d.hongguoCatalogSnapshot()}
	if len(fresh) == 0 {
		cache.LoadedAt = cached.LoadedAt
	}
	if loadErr != nil {
		cache.LastError = publicError(loadErr).Error()
	}
	if err := writeLibraryCache(d.cfg.dataDirectory(), cache); err != nil {
		loadErr = errors.Join(loadErr, fmt.Errorf("剧库缓存保存失败: %w", err))
	}
	fmt.Printf("本地剧库：%d 部，本次新增 %d 部\n", len(merged), len(merged)-len(cached.Dramas))
	return merged, loadErr
}
