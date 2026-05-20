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
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/chatwoot/chatwoot-media-server/internal/session"
)

const (
	runtimeAudioOutType = "AUDIO_OUT"
	runtimeOutputRate   = "8000"
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

	slog.Info("handler: runtime stream websocket connected",
		"session_id", grant.SessionID,
		"runtime_session_id", grant.RuntimeSessionID,
		"call_ref", grant.CallRef,
		"account_id", grant.AccountID,
	)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	writer := newRuntimeAudioWriter(ctx, sess, grant)
	defer writer.Close()

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
	)
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
	cmd := exec.CommandContext(ctx, "ffmpeg",
		"-hide_banner",
		"-loglevel", "error",
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
		"-f", "rtp",
		fmt.Sprintf("rtp://127.0.0.1:%d", udpAddr.Port),
	)
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
