package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/chatwoot/chatwoot-media-server/internal/config"
	"github.com/chatwoot/chatwoot-media-server/internal/media"
	"github.com/pion/rtp"
	"golang.org/x/sys/unix"
)

func recordingRouter(t *testing.T) (http.Handler, string) {
	t.Helper()
	dir := t.TempDir()
	recorder, err := media.NewRecorder("session_test", dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := recorder.SetRecordingIdentity("call_test", "42"); err != nil {
		t.Fatal(err)
	}
	source := recorder.NewCaptureSource("customer", "meta", "audio/opus", 48000)
	if err := recorder.CaptureRTP(source, &rtp.Packet{Header: rtp.Header{Version: 2, SSRC: 1, Timestamp: 960, SequenceNumber: 1}, Payload: []byte{0xf8, 0xff, 0xfe}}); err != nil {
		t.Fatal(err)
	}
	if err := recorder.Finalize(); err != nil {
		t.Fatal(err)
	}
	// A nil manager proves the disk API works after eviction/restart.
	return NewRouter(&config.Config{RecordingsDir: dir, AuthToken: "synthetic-token"}, nil).Build(), dir
}

func recordingRequest(router http.Handler, path string, auth bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodGet, path, nil)
	if auth {
		r.Header.Set("Authorization", "Bearer synthetic-token")
	}
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	return w
}

func TestRecordingBundleRoutesAuthenticateAndScopeAfterEviction(t *testing.T) {
	router, _ := recordingRouter(t)
	paths := []string{"/sessions/session_test/recording-manifest?account_id=42&call_id=call_test", "/sessions/session_test/recording-artifacts/track_000001?account_id=42&call_id=call_test"}
	for _, path := range paths {
		if w := recordingRequest(router, path, false); w.Code != http.StatusUnauthorized {
			t.Fatalf("unauthenticated route status=%d", w.Code)
		}
		if w := recordingRequest(router, path, true); w.Code != http.StatusOK {
			t.Fatalf("disk route status=%d", w.Code)
		}
	}
	for _, query := range []string{"account_id=99&call_id=call_test", "account_id=42&call_id=other_call", "account_id=42"} {
		if w := recordingRequest(router, "/sessions/session_test/recording-manifest?"+query, true); w.Code != http.StatusNotFound {
			t.Fatal("foreign manifest scope accepted")
		}
	}
}

func TestRecordingBundleRejectsUnlistedTraversalAndSymlinks(t *testing.T) {
	router, dir := recordingRouter(t)
	base := "/sessions/session_test/recording-artifacts/"
	for _, id := range []string{"track_999999", "manifest.json", "%2E%2E%2Foutside", "track_000001%5Coutside", "https:%2F%2Fexample.test"} {
		w := recordingRequest(router, base+id+"?account_id=42&call_id=call_test", true)
		if w.Code == http.StatusOK {
			t.Fatalf("unsafe id accepted: %s", id)
		}
	}
	artifact := filepath.Join(dir, "session_test_recording_v1", "track_000001.rtp")
	outside := filepath.Join(t.TempDir(), "outside.rtp")
	if err := os.WriteFile(outside, []byte("foreign"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(artifact); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, artifact); err != nil {
		t.Fatal(err)
	}
	if w := recordingRequest(router, base+"track_000001?account_id=42&call_id=call_test", true); w.Code != http.StatusNotFound {
		t.Fatal("symlink file accepted")
	}
	if err := os.Remove(artifact); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(artifact, 0o600); err != nil {
		t.Fatal(err)
	}
	if w := recordingRequest(router, base+"track_000001?account_id=42&call_id=call_test", true); w.Code != http.StatusNotFound {
		t.Fatal("FIFO accepted")
	}
}

func TestRecordingBundleRejectsSymlinkDirectoryAndModifiedArtifact(t *testing.T) {
	router, dir := recordingRouter(t)
	artifact := filepath.Join(dir, "session_test_recording_v1", "track_000001.rtp")
	if err := os.WriteFile(artifact, []byte("modified"), 0o600); err != nil {
		t.Fatal(err)
	}
	if w := recordingRequest(router, "/sessions/session_test/recording-artifacts/track_000001?account_id=42&call_id=call_test", true); w.Code != http.StatusNotFound {
		t.Fatal("modified capture accepted")
	}
	bundle := filepath.Join(dir, "session_test_recording_v1")
	moved := filepath.Join(dir, "moved_bundle")
	if err := os.Rename(bundle, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(moved, bundle); err != nil {
		t.Fatal(err)
	}
	if w := recordingRequest(router, "/sessions/session_test/recording-manifest?account_id=42&call_id=call_test", true); w.Code != http.StatusNotFound {
		t.Fatal("symlink directory accepted")
	}
}

func TestRecordingBundlePartialCannotServeArtifact(t *testing.T) {
	router, dir := recordingRouter(t)
	manifest := filepath.Join(dir, "session_test_recording_v1", "manifest.json")
	data, err := os.ReadFile(manifest)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i+len(`"state":"final"`) <= len(data); i++ {
		if string(data[i:i+len(`"state":"final"`)]) == `"state":"final"` {
			data = append(append(append([]byte{}, data[:i]...), []byte(`"state":"partial"`)...), data[i+len(`"state":"final"`):]...)
			break
		}
	}
	if err := os.WriteFile(manifest, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if w := recordingRequest(router, "/sessions/session_test/recording-artifacts/track_000001?account_id=42&call_id=call_test", true); w.Code != http.StatusConflict {
		t.Fatal("partial capture accepted")
	}
}
