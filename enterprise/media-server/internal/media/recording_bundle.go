package media

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	"github.com/pion/rtp"
	"golang.org/x/sys/unix"
)

const RecordingManifestVersion = 1
const maxCaptureArtifactBytes = 8 << 20
const maxRecordingArtifacts = 1024
const captureMagic = "OLRTP1\n"

// Keep these bounds aligned with the Rails v1 manifest validator. All mandatory
// raw captures and legacy sides count toward the bundle limit.
const maxRecordingArtifactBytes int64 = 128 << 20
const maxRecordingBundleBytes int64 = 256 << 20

type recordingSizeLimits struct {
	artifact int64
	bundle   int64
}

var errRecordingInputChanged = errors.New("recording input changed during finalization")

var recordingIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// Offsets describe recorder observation, not sender capture or decoded audio.
type RecordingManifest struct {
	Version          int                 `json:"version"`
	SessionID        string              `json:"session_id"`
	CallID           string              `json:"call_id"`
	AccountID        string              `json:"account_id"`
	State            string              `json:"state"`
	ClockBasis       string              `json:"clock_basis"`
	Origin           string              `json:"origin"`
	EndOffsetNS      int64               `json:"end_offset_ns"`
	DecodedAlignment string              `json:"decoded_alignment"`
	ErrorCode        string              `json:"error_code,omitempty"`
	Artifacts        []RecordingArtifact `json:"artifacts"`
}

type RecordingArtifact struct {
	ID               string `json:"id"`
	Format           string `json:"format"`
	Side             string `json:"side"`
	SourceKind       string `json:"source_kind"`
	Generation       uint64 `json:"generation"`
	Codec            string `json:"codec"`
	ClockRate        uint32 `json:"clock_rate"`
	SSRC             uint32 `json:"ssrc"`
	FirstOffsetNS    int64  `json:"first_offset_ns"`
	LastOffsetNS     int64  `json:"last_offset_ns"`
	FirstTimestamp   uint32 `json:"first_rtp_timestamp"`
	LastTimestamp    uint32 `json:"last_rtp_timestamp"`
	RTPTicks         uint64 `json:"rtp_ticks"`
	Packets          uint64 `json:"packets"`
	UnorderedPackets uint64 `json:"unordered_packets"`
	TimestampWraps   uint64 `json:"timestamp_wraps"`
	ContinuityReason string `json:"continuity_reason"`
	ByteSize         int64  `json:"byte_size"`
	SHA256           string `json:"sha256"`
}

type CaptureSource struct {
	owner      *RecordingBundle
	generation uint64
	side       string
	kind       string
	codec      string
	clockRate  uint32
	streams    map[uint32]*captureStream
}

type captureStream struct {
	artifact *RecordingArtifact
	file     *os.File
	writer   io.Writer
	lastSeq  uint16
	lastTS   uint32
}

type RecordingBundle struct {
	mu            sync.Mutex
	dir           string
	startedAt     time.Time
	now           func() time.Time
	manifest      RecordingManifest
	streams       []*captureStream
	nextSource    uint64
	nextTrack     uint64
	stopped       bool
	final         bool
	publish       func([]byte) error
	limits        recordingSizeLimits
	capturedBytes int64
}

func newRecordingBundle(sessionID, dir string, startedAt time.Time) (*RecordingBundle, error) {
	if !recordingIDPattern.MatchString(sessionID) {
		return nil, errors.New("invalid recording session ID")
	}
	bundleDir := filepath.Join(dir, sessionID+"_recording_v1")
	// Never replace a bundle from an earlier call or server process.
	if err := os.Mkdir(bundleDir, 0o700); err != nil {
		return nil, fmt.Errorf("reserve recording bundle: %w", err)
	}
	b := &RecordingBundle{dir: bundleDir, startedAt: startedAt, now: time.Now,
		manifest: RecordingManifest{Version: 1, SessionID: sessionID, State: "partial", ClockBasis: "recorder_observed_monotonic", Origin: startedAt.UTC().Format(time.RFC3339Nano), DecodedAlignment: "unknown", Artifacts: []RecordingArtifact{}},
		limits:   recordingSizeLimits{artifact: maxRecordingArtifactBytes, bundle: maxRecordingBundleBytes},
	}
	b.publish = b.publishManifest
	if err := b.checkpoint(); err != nil {
		return nil, err
	}
	return b, nil
}

func (b *RecordingBundle) SetIdentity(callID, accountID string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped {
		if b.manifest.CallID == callID && b.manifest.AccountID == accountID {
			return nil
		}
		return errors.New("recording bundle stopped")
	}
	if b.manifest.CallID != "" && (b.manifest.CallID != callID || b.manifest.AccountID != accountID) {
		return errors.New("recording identity already bound")
	}
	b.manifest.CallID, b.manifest.AccountID = callID, accountID
	return b.checkpoint()
}

func (b *RecordingBundle) NewSource(side, kind, codec string, clockRate uint32) *CaptureSource {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped || (side != "customer" && side != "agent") {
		return nil
	}
	b.nextSource++
	return &CaptureSource{owner: b, generation: b.nextSource, side: side, kind: kind, codec: codec, clockRate: clockRate, streams: map[uint32]*captureStream{}}
}

// Capture is lossless: each record is offset_ns(u64 BE), length(u32 BE), RTP bytes.
// Different SSRCs stay independent, including late packets from an old SSRC.
func (b *RecordingBundle) Capture(source *CaptureSource, packet *rtp.Packet) error {
	observed := b.now().Sub(b.startedAt).Nanoseconds()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped || source == nil {
		return nil
	}
	if source.owner != b {
		return errors.New("foreign capture source")
	}
	if packet == nil || len(packet.Payload) == 0 {
		return nil
	}
	if b.manifest.ErrorCode != "" {
		return errors.New("capture already failed")
	}
	raw, err := packet.Marshal()
	if err != nil {
		return b.fail(err)
	}
	if len(raw) > 65535 || observed < 0 {
		return b.fail(errors.New("invalid capture packet"))
	}
	s := source.streams[packet.SSRC]
	reason := "source_start"
	if s != nil {
		seqDelta := int16(packet.SequenceNumber - s.lastSeq)
		tsDelta := int32(packet.Timestamp - s.lastTS)
		if seqDelta > 0 && tsDelta < 0 {
			reason = "timestamp_reset"
			s = nil
		}
		if s != nil && s.artifact.ByteSize+int64(len(raw)+12) > b.captureArtifactLimit() {
			reason = "size_limit"
			s = nil
		}
	}
	additional := int64(len(raw) + 12)
	if s == nil {
		additional += int64(len(captureMagic))
		if additional > b.captureArtifactLimit() {
			return b.failWithCode("artifact_size_limit_exceeded", errors.New("capture artifact exceeds size limit"))
		}
	}
	if additional > b.limits.bundle-b.capturedBytes {
		return b.failWithCode("bundle_size_limit_exceeded", errors.New("capture bundle exceeds size limit"))
	}
	if s == nil {
		s, err = b.startStream(source, packet, reason, observed)
		if err != nil {
			return b.fail(err)
		}
	}
	frame := make([]byte, 12+len(raw))
	binary.BigEndian.PutUint64(frame[:8], uint64(observed))
	binary.BigEndian.PutUint32(frame[8:12], uint32(len(raw)))
	copy(frame[12:], raw)
	n, err := s.writer.Write(frame)
	if err != nil || n != len(frame) {
		return b.fail(errors.New("capture frame write failed"))
	}
	a := s.artifact
	if a.Packets > 0 {
		seqDelta, tsDelta := int16(packet.SequenceNumber-s.lastSeq), int32(packet.Timestamp-s.lastTS)
		if seqDelta > 0 && tsDelta >= 0 {
			a.RTPTicks += uint64(tsDelta)
			if packet.Timestamp < s.lastTS {
				a.TimestampWraps++
			}
			s.lastSeq, s.lastTS = packet.SequenceNumber, packet.Timestamp
			a.LastTimestamp = packet.Timestamp
		} else {
			a.UnorderedPackets++
		}
	} else {
		s.lastSeq, s.lastTS = packet.SequenceNumber, packet.Timestamp
	}
	if observed < a.FirstOffsetNS {
		a.FirstOffsetNS = observed
	}
	if observed > a.LastOffsetNS {
		a.LastOffsetNS = observed
	}
	a.Packets++
	a.ByteSize += int64(len(frame))
	b.capturedBytes += int64(len(frame))
	return nil
}

func (b *RecordingBundle) captureArtifactLimit() int64 {
	if b.limits.artifact < maxCaptureArtifactBytes {
		return b.limits.artifact
	}
	return maxCaptureArtifactBytes
}

func (b *RecordingBundle) startStream(source *CaptureSource, p *rtp.Packet, reason string, offset int64) (*captureStream, error) {
	if len(b.streams) >= maxRecordingArtifacts-2 {
		return nil, errors.New("capture artifact limit")
	}
	b.nextTrack++
	a := &RecordingArtifact{ID: fmt.Sprintf("track_%06d", b.nextTrack), Format: "rtp_framed_v1", Side: source.side, SourceKind: source.kind, Generation: source.generation, Codec: source.codec, ClockRate: source.clockRate, SSRC: p.SSRC, FirstOffsetNS: offset, LastOffsetNS: offset, FirstTimestamp: p.Timestamp, LastTimestamp: p.Timestamp, ContinuityReason: reason, ByteSize: int64(len(captureMagic))}
	f, err := os.OpenFile(filepath.Join(b.dir, a.ID+".rtp"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	if n, err := io.WriteString(f, captureMagic); err != nil || n != len(captureMagic) {
		f.Close()
		_ = os.Remove(filepath.Join(b.dir, a.ID+".rtp"))
		return nil, errors.New("capture header write failed")
	}
	s := &captureStream{artifact: a, file: f, writer: f}
	b.streams = append(b.streams, s)
	b.capturedBytes += int64(len(captureMagic))
	source.streams[p.SSRC] = s
	if err := b.checkpoint(); err != nil {
		return nil, err
	}
	return s, nil
}

func (b *RecordingBundle) fail(err error) error {
	return b.failWithCode("capture_write_failed", err)
}

func (b *RecordingBundle) failWithCode(code string, err error) error {
	if b.manifest.ErrorCode == "" {
		b.manifest.ErrorCode = code
	}
	b.manifest.State = "partial"
	_ = b.checkpoint()
	return err
}

func (b *RecordingBundle) checkpoint() error {
	b.manifest.Artifacts = b.manifest.Artifacts[:0]
	for _, s := range b.streams {
		b.manifest.Artifacts = append(b.manifest.Artifacts, *s.artifact)
	}
	data, err := json.Marshal(b.manifest)
	if err != nil {
		return err
	}
	return b.publish(data)
}

// Failed publication is retryable after RTP writes have stopped. A successful
// finalization is immutable, including its end offset and serialized digest.
func (b *RecordingBundle) Finalize(legacy map[string]string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.final {
		return nil
	}
	if !b.stopped {
		b.stopped = true
		b.manifest.EndOffsetNS = b.now().Sub(b.startedAt).Nanoseconds()
	}
	var closeErr error
	for _, s := range b.streams {
		if s.file != nil {
			if err := s.file.Sync(); err != nil {
				closeErr = err
			}
			if err := s.file.Close(); err != nil {
				closeErr = err
			}
			s.file = nil
		}
	}
	if closeErr != nil {
		return b.fail(closeErr)
	}
	if b.manifest.ErrorCode != "" {
		_ = b.checkpoint()
		return errors.New("incomplete recording bundle")
	}
	var total int64
	for _, s := range b.streams {
		f, err := OpenRecordingBundleFile(filepath.Dir(b.dir), b.manifest.SessionID, s.artifact.ID+".rtp")
		if err != nil {
			return err
		}
		info, err := f.Stat()
		if err != nil {
			f.Close()
			return err
		}
		if err := b.checkArtifactSize(info.Size(), total); err != nil {
			f.Close()
			return err
		}
		if err := validateCapture(io.LimitReader(f, info.Size()+1), s.artifact.Packets); err != nil {
			f.Close()
			return b.fail(err)
		}
		_, _ = f.Seek(0, io.SeekStart)
		digest, size, err := boundedFileDigest(f, info.Size())
		f.Close()
		if err != nil {
			return b.fail(err)
		}
		if size != s.artifact.ByteSize {
			return b.fail(errRecordingInputChanged)
		}
		s.artifact.SHA256 = digest
		total += size
	}
	// Preflight every required legacy side before copying any of them. Descriptor
	// ownership and bounded copies prevent growth or path replacement from silently
	// changing the artifact set between the limit check and final publication.
	type legacyInput struct {
		side string
		file *os.File
		size int64
	}
	var inputs []legacyInput
	defer func() {
		for _, input := range inputs {
			input.file.Close()
		}
	}()
	for _, side := range []string{"customer", "agent"} {
		path := legacy[side]
		if path == "" {
			continue
		}
		input, err := openLegacyRecordingInput(path)
		if err != nil {
			return err
		}
		info, err := input.Stat()
		if err != nil {
			input.Close()
			return err
		}
		inputs = append(inputs, legacyInput{side, input, info.Size()})
		if err := b.checkArtifactSize(info.Size(), total); err != nil {
			return err
		}
		total += info.Size()
	}
	if err := b.checkpoint(); err != nil {
		return err
	}
	for _, input := range inputs {
		artifact, err := b.stageLegacy(input.side, input.file, input.size)
		if errors.Is(err, errRecordingInputChanged) {
			return b.failWithCode("legacy_input_changed", err)
		}
		if err != nil {
			return err
		}
		b.manifest.Artifacts = append(b.manifest.Artifacts, artifact)
	}
	b.manifest.State = "final"
	data, err := json.Marshal(b.manifest)
	if err != nil {
		return err
	}
	if err := b.publish(data); err != nil {
		b.manifest.State = "partial"
		return err
	}
	b.final = true
	return nil
}

func (b *RecordingBundle) checkArtifactSize(size, total int64) error {
	if size <= 0 {
		return b.failWithCode("empty_recording_artifact", errors.New("empty recording artifact"))
	}
	if size > b.limits.artifact {
		return b.failWithCode("artifact_size_limit_exceeded", errors.New("recording artifact exceeds size limit"))
	}
	if size > b.limits.bundle-total {
		return b.failWithCode("bundle_size_limit_exceeded", errors.New("recording bundle exceeds size limit"))
	}
	return nil
}

func openLegacyRecordingInput(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		f.Close()
		return nil, errors.New("nonregular legacy recording input")
	}
	return f, nil
}

func (b *RecordingBundle) stageLegacy(side string, input *os.File, size int64) (RecordingArtifact, error) {
	f, err := os.CreateTemp(b.dir, side+"-legacy-*.tmp")
	if err != nil {
		return RecordingArtifact{}, err
	}
	defer f.Close()
	defer os.Remove(f.Name())
	if _, err := io.CopyN(f, input, size); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return RecordingArtifact{}, errRecordingInputChanged
		}
		return RecordingArtifact{}, err
	}
	var probe [1]byte
	if n, err := input.Read(probe[:]); n != 0 || err != io.EOF {
		if n != 0 || err == nil {
			return RecordingArtifact{}, errRecordingInputChanged
		}
		return RecordingArtifact{}, err
	}
	if err := f.Sync(); err != nil {
		return RecordingArtifact{}, err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return RecordingArtifact{}, err
	}
	digest, _, err := boundedFileDigest(f, size)
	if err != nil {
		return RecordingArtifact{}, err
	}
	if err := f.Close(); err != nil {
		return RecordingArtifact{}, err
	}
	if err := os.Rename(f.Name(), filepath.Join(b.dir, side+"_legacy.ogg")); err != nil {
		return RecordingArtifact{}, err
	}
	return RecordingArtifact{ID: side + "_legacy", Format: "legacy_side_ogg", Side: side, SourceKind: "legacy", Codec: "unknown", ContinuityReason: "legacy_timing_unknown", ByteSize: size, SHA256: digest}, nil
}

func boundedFileDigest(f *os.File, size int64) (string, int64, error) {
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(f, size+1))
	if err != nil {
		return "", n, err
	}
	if n != size {
		return "", n, errRecordingInputChanged
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

func validateCapture(reader io.Reader, expected uint64) error {
	magic := make([]byte, len(captureMagic))
	if _, err := io.ReadFull(reader, magic); err != nil || string(magic) != captureMagic {
		return errors.New("invalid capture header")
	}
	var packets uint64
	for {
		header := make([]byte, 12)
		_, err := io.ReadFull(reader, header)
		if err == io.EOF {
			break
		}
		if err != nil {
			return errors.New("partial capture frame")
		}
		n := binary.BigEndian.Uint32(header[8:])
		if n == 0 || n > 65535 {
			return errors.New("invalid capture frame size")
		}
		raw := make([]byte, n)
		if _, err := io.ReadFull(reader, raw); err != nil {
			return err
		}
		packet := &rtp.Packet{}
		if err := packet.Unmarshal(raw); err != nil {
			return err
		}
		packets++
	}
	if packets != expected {
		return errors.New("capture packet count mismatch")
	}
	return nil
}

func fileDigest(f *os.File) (string, int64, error) {
	h := sha256.New()
	n, err := io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), n, err
}

func (b *RecordingBundle) publishManifest(data []byte) error {
	f, err := os.CreateTemp(b.dir, "manifest-*.tmp")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(name, filepath.Join(b.dir, "manifest.json")); err != nil {
		return err
	}
	dir, err := os.Open(b.dir)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// Directory-relative NOFOLLOW opens protect both the bundle directory and file.
func OpenRecordingBundleFile(root, sessionID, name string) (*os.File, error) {
	if !recordingIDPattern.MatchString(sessionID) || (name != "manifest.json" && !regexp.MustCompile(`^(track_[0-9]{6}\.rtp|customer_legacy\.ogg|agent_legacy\.ogg)$`).MatchString(name)) {
		return nil, errors.New("invalid recording artifact")
	}
	rootFD, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(rootFD)
	dirFD, err := unix.Openat(rootFD, sessionID+"_recording_v1", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(dirFD)
	fd, err := unix.Openat(dirFD, name, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), name)
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		f.Close()
		return nil, errors.New("nonregular recording artifact")
	}
	return f, nil
}

func LoadRecordingManifest(root, sessionID string) (RecordingManifest, []byte, error) {
	f, err := OpenRecordingBundleFile(root, sessionID, "manifest.json")
	if err != nil {
		return RecordingManifest{}, nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, (1<<20)+1))
	if err != nil || len(data) > 1<<20 {
		return RecordingManifest{}, nil, errors.New("invalid manifest size")
	}
	var manifest RecordingManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return manifest, nil, err
	}
	if manifest.Version != 1 || manifest.SessionID != sessionID || len(manifest.Artifacts) > maxRecordingArtifacts {
		return manifest, nil, errors.New("invalid recording manifest")
	}
	return manifest, data, nil
}

func RecordingArtifactFilename(a RecordingArtifact) (string, error) {
	switch a.Format {
	case "rtp_framed_v1":
		if regexp.MustCompile(`^track_[0-9]{6}$`).MatchString(a.ID) {
			return a.ID + ".rtp", nil
		}
	case "legacy_side_ogg":
		if a.ID == "customer_legacy" || a.ID == "agent_legacy" {
			return a.ID + ".ogg", nil
		}
	}
	return "", errors.New("invalid artifact format or ID")
}

func (b *RecordingBundle) ReadyDigest() (string, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.final {
		return "", false
	}
	data, err := json.Marshal(b.manifest)
	if err != nil {
		return "", false
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), true
}

func (b *RecordingBundle) Cleanup() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, s := range b.streams {
		if s.file != nil {
			_ = s.file.Close()
			s.file = nil
		}
	}
	rootFD, err := unix.Open(filepath.Dir(b.dir), unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return
	}
	defer unix.Close(rootFD)
	dirFD, err := unix.Openat(rootFD, filepath.Base(b.dir), unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return
	}
	defer unix.Close(dirFD)
	for _, s := range b.streams {
		_ = unix.Unlinkat(dirFD, s.artifact.ID+".rtp", 0)
	}
	for _, name := range []string{"manifest.json", "customer_legacy.ogg", "agent_legacy.ogg"} {
		_ = unix.Unlinkat(dirFD, name, 0)
	}
	_ = unix.Unlinkat(rootFD, filepath.Base(b.dir), unix.AT_REMOVEDIR)
}
