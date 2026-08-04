package server

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/rtp"
)

type blockingWriteCloser struct {
	started   chan struct{}
	closed    chan struct{}
	startOnce sync.Once
	closeOnce sync.Once
}

func (w *blockingWriteCloser) Write(_ []byte) (int, error) {
	w.startOnce.Do(func() { close(w.started) })
	<-w.closed
	return 0, io.ErrClosedPipe
}

func (w *blockingWriteCloser) Close() error {
	w.closeOnce.Do(func() { close(w.closed) })
	return nil
}

func TestRuntimeStreamRejectsOversizedWebSocketMessages(t *testing.T) {
	readErr := make(chan error, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := runtimeStreamUpgrader.Upgrade(w, r, nil)
		if err != nil {
			readErr <- err
			return
		}
		defer conn.Close()
		configureRuntimeStreamConnection(conn)
		_, _, err = conn.ReadMessage()
		readErr <- err
	}))
	defer server.Close()

	url := "ws" + strings.TrimPrefix(server.URL, "http")
	conn, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	defer conn.Close()

	payload := make([]byte, runtimeStreamMaxMessageBytes+1)
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatalf("write oversized websocket message: %v", err)
	}

	select {
	case err := <-readErr:
		if err == nil || !strings.Contains(err.Error(), "read limit") {
			t.Fatalf("expected websocket read-limit error, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for oversized message rejection")
	}
}

func TestDecodeRuntimeAudioFrameEnforcesDecodedAudioLimit(t *testing.T) {
	atLimit := make([]byte, runtimeStreamMaxAudioBytes)
	decoded, err := decodeRuntimeAudioFrame(runtimeStreamFrame{
		Type: runtimeAudioOutType,
		Data: base64.StdEncoding.EncodeToString(atLimit),
	})
	if err != nil {
		t.Fatalf("decode frame at limit: %v", err)
	}
	if len(decoded) != runtimeStreamMaxAudioBytes {
		t.Fatalf("decoded bytes = %d, want %d", len(decoded), runtimeStreamMaxAudioBytes)
	}

	overLimit := make([]byte, runtimeStreamMaxAudioBytes+1)
	_, err = decodeRuntimeAudioFrame(runtimeStreamFrame{
		Type: runtimeAudioOutType,
		Data: base64.StdEncoding.EncodeToString(overLimit),
	})
	if err != errRuntimeAudioFrameTooLarge {
		t.Fatalf("oversized frame error = %v, want %v", err, errRuntimeAudioFrameTooLarge)
	}
}

func TestRuntimeAudioWriterCloseInterruptsBlockedWrite(t *testing.T) {
	pipe := &blockingWriteCloser{started: make(chan struct{}), closed: make(chan struct{})}
	writer := &runtimeAudioWriter{stdin: pipe}
	writeDone := make(chan error, 1)
	go func() {
		writeDone <- writer.WritePCM([]byte{1, 2, 3})
	}()

	select {
	case <-pipe.started:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for blocking audio write")
	}

	closeDone := make(chan struct{})
	go func() {
		writer.Close()
		close(closeDone)
	}()
	select {
	case <-closeDone:
	case <-time.After(time.Second):
		t.Fatal("writer close blocked behind stdin write")
	}
	select {
	case err := <-writeDone:
		if err == nil {
			t.Fatal("expected interrupted write to return an error")
		}
	case <-time.After(time.Second):
		t.Fatal("stdin write did not unblock after writer close")
	}
}

func TestRuntimeFFmpegArgsEnableLowLatencyRawPcm(t *testing.T) {
	args := runtimeFFmpegArgs(49152)
	mustContainInOrder(t, args,
		"-analyzeduration", "0",
		"-probesize", "32",
		"-fflags", "nobuffer",
		"-f", "s16le",
		"-i", "pipe:0",
		"-flush_packets", "1",
		"-f", "rtp",
		"rtp://127.0.0.1:49152",
	)
}

func TestRuntimeFFmpegProducesRTPBeforeInputEOF(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg is not installed")
	}

	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	defer conn.Close()

	port := conn.LocalAddr().(*net.UDPAddr).Port
	cmd := exec.Command("ffmpeg", runtimeFFmpegArgs(port)...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start ffmpeg: %v", err)
	}
	defer func() {
		_ = stdin.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	packets := make(chan int, 1)
	go func() {
		buf := make([]byte, 2048)
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _, readErr := conn.ReadFrom(buf)
		if readErr != nil {
			packets <- 0
			return
		}
		packets <- n
	}()

	frame := runtimeToneFrame()
	deadline := time.Now().Add(1200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if _, err := stdin.Write(frame); err != nil {
			t.Fatalf("write pcm frame before EOF: %v", err)
		}
		select {
		case n := <-packets:
			if n <= 0 {
				t.Fatalf("expected RTP packet before stdin EOF")
			}
			return
		case <-time.After(20 * time.Millisecond):
		}
	}

	select {
	case n := <-packets:
		if n <= 0 {
			t.Fatalf("expected RTP packet before stdin EOF")
		}
	case <-time.After(900 * time.Millisecond):
		t.Fatalf("ffmpeg did not emit RTP before stdin EOF")
	}
}

func TestRuntimeDecodeFFmpegArgsEnableLowLatencyOpusRTP(t *testing.T) {
	sdpPath := "/tmp/runtime-input.sdp"
	args := runtimeDecodeFFmpegArgs(sdpPath)
	mustContainInOrder(t, args,
		"-protocol_whitelist", "file,udp,rtp",
		"-analyzeduration", "0",
		"-probesize", "32",
		"-fflags", "nobuffer",
		"-i", sdpPath,
		"-f", "s16le",
		"-ar", runtimeInputRate,
		"-ac", "1",
		"pipe:1",
	)

	sdp := runtimeInputSDP(54321)
	for _, want := range []string{"m=audio 54321 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111"} {
		if !strings.Contains(sdp, want) {
			t.Fatalf("expected SDP to contain %q, got %q", want, sdp)
		}
	}
}

func TestRuntimeFFmpegArgsSupportSipG711Codecs(t *testing.T) {
	pcmuArgs := runtimeFFmpegArgsForCodec(49152, "audio/PCMU")
	mustContainInOrder(t, pcmuArgs,
		"-acodec", "pcm_mulaw",
		"-ar", "8000",
		"-payload_type", "0",
		"-f", "rtp",
		"rtp://127.0.0.1:49152",
	)

	pcmaArgs := runtimeFFmpegArgsForCodec(49153, "audio/PCMA")
	mustContainInOrder(t, pcmaArgs,
		"-acodec", "pcm_alaw",
		"-ar", "8000",
		"-payload_type", "8",
		"-f", "rtp",
		"rtp://127.0.0.1:49153",
	)
}

func TestRuntimeInputSDPSupportsSipG711Codecs(t *testing.T) {
	pcmuSDP := runtimeInputSDPForCodec(54321, "audio/PCMU")
	for _, want := range []string{"m=audio 54321 RTP/AVP 0", "a=rtpmap:0 PCMU/8000"} {
		if !strings.Contains(pcmuSDP, want) {
			t.Fatalf("expected PCMU SDP to contain %q, got %q", want, pcmuSDP)
		}
	}

	pcmaSDP := runtimeInputSDPForCodec(54322, "audio/PCMA")
	for _, want := range []string{"m=audio 54322 RTP/AVP 8", "a=rtpmap:8 PCMA/8000"} {
		if !strings.Contains(pcmaSDP, want) {
			t.Fatalf("expected PCMA SDP to contain %q, got %q", want, pcmaSDP)
		}
	}
}

func TestRuntimeInputCodecPrefersNegotiatedSessionCodec(t *testing.T) {
	tests := []struct {
		name     string
		remote   string
		fallback string
		want     string
	}{
		{name: "session pcma over relabeled remote pcmu", remote: "audio/PCMU", fallback: "audio/PCMA", want: "audio/pcma"},
		{name: "session pcmu over relabeled remote pcma", remote: "audio/PCMA", fallback: "audio/PCMU", want: "audio/pcmu"},
		{name: "session codec before remote track", remote: "", fallback: "audio/PCMA", want: "audio/pcma"},
		{name: "remote codec without session codec", remote: "audio/PCMU", fallback: "", want: "audio/pcmu"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := runtimeInputCodec(test.remote, test.fallback); got != test.want {
				t.Fatalf("runtime input codec = %q, want %q", got, test.want)
			}
		})
	}
}

func TestRuntimeInputProducerQueuesOnlyCustomerAudio(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	producer := newRuntimeAudioInputProducer(ctx, nil, runtimeStreamGrant{SessionID: "s1", RuntimeSessionID: "r1"}, nil)
	producer.ctx, producer.cancel = ctx, cancel
	producer.decoderStarting = true

	producer.OnAudioFrame("s1", "agent", "audio/opus", &rtp.Packet{Header: rtp.Header{PayloadType: 111}, Payload: []byte{1, 2, 3}})
	select {
	case <-producer.input:
		t.Fatalf("agent audio must not be sent to AI runtime input")
	default:
	}

	producer.OnAudioFrame("s1", "customer", "audio/opus", &rtp.Packet{Header: rtp.Header{PayloadType: 109, SequenceNumber: 7, Timestamp: 960}, Payload: []byte{1, 2, 3}})
	select {
	case raw := <-producer.input:
		if len(raw) == 0 {
			t.Fatalf("expected marshaled RTP packet")
		}
		var queued rtp.Packet
		if err := queued.Unmarshal(raw); err != nil {
			t.Fatalf("queued RTP packet must be valid: %v", err)
		}
		if queued.PayloadType != 111 {
			t.Fatalf("runtime decoder payload type = %d, want 111", queued.PayloadType)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatalf("customer RTP packet was not queued")
	}
}

func TestRuntimeInputProducerUsesRemoteG711Codec(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	producer := newRuntimeAudioInputProducer(ctx, nil, runtimeStreamGrant{SessionID: "s1", RuntimeSessionID: "r1"}, nil)
	producer.ctx, producer.cancel = ctx, cancel
	producer.codec = "audio/pcmu"
	producer.decoderStarting = true

	producer.OnAudioFrame("s1", "customer", "audio/PCMU", &rtp.Packet{Header: rtp.Header{PayloadType: 109}, Payload: []byte{1, 2, 3}})

	select {
	case raw := <-producer.input:
		var queued rtp.Packet
		if err := queued.Unmarshal(raw); err != nil {
			t.Fatalf("queued RTP packet must be valid: %v", err)
		}
		if queued.PayloadType != 0 {
			t.Fatalf("PCMU decoder payload type = %d, want 0", queued.PayloadType)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatalf("customer PCMU RTP packet was not queued")
	}
}

func TestRuntimeDecodeFFmpegProducesPCMBeforeInputEOF(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg is not installed")
	}

	encodedRTPConn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen encoded RTP UDP: %v", err)
	}
	defer encodedRTPConn.Close()

	encoder := exec.Command("ffmpeg", runtimeFFmpegArgs(encodedRTPConn.LocalAddr().(*net.UDPAddr).Port)...)
	encoder.Stdout = io.Discard
	encoder.Stderr = io.Discard
	encoderStdin, err := encoder.StdinPipe()
	if err != nil {
		t.Fatalf("encoder stdin pipe: %v", err)
	}
	if err := encoder.Start(); err != nil {
		t.Fatalf("start encoder ffmpeg: %v", err)
	}
	defer func() {
		_ = encoderStdin.Close()
		if encoder.Process != nil {
			_ = encoder.Process.Kill()
		}
		_ = encoder.Wait()
	}()

	decoderListener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve decoder UDP port: %v", err)
	}
	decoderPort := decoderListener.LocalAddr().(*net.UDPAddr).Port
	_ = decoderListener.Close()

	sdpFile, err := os.CreateTemp(t.TempDir(), "runtime-input-*.sdp")
	if err != nil {
		t.Fatalf("create SDP: %v", err)
	}
	if _, err := sdpFile.WriteString(runtimeInputSDP(decoderPort)); err != nil {
		t.Fatalf("write SDP: %v", err)
	}
	if err := sdpFile.Close(); err != nil {
		t.Fatalf("close SDP: %v", err)
	}

	decoder := exec.Command("ffmpeg", runtimeDecodeFFmpegArgs(sdpFile.Name())...)
	decoder.Stderr = io.Discard
	decoderStdout, err := decoder.StdoutPipe()
	if err != nil {
		t.Fatalf("decoder stdout pipe: %v", err)
	}
	if err := decoder.Start(); err != nil {
		t.Fatalf("start decoder ffmpeg: %v", err)
	}
	defer func() {
		if decoder.Process != nil {
			_ = decoder.Process.Kill()
		}
		_ = decoder.Wait()
	}()

	decoderUDP, err := net.Dial("udp4", fmt.Sprintf("127.0.0.1:%d", decoderPort))
	if err != nil {
		t.Fatalf("dial decoder UDP: %v", err)
	}
	defer decoderUDP.Close()

	go func() {
		buf := make([]byte, 2048)
		for {
			_ = encodedRTPConn.SetReadDeadline(time.Now().Add(2 * time.Second))
			n, _, readErr := encodedRTPConn.ReadFrom(buf)
			if readErr != nil {
				return
			}
			_, _ = decoderUDP.Write(buf[:n])
		}
	}()

	pcmReady := make(chan int, 1)
	go func() {
		buf := make([]byte, runtimeInputFrameBytes)
		n, _ := io.ReadFull(decoderStdout, buf)
		pcmReady <- n
	}()

	frame := runtimeToneFrame()
	deadline := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if _, err := encoderStdin.Write(frame); err != nil {
			t.Fatalf("write encoder PCM before EOF: %v", err)
		}
		select {
		case n := <-pcmReady:
			if n < runtimeInputFrameBytes {
				t.Fatalf("expected a full runtime input PCM frame, got %d bytes", n)
			}
			return
		case <-time.After(20 * time.Millisecond):
		}
	}

	select {
	case n := <-pcmReady:
		if n < runtimeInputFrameBytes {
			t.Fatalf("expected a full runtime input PCM frame, got %d bytes", n)
		}
	case <-time.After(1500 * time.Millisecond):
		t.Fatalf("ffmpeg decoder did not emit PCM before encoder stdin EOF")
	}
}

func runtimeToneFrame() []byte {
	const sampleRate = 8000
	const samplesPerFrame = 160 // 20ms at 8kHz
	frame := make([]byte, samplesPerFrame*2)
	for i := 0; i < samplesPerFrame; i++ {
		sample := int16(math.Sin(2*math.Pi*440*float64(i)/sampleRate) * 12000)
		binary.LittleEndian.PutUint16(frame[i*2:], uint16(sample))
	}
	return frame
}

func mustContainInOrder(t *testing.T, values []string, expected ...string) {
	t.Helper()
	cursor := 0
	for _, want := range expected {
		found := false
		for cursor < len(values) {
			if values[cursor] == want {
				found = true
				cursor++
				break
			}
			cursor++
		}
		if !found {
			t.Fatalf("expected %q in args after position %d: %#v", want, cursor, values)
		}
	}
}
