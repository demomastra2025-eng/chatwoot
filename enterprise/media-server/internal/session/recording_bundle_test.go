package session

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/chatwoot/chatwoot-media-server/internal/callback"
	"github.com/chatwoot/chatwoot-media-server/internal/media"
	"github.com/pion/rtp"
)

func TestRecordingReadySignalsFinalBundleWithoutCombinedAudio(t *testing.T) {
	ready := make(chan callback.RecordingReadyPayload, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/callbacks/media_server/recording_ready" {
			var body callback.RecordingReadyPayload
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			ready <- body
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	recorder, err := media.NewRecorder("session_test", t.TempDir())
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
	digest, ok := recorder.RecordingBundleDigest()
	if !ok {
		t.Fatal("bundle not final")
	}
	s := &Session{ID: "session_test", CallID: "call_test", AccountID: "42", Recorder: recorder, railsClient: callback.NewRailsClient(server.URL, "synthetic-token", time.Second)}
	s.sendTerminationCallbacks("synthetic_test")
	select {
	case body := <-ready:
		if body.RecordingManifestVersion != 1 || body.RecordingManifestSHA256 != digest || body.AccountID != "42" || body.CallID != "call_test" {
			t.Fatalf("bad ready signal: %#v", body)
		}
	case <-time.After(time.Second):
		t.Fatal("final bundle did not trigger ready without combined")
	}
}

func TestRecordingReadyRetriesSameDigestWithBoundedAttempts(t *testing.T) {
	for _, succeeds := range []bool{true, false} {
		t.Run(map[bool]string{true: "last_attempt_succeeds", false: "all_attempts_fail"}[succeeds], func(t *testing.T) {
			var count atomic.Int32
			payloads := make(chan callback.RecordingReadyPayload, recordingReadyAttempts)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body callback.RecordingReadyPayload
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				payloads <- body
				if count.Add(1) == recordingReadyAttempts && succeeds {
					w.WriteHeader(http.StatusOK)
				} else {
					w.WriteHeader(http.StatusServiceUnavailable)
				}
			}))
			defer server.Close()
			s := &Session{railsClient: callback.NewRailsClient(server.URL, "synthetic-token", time.Second)}
			want := callback.RecordingReadyPayload{SessionID: "session_test", CallID: "call_test", AccountID: "42", RecordingManifestVersion: 1, RecordingManifestSHA256: strings.Repeat("a", 64)}
			err := s.notifyRecordingReady(context.Background(), want)
			if (err == nil) != succeeds || count.Load() != recordingReadyAttempts {
				t.Fatalf("unbounded or incorrect retry: count=%d err=%v", count.Load(), err)
			}
			for i := 0; i < recordingReadyAttempts; i++ {
				if body := <-payloads; body != want {
					t.Fatalf("retry changed final payload: %#v", body)
				}
			}
		})
	}
}

func TestRecordingReadyRetryHonorsCancellationAndDeadline(t *testing.T) {
	var count atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count.Add(1)
		cancel()
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	s := &Session{railsClient: callback.NewRailsClient(server.URL, "synthetic-token", time.Second)}
	payload := callback.RecordingReadyPayload{RecordingManifestVersion: 1}
	started := time.Now()
	if err := s.notifyRecordingReady(ctx, payload); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation ignored: %v", err)
	}
	if count.Load() != 1 || time.Since(started) >= recordingReadyRetryDelay {
		t.Fatal("cancellation waited for retry")
	}

	blocked := make(chan struct{})
	release := make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(blocked)
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer slow.Close()
	defer close(release)
	s.railsClient = callback.NewRailsClient(slow.URL, "synthetic-token", time.Second)
	deadline, stop := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer stop()
	started = time.Now()
	if err := s.notifyRecordingReady(deadline, payload); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline ignored: %v", err)
	}
	if time.Since(started) > 500*time.Millisecond {
		t.Fatal("total delivery wait exceeded parent deadline")
	}
}

func TestLegacyRecordingReadyDoesNotGainRetries(t *testing.T) {
	var count atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	s := &Session{railsClient: callback.NewRailsClient(server.URL, "synthetic-token", time.Second)}
	if err := s.notifyRecordingReady(context.Background(), callback.RecordingReadyPayload{}); err == nil || count.Load() != 1 {
		t.Fatal("legacy delivery changed")
	}
}

func TestTerminationDoesNotWaitForRecordingCallback(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/callbacks/media_server/recording_ready" {
			close(entered)
			<-release
			defer close(done)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	defer close(release)
	recorder, err := media.NewRecorder("session_background", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := recorder.SetRecordingIdentity("call_test", "42"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := &Session{ID: "session_background", CallID: "call_test", AccountID: "42", Recorder: recorder, Bridge: media.NewBridge("session_background", nil, recorder), cancel: cancel, railsClient: callback.NewRailsClient(server.URL, "synthetic-token", time.Second)}
	returned := make(chan struct{})
	go func() { s.Terminate("synthetic_background"); close(returned) }()
	select {
	case <-returned:
	case <-time.After(time.Second):
		t.Fatal("termination blocked on callback")
	}
	select {
	case <-ctx.Done():
	default:
		t.Fatal("live transports were not canceled before callback")
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("recording callback did not run in background")
	}
	select {
	case <-done:
		t.Fatal("callback was not blocked during termination check")
	default:
	}
}

func TestRecordingPublicationRetryCompletesBeforeReady(t *testing.T) {
	dir := t.TempDir()
	recorder, err := media.NewRecorder("session_retry", dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := recorder.SetRecordingIdentity("call_retry", "42"); err != nil {
		t.Fatal(err)
	}
	source := recorder.NewCaptureSource("customer", "meta", "audio/opus", 48000)
	if err := recorder.CaptureRTP(source, &rtp.Packet{Header: rtp.Header{Version: 2, SSRC: 1, Timestamp: 960, SequenceNumber: 1}, Payload: []byte{0xf8, 0xff, 0xfe}}); err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(dir, "session_retry_recording_v1")
	backup := filepath.Join(dir, "synthetic-retry-backup")
	if err := os.Rename(bundle, backup); err != nil {
		t.Fatal(err)
	}
	if err := recorder.Finalize(); err == nil {
		t.Fatal("expected initial publication failure")
	}
	if _, ready := recorder.RecordingBundleDigest(); ready {
		t.Fatal("partial bundle published ready")
	}
	if err := os.Rename(backup, bundle); err != nil {
		t.Fatal(err)
	}
	ready := make(chan callback.RecordingReadyPayload, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/callbacks/media_server/recording_ready" {
			var body callback.RecordingReadyPayload
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			ready <- body
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	s := &Session{ID: "session_retry", CallID: "call_retry", AccountID: "42", Recorder: recorder, railsClient: callback.NewRailsClient(server.URL, "synthetic-token", time.Second)}
	s.sendTerminationCallbacks("synthetic_retry")
	digest, ok := recorder.RecordingBundleDigest()
	if !ok {
		t.Fatal("publication retry did not finalize bundle")
	}
	if body := <-ready; body.RecordingManifestVersion != 1 || body.RecordingManifestSHA256 != digest {
		t.Fatal("ready was sent without final digest")
	}
}
