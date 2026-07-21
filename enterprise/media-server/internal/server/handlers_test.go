package server

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/chatwoot/chatwoot-media-server/internal/config"
	"github.com/chatwoot/chatwoot-media-server/internal/session"
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

func TestBuildRuntimeAgentContractReturnsScopedOneTimeStreamShape(t *testing.T) {
	h := NewHandlers(&config.Config{}, nil)
	req := RuntimeAgentRequest{CallRef: "whatsapp:wa-call-1", AccountID: "42", ConversationID: "7", InboxID: "9"}

	resp, err := h.buildRuntimeAgentContract("media-session-1", req, "media.internal")
	if err != nil {
		t.Fatalf("expected runtime agent contract: %v", err)
	}

	if !strings.HasPrefix(resp.RuntimeSessionID, "rt_media-session-1_") {
		t.Fatalf("unexpected runtime session id %q", resp.RuntimeSessionID)
	}
	if resp.StreamURL != "ws://media.internal/sessions/media-session-1/runtime-stream" {
		t.Fatalf("unexpected stream url %q", resp.StreamURL)
	}
	if resp.StreamToken == "" {
		t.Fatal("expected separate stream token")
	}
	if strings.Contains(resp.StreamURL, resp.StreamToken) {
		t.Fatal("stream url leaked capability token")
	}
	if strings.Contains(resp.StreamURL, "whatsapp:wa-call-1") {
		t.Fatalf("stream url leaked call ref: %q", resp.StreamURL)
	}
	if resp.Codec != "pcm_s16le" || resp.InputSampleRate != 16000 || resp.OutputSampleRate != 8000 {
		t.Fatalf("unexpected audio contract: %#v", resp)
	}
	if resp.ExpiresAt.IsZero() {
		t.Fatal("expected non-zero expiration")
	}
}

func TestRuntimeAgentRequestMatchesSessionScope(t *testing.T) {
	info := session.Info{CallID: "wa-call-1", AccountID: "42"}
	tests := []struct {
		name string
		req  RuntimeAgentRequest
		want bool
	}{
		{name: "canonical WhatsApp call ref", req: RuntimeAgentRequest{CallRef: "whatsapp:wa-call-1", AccountID: "42"}, want: true},
		{name: "raw provider call ref", req: RuntimeAgentRequest{CallRef: "wa-call-1", AccountID: "42"}, want: true},
		{name: "wrong account", req: RuntimeAgentRequest{CallRef: "whatsapp:wa-call-1", AccountID: "43"}, want: false},
		{name: "wrong call", req: RuntimeAgentRequest{CallRef: "whatsapp:wa-call-2", AccountID: "42"}, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := runtimeAgentRequestMatchesSession(tt.req, info); got != tt.want {
				t.Fatalf("runtime agent scope match = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestRuntimeStreamGrantIsScopedOneTimeAndExpires(t *testing.T) {
	h := NewHandlers(&config.Config{}, nil)
	resp, err := h.buildRuntimeAgentContract("media-session-1", RuntimeAgentRequest{CallRef: "whatsapp:wa-call-1", AccountID: "42"}, "media.internal")
	if err != nil {
		t.Fatalf("expected runtime agent contract: %v", err)
	}
	token := resp.StreamToken

	if _, ok, status, _ := h.consumeRuntimeStreamGrant("wrong-session", token); ok || status != http.StatusUnauthorized {
		t.Fatalf("expected wrong-session token to be rejected with 401, ok=%v status=%d", ok, status)
	}
	grant, ok, status, message := h.consumeRuntimeStreamGrant("media-session-1", token)
	if !ok || status != http.StatusOK || message != "" {
		t.Fatalf("expected token to be consumed once, ok=%v status=%d message=%q", ok, status, message)
	}
	if grant.RuntimeSessionID != resp.RuntimeSessionID {
		t.Fatalf("expected runtime session id %q, got %q", resp.RuntimeSessionID, grant.RuntimeSessionID)
	}
	if _, ok, status, _ := h.consumeRuntimeStreamGrant("media-session-1", token); ok || status != http.StatusConflict {
		t.Fatalf("expected duplicate token use to be rejected with 409, ok=%v status=%d", ok, status)
	}

	expiredToken := "expired-runtime-token"
	h.storeRuntimeStreamGrant(runtimeStreamGrant{SessionID: "media-session-1", RuntimeSessionID: "rt-expired", Token: expiredToken, ExpiresAt: time.Now().UTC().Add(-time.Second)})
	if _, ok, status, _ := h.consumeRuntimeStreamGrant("media-session-1", expiredToken); ok || status != http.StatusGone {
		t.Fatalf("expected expired token to be rejected with 410, ok=%v status=%d", ok, status)
	}
}

func TestRuntimeStreamGrantCleanupRemovesAbandonedExpiredTokens(t *testing.T) {
	h := NewHandlers(&config.Config{}, nil)
	token := "abandoned-expired-runtime-token"
	h.runtimeStreamGrants.Store(token, runtimeStreamGrant{
		SessionID: "media-session-1",
		Token:     token,
		ExpiresAt: time.Now().UTC().Add(-2 * time.Minute),
	})

	h.cleanupRuntimeStreamGrants(time.Now().UTC())
	if _, ok := h.runtimeStreamGrants.Load(token); ok {
		t.Fatal("expected abandoned expired runtime token to be removed")
	}
}

func TestRuntimeStreamTokenAcceptsOnlyBearer(t *testing.T) {
	bearer, _ := http.NewRequest(http.MethodGet, "http://media/runtime-stream", nil)
	bearer.Header.Set("Authorization", "Bearer header-token")
	if token := runtimeStreamToken(bearer); token != "header-token" {
		t.Fatalf("unexpected bearer token %q", token)
	}

	legacy, _ := http.NewRequest(http.MethodGet, "http://media/runtime-stream?token=query-token", nil)
	if token := runtimeStreamToken(legacy); token != "" {
		t.Fatalf("expected query token to be rejected, got %q", token)
	}
}
