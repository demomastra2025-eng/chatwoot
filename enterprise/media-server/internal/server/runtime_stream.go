package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/rtp"

	"github.com/chatwoot/chatwoot-media-server/internal/session"
)

const (
	runtimeAudioOutType     = "AUDIO_OUT"
	runtimeAudioInType      = "AUDIO_IN"
	runtimeOutputRate       = "8000"
	runtimeInputRate        = "16000"
	runtimeInputFrameBytes  = 640 // 20ms PCM16 mono at 16kHz
	runtimeInputBufferDepth = 256
)

var runtimeStreamUpgrader = websocket.Upgrader{
	CheckOrigin: func(_ *http.Request) bool { return true },
}

type runtimeStreamFrame struct {
	Type     string `json:"type"`
	Data     string `json:"data"`
	MimeType string `json:"mime_type,omitempty"`
}

func (h *Handlers) serveRuntimeStream(w http.ResponseWriter, r *http.Request, grant runtimeStreamGrant) {
	if h.manager == nil {
		writeError(w, http.StatusServiceUnavailable, "session manager unavailable")
		return
	}

	sess := h.manager.GetSession(grant.SessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	conn, err := runtimeStreamUpgrader.Upgrade(w, r, nil)
	if err != nil {
		slog.Warn("handler: runtime stream websocket upgrade failed",
			"session_id", grant.SessionID,
			"runtime_session_id", grant.RuntimeSessionID,
			"error", err,
		)
		return
	}
	defer conn.Close()

	consumedGrant, ok, status, message := h.consumeRuntimeStreamGrant(grant.SessionID, grant.Token)
	if !ok {
		deadline := time.Now().Add(200 * time.Millisecond)
		_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, message), deadline)
		slog.Warn("handler: runtime stream grant consume failed after websocket upgrade",
			"session_id", grant.SessionID,
			"runtime_session_id", grant.RuntimeSessionID,
			"status", status,
			"message", message,
		)
		return
	}
	grant = consumedGrant

	slog.Info("handler: runtime stream websocket connected",
		"session_id", grant.SessionID,
		"runtime_session_id", grant.RuntimeSessionID,
		"call_ref", grant.CallRef,
		"account_id", grant.AccountID,
	)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	stopRuntimeCloseWatcher := closeRuntimeStreamOnSessionDone(ctx, sess, conn, grant)
	defer stopRuntimeCloseWatcher()
	writer := newRuntimeAudioWriter(ctx, sess, grant)
	defer writer.Close()
	inputProducer := newRuntimeAudioInputProducer(ctx, sess, grant, conn)
	if err := inputProducer.Start(); err != nil {
		slog.Warn("handler: runtime audio input producer unavailable",
			"session_id", grant.SessionID,
			"runtime_session_id", grant.RuntimeSessionID,
			"error", err,
		)
	} else {
		defer inputProducer.Close()
		if sess.Bridge != nil {
			sess.Bridge.AddConsumer(inputProducer)
		} else {
			slog.Warn("handler: runtime audio input bridge unavailable",
				"session_id", grant.SessionID,
				"runtime_session_id", grant.RuntimeSessionID,
			)
		}
	}

	for {
		_, data, readErr := conn.ReadMessage()
		if readErr != nil {
			if websocket.IsUnexpectedCloseError(readErr, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				slog.Warn("handler: runtime stream websocket read failed",
					"session_id", grant.SessionID,
					"runtime_session_id", grant.RuntimeSessionID,
					"error", readErr,
				)
			}
			break
		}

		var frame runtimeStreamFrame
		if err := json.Unmarshal(data, &frame); err != nil {
			slog.Warn("handler: runtime stream invalid frame",
				"session_id", grant.SessionID,
				"runtime_session_id", grant.RuntimeSessionID,
				"error", err,
			)
			continue
		}
		if !strings.EqualFold(strings.TrimSpace(frame.Type), runtimeAudioOutType) || strings.TrimSpace(frame.Data) == "" {
			continue
		}

		pcm, err := base64.StdEncoding.DecodeString(frame.Data)
		if err != nil {
			slog.Warn("handler: runtime stream invalid audio frame",
				"session_id", grant.SessionID,
				"runtime_session_id", grant.RuntimeSessionID,
				"error", err,
			)
			continue
		}
		if len(pcm) == 0 {
			continue
		}
		if err := writer.WritePCM(pcm); err != nil {
			slog.Warn("handler: runtime stream audio write failed",
				"session_id", grant.SessionID,
				"runtime_session_id", grant.RuntimeSessionID,
				"error", err,
			)
		}
	}

	slog.Info("handler: runtime stream websocket disconnected",
		"session_id", grant.SessionID,
		"runtime_session_id", grant.RuntimeSessionID,
		"rtp_packets", writer.Packets(),
		"input_pcm_frames", inputProducer.PCMFrames(),
	)
}

func closeRuntimeStreamOnSessionDone(ctx context.Context, sess *session.Session, conn *websocket.Conn, grant runtimeStreamGrant) func() {
	done := sess.Done()
	if done == nil {
		return func() {}
	}

	stop := make(chan struct{})
	var once sync.Once
	stopFn := func() { once.Do(func() { close(stop) }) }
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-stop:
			return
		case <-done:
		}

		slog.Info("handler: runtime stream closing after media session termination",
			"session_id", grant.SessionID,
			"runtime_session_id", grant.RuntimeSessionID,
			"call_ref", grant.CallRef,
		)
		deadline := time.Now().Add(200 * time.Millisecond)
		_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "media session terminated"), deadline)
		_ = conn.Close()
	}()
	return stopFn
}

type runtimeAudioWriter struct {
	ctx    context.Context
	sess   *session.Session
	grant  runtimeStreamGrant
	mu     sync.Mutex
	stdin  io.WriteCloser
	conn   net.PacketConn
	cmd    *exec.Cmd
	pkts   uint64
	closed bool
}

func newRuntimeAudioWriter(ctx context.Context, sess *session.Session, grant runtimeStreamGrant) *runtimeAudioWriter {
	return &runtimeAudioWriter{ctx: ctx, sess: sess, grant: grant}
}

func (w *runtimeAudioWriter) WritePCM(pcm []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return errors.New("runtime audio writer closed")
	}
	if w.stdin == nil {
		if err := w.startLocked(); err != nil {
			return err
		}
	}
	_, err := w.stdin.Write(pcm)
	return err
}

func (w *runtimeAudioWriter) Packets() uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.pkts
}

func (w *runtimeAudioWriter) Close() {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	stdin := w.stdin
	conn := w.conn
	cmd := w.cmd
	w.mu.Unlock()

	if stdin != nil {
		_ = stdin.Close()
	}
	if conn != nil {
		_ = conn.Close()
	}
	if cmd != nil && cmd.Process != nil {
		done := make(chan struct{})
		go func() {
			_ = cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			_ = cmd.Process.Kill()
			<-done
		}
	}
}

type runtimeAudioInputProducer struct {
	parentCtx context.Context
	ctx       context.Context
	cancel    context.CancelFunc
	sess      *session.Session
	grant     runtimeStreamGrant
	ws        *websocket.Conn
	wsMu      sync.Mutex
	mu        sync.Mutex
	input     chan []byte
	udp       net.Conn
	cmd       *exec.Cmd
	sdpPath   string
	frames    uint64
	pkts      uint64
	dropped   uint64
	closed    bool
}

func newRuntimeAudioInputProducer(parentCtx context.Context, sess *session.Session, grant runtimeStreamGrant, ws *websocket.Conn) *runtimeAudioInputProducer {
	return &runtimeAudioInputProducer{
		parentCtx: parentCtx,
		sess:      sess,
		grant:     grant,
		ws:        ws,
		input:     make(chan []byte, runtimeInputBufferDepth),
	}
}

func (p *runtimeAudioInputProducer) Start() error {
	if p.sess == nil || p.sess.Bridge == nil {
		return errors.New("runtime audio input bridge unavailable")
	}

	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("allocate runtime audio input udp: %w", err)
	}
	udpAddr, ok := listener.LocalAddr().(*net.UDPAddr)
	_ = listener.Close()
	if !ok {
		return errors.New("runtime audio input udp address unavailable")
	}

	sdpFile, err := os.CreateTemp("", "chatwoot-runtime-input-*.sdp")
	if err != nil {
		return fmt.Errorf("create runtime input sdp: %w", err)
	}
	p.sdpPath = sdpFile.Name()
	if _, err := sdpFile.WriteString(runtimeInputSDP(udpAddr.Port)); err != nil {
		_ = sdpFile.Close()
		_ = os.Remove(p.sdpPath)
		return fmt.Errorf("write runtime input sdp: %w", err)
	}
	if err := sdpFile.Close(); err != nil {
		_ = os.Remove(p.sdpPath)
		return fmt.Errorf("close runtime input sdp: %w", err)
	}

	p.ctx, p.cancel = context.WithCancel(p.parentCtx)
	cmd := exec.CommandContext(p.ctx, "ffmpeg", runtimeDecodeFFmpegArgs(p.sdpPath)...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		p.cleanupStartFailure()
		return fmt.Errorf("open ffmpeg decoder stdout: %w", err)
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		p.cleanupStartFailure()
		return fmt.Errorf("start ffmpeg opus decoder: %w", err)
	}

	udpConn, err := net.Dial("udp4", fmt.Sprintf("127.0.0.1:%d", udpAddr.Port))
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		p.cleanupStartFailure()
		return fmt.Errorf("dial runtime audio input udp: %w", err)
	}

	p.mu.Lock()
	p.cmd = cmd
	p.udp = udpConn
	p.mu.Unlock()

	go p.forwardRTPToDecoder()
	go p.forwardPCMToRuntime(stdout)

	slog.Info("handler: runtime audio input decoder started",
		"session_id", p.grant.SessionID,
		"runtime_session_id", p.grant.RuntimeSessionID,
		"output_rate", runtimeInputRate,
	)
	return nil
}

func (p *runtimeAudioInputProducer) cleanupStartFailure() {
	if p.cancel != nil {
		p.cancel()
	}
	if p.sdpPath != "" {
		_ = os.Remove(p.sdpPath)
	}
}

func (p *runtimeAudioInputProducer) OnAudioFrame(_ string, source string, packet *rtp.Packet) {
	if source != "customer" || packet == nil {
		return
	}
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	if closed {
		return
	}
	decoderPacket := *packet
	decoderPacket.PayloadType = 111
	raw, err := decoderPacket.Marshal()
	if err != nil {
		slog.Debug("handler: runtime audio input RTP marshal failed",
			"session_id", p.grant.SessionID,
			"runtime_session_id", p.grant.RuntimeSessionID,
			"error", err,
		)
		return
	}
	select {
	case p.input <- raw:
		p.mu.Lock()
		p.pkts++
		pkts := p.pkts
		p.mu.Unlock()
		if pkts == 1 || pkts%200 == 0 {
			slog.Info("handler: runtime audio RTP flowing to AI decoder",
				"session_id", p.grant.SessionID,
				"runtime_session_id", p.grant.RuntimeSessionID,
				"packets", pkts,
			)
		}
	case <-p.ctx.Done():
		return
	default:
		p.mu.Lock()
		p.dropped++
		dropped := p.dropped
		p.mu.Unlock()
		if dropped == 1 || dropped%200 == 0 {
			slog.Warn("handler: runtime audio input RTP dropped",
				"session_id", p.grant.SessionID,
				"runtime_session_id", p.grant.RuntimeSessionID,
				"dropped", dropped,
			)
		}
	}
}

func (p *runtimeAudioInputProducer) forwardRTPToDecoder() {
	for {
		select {
		case <-p.ctx.Done():
			return
		case raw := <-p.input:
			if len(raw) == 0 {
				continue
			}
			p.mu.Lock()
			udp := p.udp
			p.mu.Unlock()
			if udp == nil {
				continue
			}
			if _, err := udp.Write(raw); err != nil {
				slog.Debug("handler: runtime audio input UDP write failed",
					"session_id", p.grant.SessionID,
					"runtime_session_id", p.grant.RuntimeSessionID,
					"error", err,
				)
			}
		}
	}
}

func (p *runtimeAudioInputProducer) forwardPCMToRuntime(stdout io.Reader) {
	buf := make([]byte, 4096)
	pending := make([]byte, 0, runtimeInputFrameBytes*2)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			pending = append(pending, buf[:n]...)
			for len(pending) >= runtimeInputFrameBytes {
				frame := append([]byte(nil), pending[:runtimeInputFrameBytes]...)
				pending = pending[runtimeInputFrameBytes:]
				if err := p.writePCMFrame(frame); err != nil {
					slog.Warn("handler: runtime audio input websocket write failed",
						"session_id", p.grant.SessionID,
						"runtime_session_id", p.grant.RuntimeSessionID,
						"error", err,
					)
					return
				}
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				slog.Debug("handler: runtime audio input decoder ended",
					"session_id", p.grant.SessionID,
					"runtime_session_id", p.grant.RuntimeSessionID,
					"error", err,
				)
			}
			return
		}
	}
}

func (p *runtimeAudioInputProducer) writePCMFrame(frame []byte) error {
	p.wsMu.Lock()
	err := p.ws.WriteJSON(runtimeStreamFrame{
		Type:     runtimeAudioInType,
		Data:     base64.StdEncoding.EncodeToString(frame),
		MimeType: fmt.Sprintf("audio/pcm;rate=%s", runtimeInputRate),
	})
	p.wsMu.Unlock()
	if err != nil {
		return err
	}
	p.mu.Lock()
	p.frames++
	frames := p.frames
	p.mu.Unlock()
	if frames == 1 || frames%200 == 0 {
		slog.Info("handler: runtime audio PCM flowing to AI",
			"session_id", p.grant.SessionID,
			"runtime_session_id", p.grant.RuntimeSessionID,
			"frames", frames,
			"mime_type", fmt.Sprintf("audio/pcm;rate=%s", runtimeInputRate),
		)
	}
	return nil
}

func (p *runtimeAudioInputProducer) PCMFrames() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.frames
}

func (p *runtimeAudioInputProducer) Close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	cancel := p.cancel
	udp := p.udp
	cmd := p.cmd
	sdpPath := p.sdpPath
	p.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if udp != nil {
		_ = udp.Close()
	}
	if cmd != nil && cmd.Process != nil {
		done := make(chan struct{})
		go func() {
			_ = cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			_ = cmd.Process.Kill()
			<-done
		}
	}
	if sdpPath != "" {
		_ = os.Remove(sdpPath)
	}
}

func runtimeInputSDP(port int) string {
	return fmt.Sprintf("v=0\n"+
		"o=- 0 0 IN IP4 127.0.0.1\n"+
		"s=Chatwoot Runtime Input\n"+
		"c=IN IP4 127.0.0.1\n"+
		"t=0 0\n"+
		"m=audio %d RTP/AVP 111\n"+
		"a=rtpmap:111 opus/48000/2\n"+
		"a=fmtp:111 minptime=20;useinbandfec=1\n", port)
}

func runtimeDecodeFFmpegArgs(sdpPath string) []string {
	return []string{
		"-hide_banner",
		"-loglevel", "error",
		"-protocol_whitelist", "file,udp,rtp",
		"-analyzeduration", "0",
		"-probesize", "32",
		"-fflags", "nobuffer",
		"-i", sdpPath,
		"-f", "s16le",
		"-ar", runtimeInputRate,
		"-ac", "1",
		"pipe:1",
	}
}

func runtimeFFmpegArgs(port int) []string {
	return []string{
		"-hide_banner",
		"-loglevel", "error",
		"-analyzeduration", "0",
		"-probesize", "32",
		"-fflags", "nobuffer",
		"-f", "s16le",
		"-ar", runtimeOutputRate,
		"-ac", "1",
		"-i", "pipe:0",
		"-acodec", "libopus",
		"-ar", "48000",
		"-ac", "1",
		"-application", "voip",
		"-frame_duration", "20",
		"-payload_type", "111",
		"-flush_packets", "1",
		"-f", "rtp",
		fmt.Sprintf("rtp://127.0.0.1:%d", port),
	}
}

func (w *runtimeAudioWriter) startLocked() error {
	if w.sess == nil || w.sess.MetaPeer == nil || w.sess.MetaPeer.LocalTrack() == nil {
		return errors.New("meta local track unavailable")
	}

	packetConn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("listen runtime rtp udp: %w", err)
	}
	udpAddr, ok := packetConn.LocalAddr().(*net.UDPAddr)
	if !ok {
		_ = packetConn.Close()
		return errors.New("runtime rtp udp address unavailable")
	}

	ctx, cancel := context.WithCancel(w.ctx)
	cmd := exec.CommandContext(ctx, "ffmpeg", runtimeFFmpegArgs(udpAddr.Port)...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		_ = packetConn.Close()
		return fmt.Errorf("open ffmpeg stdin: %w", err)
	}
	if err := cmd.Start(); err != nil {
		cancel()
		_ = packetConn.Close()
		return fmt.Errorf("start ffmpeg opus encoder: %w", err)
	}

	w.stdin = stdin
	w.conn = packetConn
	w.cmd = cmd

	go func() {
		defer cancel()
		buf := make([]byte, 1600)
		for {
			n, _, err := packetConn.ReadFrom(buf)
			if err != nil {
				return
			}
			if n == 0 {
				continue
			}
			raw := append([]byte(nil), buf[:n]...)
			if _, err := w.sess.MetaPeer.LocalTrack().Write(raw); err != nil {
				slog.Debug("handler: runtime RTP write to Meta failed",
					"session_id", w.grant.SessionID,
					"runtime_session_id", w.grant.RuntimeSessionID,
					"error", err,
				)
				continue
			}
			payloadBytes := n
			var pkt rtp.Packet
			if err := pkt.Unmarshal(raw); err == nil {
				payloadBytes = len(pkt.Payload)
				if w.sess.Recorder != nil {
					if err := w.sess.Recorder.WriteAgentRTP(&pkt); err != nil {
						slog.Warn("handler: failed to record runtime audio",
							"session_id", w.grant.SessionID,
							"runtime_session_id", w.grant.RuntimeSessionID,
							"error", err,
						)
					}
				}
			}
			if w.sess.Bridge != nil {
				w.sess.Bridge.RecordRuntimeAgentPacket(payloadBytes)
			}
			w.mu.Lock()
			w.pkts++
			pkts := w.pkts
			w.mu.Unlock()
			if pkts == 1 || pkts%200 == 0 {
				slog.Info("handler: runtime audio RTP flowing to Meta",
					"session_id", w.grant.SessionID,
					"runtime_session_id", w.grant.RuntimeSessionID,
					"packets", pkts,
				)
			}
		}
	}()

	slog.Info("handler: runtime audio encoder started",
		"session_id", w.grant.SessionID,
		"runtime_session_id", w.grant.RuntimeSessionID,
		"input_rate", runtimeOutputRate,
	)
	return nil
}
