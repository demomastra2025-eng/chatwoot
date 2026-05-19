package media

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRecorderFinalizeWithNoRTPPacketsDoesNotCreateHeaderOnlyRecording(t *testing.T) {
	dir := t.TempDir()
	recorder, err := NewRecorder("sess_no_packets", dir)
	if err != nil {
		t.Fatalf("NewRecorder returned error: %v", err)
	}

	started := time.Now()
	if err := recorder.Finalize(); err != nil {
		t.Fatalf("Finalize returned error: %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("Finalize took too long for empty RTP streams: %s", elapsed)
	}

	combined := filepath.Join(dir, "sess_no_packets.ogg")
	if _, err := os.Stat(combined); !os.IsNotExist(err) {
		t.Fatalf("expected no combined recording for empty RTP streams, stat err=%v", err)
	}
}
