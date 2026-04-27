package server

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/chatwoot/chatwoot-media-server/internal/config"
)

func TestResolveAudioSourceRejectsTraversalAndSymlinkEscape(t *testing.T) {
	base := t.TempDir()
	outside := t.TempDir()
	insideFile := filepath.Join(base, "inside.ogg")
	if err := os.WriteFile(insideFile, []byte("ogg"), 0o600); err != nil {
		t.Fatal(err)
	}
	outsideFile := filepath.Join(outside, "escape.ogg")
	if err := os.WriteFile(outsideFile, []byte("ogg"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outsideFile, filepath.Join(base, "escape.ogg")); err != nil {
		t.Fatal(err)
	}

	h := NewHandlers(&config.Config{AudioDir: base}, nil)

	if _, err := h.resolveAudioSource("../escape.ogg"); err == nil {
		t.Fatal("expected traversal source to be rejected")
	}
	if _, err := h.resolveAudioSource(insideFile); err == nil {
		t.Fatal("expected absolute source to be rejected")
	}
	if _, err := h.resolveAudioSource("https://example.com/prompt.ogg"); err == nil {
		t.Fatal("expected URL source to be rejected")
	}
	if _, err := h.resolveAudioSource("prompts\\welcome.ogg"); err == nil {
		t.Fatal("expected backslash source to be rejected")
	}
	if _, err := h.resolveAudioSource("escape.ogg"); err == nil {
		t.Fatal("expected symlink escape to be rejected")
	}
}

func TestResolveAudioSourceAllowsOggFilesInsideAudioDir(t *testing.T) {
	base := t.TempDir()
	if err := os.MkdirAll(filepath.Join(base, "prompts"), 0o700); err != nil {
		t.Fatal(err)
	}
	filePath := filepath.Join(base, "prompts", "welcome.ogg")
	if err := os.WriteFile(filePath, []byte("ogg"), 0o600); err != nil {
		t.Fatal(err)
	}

	h := NewHandlers(&config.Config{AudioDir: base}, nil)
	resolved, err := h.resolveAudioSource("prompts/../prompts/welcome.ogg")
	if err != nil {
		t.Fatalf("expected source to resolve: %v", err)
	}
	if resolved != filePath {
		t.Fatalf("expected %q, got %q", filePath, resolved)
	}
}
