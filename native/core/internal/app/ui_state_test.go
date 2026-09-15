package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCorruptTaskStateIsPreservedAndPreventsStartup(t *testing.T) {
	for _, body := range []string{`{"tasks":[`, `null`, `[]`} {
		t.Run(body, func(t *testing.T) {
			cfg := defaultConfig()
			cfg.dataDir = t.TempDir()
			cfg.OutputDir = t.TempDir()
			path := filepath.Join(cfg.dataDir, "ui-state.json")
			if err := os.WriteFile(path, []byte(body), 0600); err != nil {
				t.Fatal(err)
			}
			app := NewUIApp(NewDownloader(cfg))
			if err := app.saveStateLocked(); err == nil {
				t.Fatal("corrupt state overwritten")
			}
			if err := app.ListenAndServe("127.0.0.1:0"); err == nil || !strings.Contains(err.Error(), "原文件未修改") {
				t.Fatalf("startup did not reject corrupt state: %v", err)
			}
			got, err := os.ReadFile(path)
			if err != nil || string(got) != body {
				t.Fatalf("original state was modified: %q %v", got, err)
			}
		})
	}
}

func TestMissingTaskStateCanBeCreated(t *testing.T) {
	app := &UIApp{statePath: filepath.Join(t.TempDir(), "ui-state.json")}
	app.loadState()
	if app.stateLoadErr != nil {
		t.Fatal(app.stateLoadErr)
	}
	if err := app.saveStateLocked(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.ReadFile(app.statePath); err != nil {
		t.Fatal(err)
	}
}

func TestTaskStateWriteFailurePreventsServerStartup(t *testing.T) {
	cfg := defaultConfig()
	cfg.dataDir = t.TempDir()
	cfg.OutputDir = t.TempDir()
	app := NewUIApp(NewDownloader(cfg))
	blocker := filepath.Join(cfg.dataDir, "not-a-directory")
	if err := os.WriteFile(blocker, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	app.statePath = filepath.Join(blocker, "ui-state.json")
	// A failed storage preflight must be reported before attempting to bind.
	err := app.ListenAndServe("invalid-listen-address")
	if err == nil || !strings.Contains(err.Error(), "无法保存任务状态") {
		t.Fatalf("storage failure was ignored: %v", err)
	}
	body, err := os.ReadFile(blocker)
	if err != nil || string(body) != "keep" {
		t.Fatalf("existing file changed: %q %v", body, err)
	}
}
