package app

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func readDiagnosticEvents(t *testing.T, path string) []diagnosticEvent {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var events []diagnosticEvent
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var event diagnosticEvent
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil || event.Time.IsZero() || event.Event == "" {
			t.Fatal("invalid diagnostic record", err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return events
}

func TestDiagnosticLogConcurrentWritesAndRedaction(t *testing.T) {
	log := newDiagnosticLog(t.TempDir())
	d := &Downloader{cfg: Config{Token: "fixture-token", AESKeyHex: "fixture-media-key"}, diagnostics: log}
	var group sync.WaitGroup
	for index := 0; index < 50; index++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			d.recordDiagnostic(diagnosticEvent{Event: "fixture.failed", Episode: index + 1, Message: "fixture-token fixture-media-key https://user:fixture-password@media.invalid/video?signature=fixture-signature#fixture-fragment"})
		}(index)
	}
	group.Wait()
	events := readDiagnosticEvents(t, log.path)
	seen := make(map[int]bool)
	for _, event := range events {
		seen[event.Episode] = true
		for _, secret := range []string{"fixture-token", "fixture-media-key", "fixture-password", "fixture-signature", "fixture-fragment"} {
			if strings.Contains(event.Message, secret) {
				t.Fatal("diagnostic log exposed a credential or signed URL parameter")
			}
		}
	}
	if len(events) != 50 || len(seen) != 50 {
		t.Fatal("concurrent diagnostic events were lost or interleaved")
	}
	info, err := os.Stat(log.path)
	if err != nil || runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		t.Fatal("new diagnostic file was not private", err)
	}
}

func TestDiagnosticLogRotationBoundsFiles(t *testing.T) {
	log := newDiagnosticLog(t.TempDir())
	log.limit = 512
	for index := 0; index < 30; index++ {
		if err := log.write(diagnosticEvent{Event: "fixture.rotate", Episode: index, Message: strings.Repeat("x", 100)}); err != nil {
			t.Fatal(err)
		}
	}
	files, err := os.ReadDir(filepath.Dir(log.path))
	if err != nil || len(files) != diagnosticLogBackups+1 {
		t.Fatal("diagnostic rotation exceeded its file bound", err)
	}
	for _, file := range files {
		info, err := file.Info()
		if err != nil || info.Size() > log.limit || len(readDiagnosticEvents(t, filepath.Join(filepath.Dir(log.path), file.Name()))) == 0 {
			t.Fatal("rotation kept an oversized or invalid file", err)
		}
	}
	current := readDiagnosticEvents(t, log.path)
	if current[len(current)-1].Episode != 29 {
		t.Fatal("rotation discarded the latest event")
	}
	if err := newDiagnosticLog(filepath.Dir(filepath.Dir(log.path))).write(diagnosticEvent{Event: "fixture.restart", Message: "restart"}); err != nil {
		t.Fatal("reopening diagnostics failed", err)
	}
}

func TestDiagnosticWriteFailureDoesNotReplacePlaybackError(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "logs"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	log := newDiagnosticLog(directory)
	if err := log.write(diagnosticEvent{Event: "fixture.failed", Message: "failure"}); err == nil {
		t.Fatal("unwritable diagnostics unexpectedly succeeded")
	}
	d := &Downloader{diagnostics: log}
	d.recordDiagnostic(diagnosticEvent{Event: "playback.failed", Message: "unexpected EOF"})
	data, err := os.ReadFile(filepath.Join(directory, "logs"))
	if err != nil || string(data) != "keep" {
		t.Fatal("diagnostics replaced an existing file", err)
	}
}
