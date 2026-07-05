package media

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pion/rtp"
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

func TestRecorderFinalizeWithCustomerOnlyRTPCreatesRecording(t *testing.T) {
	dir := t.TempDir()
	recorder, err := NewRecorder("sess_customer_only", dir)
	if err != nil {
		t.Fatalf("NewRecorder returned error: %v", err)
	}

	for i := uint16(1); i <= 3; i++ {
		err := recorder.WriteCustomerRTP(&rtp.Packet{
			Header: rtp.Header{
				Version:        2,
				PayloadType:    111,
				SequenceNumber: i,
				Timestamp:      uint32(i) * 960,
				SSRC:           1234,
			},
			Payload: []byte{0xf8, 0xff, 0xfe},
		})
		if err != nil {
			t.Fatalf("WriteCustomerRTP returned error: %v", err)
		}
	}

	if err := recorder.Finalize(); err != nil {
		t.Fatalf("Finalize returned error: %v", err)
	}

	combined := filepath.Join(dir, "sess_customer_only.ogg")
	info, err := os.Stat(combined)
	if err != nil {
		t.Fatalf("expected combined recording, stat err=%v", err)
	}
	if info.Size() == 0 {
		t.Fatalf("expected non-empty combined recording")
	}
}
