package media

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pion/rtp"
)

func testBundle(t *testing.T) (*RecordingBundle, *time.Time) {
	t.Helper()
	origin := time.Unix(1700000000, 0)
	now := origin
	b, err := newRecordingBundle("session_test", t.TempDir(), origin)
	if err != nil {
		t.Fatal(err)
	}
	b.now = func() time.Time { return now }
	if err := b.SetIdentity("call_test", "42"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(b.Cleanup)
	return b, &now
}

func packet(seq uint16, ts, ssrc uint32) *rtp.Packet {
	return &rtp.Packet{Header: rtp.Header{Version: 2, PayloadType: 111, SequenceNumber: seq, Timestamp: ts, SSRC: ssrc}, Payload: []byte{0xf8, 0xff, 0xfe}}
}

func readFrames(t *testing.T, b *RecordingBundle, a RecordingArtifact) ([][]byte, []uint64) {
	t.Helper()
	f, err := os.Open(filepath.Join(b.dir, a.ID+".rtp"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	magic := make([]byte, len(captureMagic))
	_, err = io.ReadFull(f, magic)
	if err != nil || string(magic) != captureMagic {
		t.Fatal("bad capture header")
	}
	var frames [][]byte
	var offsets []uint64
	for {
		header := make([]byte, 12)
		_, err = io.ReadFull(f, header)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		raw := make([]byte, binary.BigEndian.Uint32(header[8:]))
		if _, err = io.ReadFull(f, raw); err != nil {
			t.Fatal(err)
		}
		frames = append(frames, raw)
		offsets = append(offsets, binary.BigEndian.Uint64(header[:8]))
	}
	return frames, offsets
}

func TestCapturePreservesLateSidesAndExactPackets(t *testing.T) {
	b, now := testBundle(t)
	customer := b.NewSource("customer", "meta", "audio/opus", 48000)
	agent := b.NewSource("agent", "browser", "audio/opus", 48000)
	p := packet(10, 100000, 23)
	p.CSRC = []uint32{1, 2}
	if err := p.SetExtension(1, []byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	*now = b.startedAt.Add(400 * time.Millisecond)
	if err := b.Capture(customer, p); err != nil {
		t.Fatal(err)
	}
	*now = b.startedAt.Add(5400 * time.Millisecond)
	if err := b.Capture(agent, p); err != nil {
		t.Fatal(err)
	}
	*now = b.startedAt.Add(5600 * time.Millisecond)
	if err := b.Finalize(nil); err != nil {
		t.Fatal(err)
	}
	if b.manifest.ClockBasis != "recorder_observed_monotonic" || b.manifest.DecodedAlignment != "unknown" {
		t.Fatal("false clock claim")
	}
	if len(b.manifest.Artifacts) != 2 || b.manifest.Artifacts[0].FirstOffsetNS != 400000000 || b.manifest.Artifacts[1].FirstOffsetNS != 5400000000 {
		t.Fatalf("lost late offset: %#v", b.manifest)
	}
	want, _ := p.Marshal()
	for _, a := range b.manifest.Artifacts {
		frames, _ := readFrames(t, b, a)
		if len(frames) != 1 || !bytes.Equal(frames[0], want) {
			t.Fatal("RTP payload/header changed")
		}
	}
}

func TestCaptureWrapResetReorderAndSSRCIsolation(t *testing.T) {
	tests := []struct {
		name      string
		packets   []*rtp.Packet
		tracks    int
		ticks     uint64
		unordered uint64
		wraps     uint64
	}{
		{"timestamp_wrap", []*rtp.Packet{packet(65535, ^uint32(0)-479, 1), packet(0, 480, 1)}, 1, 960, 0, 1},
		{"timestamp_reset", []*rtp.Packet{packet(1, 90000, 1), packet(2, 960, 1)}, 2, 0, 0, 0},
		{"sequence_restart_ambiguous", []*rtp.Packet{packet(100, 90000, 1), packet(1, 960, 1)}, 1, 0, 1, 0},
		{"duplicate_and_reorder", []*rtp.Packet{packet(1, 960, 1), packet(3, 2880, 1), packet(2, 1920, 1), packet(2, 1920, 1)}, 1, 1920, 2, 0},
		{"late_old_ssrc", []*rtp.Packet{packet(1, 960, 1), packet(1, 90000, 2), packet(2, 1920, 1)}, 2, 960, 0, 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			b, now := testBundle(t)
			source := b.NewSource("customer", "meta", "audio/opus", 48000)
			for i, p := range test.packets {
				*now = b.startedAt.Add(time.Duration(i+1) * 20 * time.Millisecond)
				if err := b.Capture(source, p); err != nil {
					t.Fatal(err)
				}
			}
			if err := b.Finalize(nil); err != nil {
				t.Fatal(err)
			}
			if len(b.manifest.Artifacts) != test.tracks {
				t.Fatalf("tracks=%d", len(b.manifest.Artifacts))
			}
			a := b.manifest.Artifacts[0]
			if a.RTPTicks != test.ticks || a.UnorderedPackets != test.unordered || a.TimestampWraps != test.wraps {
				t.Fatalf("bad anchors: %#v", a)
			}
			count := 0
			for _, a := range b.manifest.Artifacts {
				frames, _ := readFrames(t, b, a)
				count += len(frames)
			}
			if count != len(test.packets) {
				t.Fatal("lost duplicate/reordered packet")
			}
		})
	}
}

func TestCaptureGenerationsAndCodecsRemainSeparate(t *testing.T) {
	b, now := testBundle(t)
	sources := []*CaptureSource{b.NewSource("agent", "runtime", "audio/pcmu", 8000), b.NewSource("agent", "browser", "audio/opus", 48000), b.NewSource("agent", "runtime", "audio/pcma", 8000)}
	for i, s := range sources {
		*now = b.startedAt.Add(time.Duration(i+1) * time.Second)
		if err := b.Capture(s, packet(1, 960, 12)); err != nil {
			t.Fatal(err)
		}
	}
	if err := b.Finalize(nil); err != nil {
		t.Fatal(err)
	}
	for i, a := range b.manifest.Artifacts {
		if a.Generation != uint64(i+1) || a.ClockRate != sources[i].clockRate || a.Codec != sources[i].codec {
			t.Fatal("source/codec conflated")
		}
	}
}

func TestCaptureNoPacketsCreatesNoArtifacts(t *testing.T) {
	b, _ := testBundle(t)
	source := b.NewSource("customer", "meta", "audio/opus", 48000)
	if err := b.Capture(source, &rtp.Packet{Header: rtp.Header{Version: 2}}); err != nil {
		t.Fatal(err)
	}
	if err := b.Finalize(nil); err != nil {
		t.Fatal(err)
	}
	if len(b.manifest.Artifacts) != 0 || b.manifest.State != "final" {
		t.Fatal("header-only capture artifact")
	}
}

type shortCaptureWriter struct{}

func (shortCaptureWriter) Write(p []byte) (int, error) { return len(p) / 2, io.ErrShortWrite }

func TestCaptureWriteFailureNeverPublishesFinal(t *testing.T) {
	b, _ := testBundle(t)
	source := b.NewSource("customer", "meta", "audio/opus", 48000)
	if err := b.Capture(source, packet(1, 960, 1)); err != nil {
		t.Fatal(err)
	}
	b.streams[0].writer = shortCaptureWriter{}
	if err := b.Capture(source, packet(2, 1920, 1)); err == nil {
		t.Fatal("expected write failure")
	}
	if err := b.Finalize(nil); err == nil {
		t.Fatal("failed capture became final")
	}
	manifest, _, err := LoadRecordingManifest(filepath.Dir(b.dir), "session_test")
	if err != nil {
		t.Fatal(err)
	}
	if manifest.State != "partial" || manifest.ErrorCode == "" {
		t.Fatal("failure not persisted")
	}
}

func TestCaptureFinalPublicationRetriesAndThenStaysImmutable(t *testing.T) {
	b, now := testBundle(t)
	source := b.NewSource("customer", "meta", "audio/opus", 48000)
	if err := b.Capture(source, packet(1, 960, 1)); err != nil {
		t.Fatal(err)
	}
	original := b.publish
	b.publish = func(data []byte) error {
		if bytes.Contains(data, []byte(`"state":"final"`)) {
			return errors.New("synthetic publish failure")
		}
		return original(data)
	}
	*now = b.startedAt.Add(time.Second)
	if err := b.Finalize(nil); err == nil {
		t.Fatal("expected publish failure")
	}
	if _, ready := b.ReadyDigest(); ready {
		t.Fatal("premature ready signal")
	}
	b.publish = original
	*now = b.startedAt.Add(5 * time.Second)
	if err := b.Finalize(nil); err != nil {
		t.Fatal(err)
	}
	digest, ready := b.ReadyDigest()
	if !ready {
		t.Fatal("not ready after retry")
	}
	if b.manifest.EndOffsetNS != int64(time.Second) {
		t.Fatal("end offset moved during retry")
	}
	*now = b.startedAt.Add(10 * time.Second)
	_ = b.Capture(source, packet(2, 1920, 1))
	if err := b.Finalize(nil); err != nil {
		t.Fatal(err)
	}
	after, _ := b.ReadyDigest()
	if after != digest {
		t.Fatal("final digest changed")
	}
}

func TestCaptureFinalizationHashesLegacySidesAndMissingSideStaysPending(t *testing.T) {
	b, now := testBundle(t)
	source := b.NewSource("customer", "meta", "audio/opus", 48000)
	if err := b.Capture(source, packet(1, 960, 1)); err != nil {
		t.Fatal(err)
	}
	legacy := filepath.Join(t.TempDir(), "synthetic-side.ogg")
	if err := b.Finalize(map[string]string{"customer": legacy}); err == nil {
		t.Fatal("missing required side became final")
	}
	if _, ready := b.ReadyDigest(); ready {
		t.Fatal("missing required side published ready")
	}
	if err := os.WriteFile(legacy, []byte("synthetic legacy bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	*now = b.startedAt.Add(time.Second)
	if err := b.Finalize(map[string]string{"customer": legacy}); err != nil {
		t.Fatal(err)
	}
	manifest, data, err := LoadRecordingManifest(filepath.Dir(b.dir), "session_test")
	if err != nil {
		t.Fatal(err)
	}
	if manifest.State != "final" || len(manifest.Artifacts) != 2 || b.streams[0].file != nil {
		t.Fatal("artifacts were not closed before final")
	}
	for _, a := range manifest.Artifacts {
		filename, err := RecordingArtifactFilename(a)
		if err != nil {
			t.Fatal(err)
		}
		f, err := OpenRecordingBundleFile(filepath.Dir(b.dir), "session_test", filename)
		if err != nil {
			t.Fatal(err)
		}
		digest, size, err := fileDigest(f)
		f.Close()
		if err != nil || digest != a.SHA256 || size != a.ByteSize {
			t.Fatal("final artifact is not hashed")
		}
	}
	before, _ := b.ReadyDigest()
	if err := b.Finalize(map[string]string{"customer": legacy}); err != nil {
		t.Fatal(err)
	}
	after, _ := b.ReadyDigest()
	_, afterData, err := LoadRecordingManifest(filepath.Dir(b.dir), "session_test")
	if err != nil || !bytes.Equal(data, afterData) || before != after {
		t.Fatal("final retry changed digest or manifest")
	}
}

func TestCaptureOversizedPacketCannotPublishFinal(t *testing.T) {
	b, _ := testBundle(t)
	source := b.NewSource("customer", "meta", "audio/opus", 48000)
	p := packet(1, 960, 1)
	p.Payload = make([]byte, 65536)
	if err := b.Capture(source, p); err == nil {
		t.Fatal("oversized packet accepted")
	}
	if err := b.Finalize(nil); err == nil {
		t.Fatal("dropped packet became final")
	}
	if _, ready := b.ReadyDigest(); ready {
		t.Fatal("failed capture published ready")
	}
}

func TestCaptureReservationAndCleanupPreserveOtherBundles(t *testing.T) {
	dir := t.TempDir()
	b, err := newRecordingBundle("session_one", dir, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(dir, "foreign.ogg")
	if err := os.WriteFile(foreign, []byte("foreign"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newRecordingBundle("session_one", dir, time.Now()); err == nil {
		t.Fatal("replaced existing bundle")
	}
	b.Cleanup()
	if data, err := os.ReadFile(foreign); err != nil || string(data) != "foreign" {
		t.Fatal("removed foreign recording")
	}
	if _, err := os.Stat(b.dir); !os.IsNotExist(err) {
		t.Fatal("own bundle not removed")
	}
}

func TestCaptureRejectsForeignSourceAndTruncatedFrame(t *testing.T) {
	b, _ := testBundle(t)
	other, _ := testBundle(t)
	if err := b.Capture(other.NewSource("agent", "runtime", "audio/opus", 48000), packet(1, 960, 1)); err == nil {
		t.Fatal("foreign source accepted")
	}
	if err := validateCapture(bytes.NewReader([]byte(captureMagic+"partial")), 1); err == nil {
		t.Fatal("truncated frame accepted")
	}
}

func TestRecorderRefusesLegacyPathCollisionBeforeOpeningWriters(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session_collision_customer.ogg")
	if err := os.WriteFile(path, []byte("existing recording"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewRecorder("session_collision", dir); err == nil {
		t.Fatal("legacy recording overwritten")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "existing recording" {
		t.Fatal("collision destroyed existing recording")
	}
}

func TestCaptureGapsAndOverlapRemainInObservationClock(t *testing.T) {
	b, now := testBundle(t)
	customer := b.NewSource("customer", "meta", "audio/opus", 48000)
	agent := b.NewSource("agent", "browser", "audio/opus", 48000)
	*now = b.startedAt.Add(time.Second)
	_ = b.Capture(customer, packet(1, 960, 1))
	_ = b.Capture(agent, packet(1, 90000, 2))
	*now = b.startedAt.Add(6 * time.Second)
	_ = b.Capture(customer, packet(2, 240960, 1))
	if err := b.Finalize(nil); err != nil {
		t.Fatal(err)
	}
	c := b.manifest.Artifacts[0]
	a := b.manifest.Artifacts[1]
	if c.FirstOffsetNS != a.FirstOffsetNS || c.LastOffsetNS-c.FirstOffsetNS != int64(5*time.Second) || c.RTPTicks != 240000 {
		t.Fatal("gap or overlap was collapsed")
	}
	frames, offsets := readFrames(t, b, c)
	if len(frames) != 2 || offsets[1]-offsets[0] != uint64(5*time.Second) {
		t.Fatal("gap provenance lost")
	}
}

func syntheticLegacy(t *testing.T, size int) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "synthetic-side.ogg")
	if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, size), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func assertPartialSizeFailure(t *testing.T, b *RecordingBundle, code string) {
	t.Helper()
	if _, ready := b.ReadyDigest(); ready {
		t.Fatal("oversize bundle published ready")
	}
	manifest, _, err := LoadRecordingManifest(filepath.Dir(b.dir), "session_test")
	if err != nil {
		t.Fatal(err)
	}
	if manifest.State != "partial" || manifest.ErrorCode != code {
		t.Fatalf("missing stable size failure: %#v", manifest)
	}
	for _, stream := range b.streams {
		if stream.file != nil {
			t.Fatal("capture writer still open after finalization")
		}
	}
}

func TestRecordingSizeContractMatchesCrossLanguageFixture(t *testing.T) {
	data, err := os.ReadFile("testdata/recording_bundle_limits.json")
	if err != nil {
		t.Fatal(err)
	}
	var contract struct {
		Version  int   `json:"version"`
		Artifact int64 `json:"max_artifact_bytes"`
		Bundle   int64 `json:"max_bundle_bytes"`
	}
	if err := json.Unmarshal(data, &contract); err != nil {
		t.Fatal(err)
	}
	b, _ := testBundle(t)
	if contract.Version != RecordingManifestVersion || contract.Artifact != maxRecordingArtifactBytes || contract.Bundle != maxRecordingBundleBytes || b.limits.artifact != contract.Artifact || b.limits.bundle != contract.Bundle {
		t.Fatal("producer size contract drifted from shared Rails fixture")
	}
}

func TestRecordingLegacyArtifactSizeBoundaryAndPermanentFailure(t *testing.T) {
	for _, size := range []int{128, 129} {
		t.Run(fmt.Sprintf("bytes_%d", size), func(t *testing.T) {
			b, _ := testBundle(t)
			b.limits = recordingSizeLimits{artifact: 128, bundle: 256}
			path := syntheticLegacy(t, size)
			legacy := map[string]string{"customer": path}
			err := b.Finalize(legacy)
			if size == 128 {
				if err != nil {
					t.Fatal(err)
				}
				digest, ready := b.ReadyDigest()
				if !ready {
					t.Fatal("exact artifact bound rejected")
				}
				if b.manifest.Artifacts[0].ByteSize != 128 {
					t.Fatal("artifact size changed")
				}
				if err := b.Finalize(legacy); err != nil {
					t.Fatal(err)
				}
				after, _ := b.ReadyDigest()
				if after != digest {
					t.Fatal("exact bound digest changed on retry")
				}
				return
			}
			if err == nil {
				t.Fatal("artifact one byte over limit accepted")
			}
			assertPartialSizeFailure(t, b, "artifact_size_limit_exceeded")
			if _, err := os.Stat(filepath.Join(b.dir, "customer_legacy.ogg")); !os.IsNotExist(err) {
				t.Fatal("oversize artifact copied")
			}
			if err := os.Truncate(path, 128); err != nil {
				t.Fatal(err)
			}
			if err := b.Finalize(legacy); err == nil {
				t.Fatal("retry made rejected oversize artifact final")
			}
			if err := b.Finalize(nil); err == nil {
				t.Fatal("retry silently excluded mandatory side")
			}
			assertPartialSizeFailure(t, b, "artifact_size_limit_exceeded")
		})
	}
}

func TestRecordingAggregateBoundaryIncludesAllSourcesAndLegacySides(t *testing.T) {
	for _, sources := range []int{0, 1, 2, 3} {
		for _, excess := range []int{0, 1} {
			t.Run(fmt.Sprintf("sources_%d_excess_%d", sources, excess), func(t *testing.T) {
				b, _ := testBundle(t)
				b.limits = recordingSizeLimits{artifact: 128, bundle: 256}
				for i := 0; i < sources; i++ {
					side, kind := "customer", "meta"
					if i > 0 {
						side, kind = "agent", "runtime"
					}
					if err := b.Capture(b.NewSource(side, kind, "audio/opus", 48000), packet(1, 960, uint32(i+1))); err != nil {
						t.Fatal(err)
					}
				}
				captureBytes := int(b.capturedBytes)
				customer := syntheticLegacy(t, 128)
				agent := syntheticLegacy(t, 128-captureBytes+excess)
				legacy := map[string]string{"customer": customer, "agent": agent}
				err := b.Finalize(legacy)
				if excess == 0 {
					if err != nil {
						t.Fatal(err)
					}
					var total int64
					for _, artifact := range b.manifest.Artifacts {
						total += artifact.ByteSize
					}
					if total != 256 || len(b.manifest.Artifacts) != sources+2 {
						t.Fatal("mandatory artifacts lost at exact aggregate bound")
					}
					digest, ready := b.ReadyDigest()
					if !ready {
						t.Fatal("exact bundle bound rejected")
					}
					if err := b.Finalize(legacy); err != nil {
						t.Fatal(err)
					}
					after, _ := b.ReadyDigest()
					if after != digest {
						t.Fatal("aggregate boundary retry changed digest")
					}
					return
				}
				if err == nil {
					t.Fatal("aggregate one byte over limit accepted")
				}
				// Without captures, the second legacy side itself also exceeds 128.
				code := "bundle_size_limit_exceeded"
				if sources == 0 {
					code = "artifact_size_limit_exceeded"
				}
				assertPartialSizeFailure(t, b, code)
				for _, side := range []string{"customer", "agent"} {
					if _, err := os.Stat(filepath.Join(b.dir, side+"_legacy.ogg")); !os.IsNotExist(err) {
						t.Fatal("preflight copied an incomplete artifact set")
					}
				}
				if err := os.Truncate(agent, 128-int64(captureBytes)); err != nil {
					t.Fatal(err)
				}
				if err := b.Finalize(legacy); err == nil {
					t.Fatal("retry cleared aggregate failure")
				}
				assertPartialSizeFailure(t, b, code)
			})
		}
	}
}

func TestCaptureAggregateLimitStopsBeforeWritingAnotherSource(t *testing.T) {
	b, _ := testBundle(t)
	b.limits = recordingSizeLimits{artifact: 128, bundle: 68}
	for i := 0; i < 2; i++ {
		if err := b.Capture(b.NewSource("agent", "runtime", "audio/opus", 48000), packet(1, 960, uint32(i+1))); err != nil {
			t.Fatal(err)
		}
	}
	if b.capturedBytes != 68 {
		t.Fatal("capture framing/header bytes omitted from total")
	}
	if err := b.Capture(b.NewSource("agent", "runtime", "audio/opus", 48000), packet(1, 960, 3)); err == nil {
		t.Fatal("capture wrote past aggregate bound")
	}
	if len(b.streams) != 2 || b.capturedBytes != 68 {
		t.Fatal("rejected capture still created or wrote a track")
	}
	if err := b.Finalize(nil); err == nil {
		t.Fatal("capture overflow became final")
	}
	assertPartialSizeFailure(t, b, "bundle_size_limit_exceeded")
}

func TestCaptureCannotCreateArtifactAboveSingleArtifactLimit(t *testing.T) {
	b, _ := testBundle(t)
	b.limits = recordingSizeLimits{artifact: 33, bundle: 256}
	if err := b.Capture(b.NewSource("customer", "meta", "audio/opus", 48000), packet(1, 960, 1)); err == nil {
		t.Fatal("capture header/frame exceeded artifact bound")
	}
	if len(b.streams) != 0 {
		t.Fatal("oversize capture created a file")
	}
	if err := b.Finalize(nil); err == nil {
		t.Fatal("artifact overflow became final")
	}
	assertPartialSizeFailure(t, b, "artifact_size_limit_exceeded")
}

func TestFinalizeRechecksActualCaptureFileSize(t *testing.T) {
	b, _ := testBundle(t)
	b.limits = recordingSizeLimits{artifact: 128, bundle: 256}
	if err := b.Capture(b.NewSource("customer", "meta", "audio/opus", 48000), packet(1, 960, 1)); err != nil {
		t.Fatal(err)
	}
	if err := b.streams[0].file.Truncate(129); err != nil {
		t.Fatal(err)
	}
	if err := b.Finalize(nil); err == nil {
		t.Fatal("finalization trusted stale capture bookkeeping")
	}
	assertPartialSizeFailure(t, b, "artifact_size_limit_exceeded")
}

func TestFinalizeRejectsLegacyGrowthAfterPreflightWithoutUnboundedCopy(t *testing.T) {
	b, _ := testBundle(t)
	b.limits = recordingSizeLimits{artifact: 128, bundle: 256}
	path := syntheticLegacy(t, 128)
	original := b.publish
	grown := false
	b.publish = func(data []byte) error {
		if !grown && bytes.Contains(data, []byte(`"state":"partial"`)) {
			grown = true
			f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
			if err != nil {
				return err
			}
			_, err = f.Write([]byte{'x'})
			f.Close()
			if err != nil {
				return err
			}
		}
		return original(data)
	}
	if err := b.Finalize(map[string]string{"customer": path}); err == nil {
		t.Fatal("input growth after preflight accepted")
	}
	assertPartialSizeFailure(t, b, "legacy_input_changed")
	entries, err := os.ReadDir(b.dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.Name() != "manifest.json" {
			t.Fatal("partial legacy copy retained or published")
		}
	}
	b.publish = original
	if err := os.Truncate(path, 128); err != nil {
		t.Fatal(err)
	}
	if err := b.Finalize(map[string]string{"customer": path}); err == nil {
		t.Fatal("retry cleared legacy growth failure")
	}
	assertPartialSizeFailure(t, b, "legacy_input_changed")
}

func TestRecorderSizeFailurePreservesLegacyCombinedPlayback(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // Exercise the existing single-side fallback.
	r, err := NewRecorder("session_size_playback", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Cleanup)
	r.bundle.limits = recordingSizeLimits{artifact: 33, bundle: 256}
	p := packet(1, 960, 1)
	if err := r.CaptureRTP(r.NewCaptureSource("customer", "meta", "audio/opus", 48000), p); err == nil {
		t.Fatal("expected bundle cap failure")
	}
	if err := r.WriteCustomerRTP(p); err != nil {
		t.Fatal(err)
	}
	if err := r.Finalize(); err == nil {
		t.Fatal("failed bundle became final")
	}
	if r.FileSize() <= 0 {
		t.Fatal("bundle failure removed legacy combined playback")
	}
	before, err := os.ReadFile(r.CombinedFilePath())
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Finalize(); err == nil {
		t.Fatal("bundle cap failure cleared on recorder retry")
	}
	after, err := os.ReadFile(r.CombinedFilePath())
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("retry changed combined playback")
	}
	if _, ready := r.RecordingBundleDigest(); ready {
		t.Fatal("failed bundle emitted ready")
	}
}
