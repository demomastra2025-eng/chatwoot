package server

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/chatwoot/chatwoot-media-server/internal/config"
	"github.com/chatwoot/chatwoot-media-server/internal/media"
	"github.com/chatwoot/chatwoot-media-server/internal/peer"
	"github.com/chatwoot/chatwoot-media-server/internal/session"
)

// maxRequestBodySize limits JSON request bodies to 1MB to prevent memory exhaustion.
const maxRequestBodySize = 1 << 20

// startTime is set at server startup for uptime calculations.
var startTime = time.Now()

// Handlers implements all HTTP API endpoint handlers for the media server.
type Handlers struct {
	cfg                 *config.Config
	manager             *session.Manager
	runtimeStreamGrants sync.Map
}

// NewHandlers creates a new Handlers instance backed by the given session
// manager and configuration.
func NewHandlers(cfg *config.Config, mgr *session.Manager) *Handlers {
	return &Handlers{cfg: cfg, manager: mgr}
}

// --- Request/Response types ---

// CreateSessionRequest is the JSON body for POST /sessions.
type CreateSessionRequest struct {
	CallID       string            `json:"call_id"`
	AccountID    string            `json:"account_id"`
	Direction    string            `json:"direction"`
	MetaSDPOffer string            `json:"meta_sdp_offer"`
	ICEServers   []ICEServerConfig `json:"ice_servers"`
}

// ICEServerConfig mirrors webrtc.ICEServer for JSON deserialization.
type ICEServerConfig struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// CreateSessionResponse is the JSON response for POST /sessions.
type CreateSessionResponse struct {
	SessionID     string `json:"session_id"`
	MetaSDPAnswer string `json:"meta_sdp_answer,omitempty"`
	MetaSDPOffer  string `json:"meta_sdp_offer,omitempty"`
	Status        string `json:"status"`
}

// AgentOfferRequest is the JSON body for POST /sessions/:id/agent-offer.
type AgentOfferRequest struct {
	PeerID     string            `json:"peer_id"`
	Role       string            `json:"role"`
	ICEServers []ICEServerConfig `json:"ice_servers"`
}

// AgentOfferResponse is the JSON response for POST /sessions/:id/agent-offer.
type AgentOfferResponse struct {
	SDPOffer   string            `json:"sdp_offer"`
	PeerID     string            `json:"peer_id"`
	ICEServers []ICEServerConfig `json:"ice_servers"`
}

// AgentAnswerRequest is the JSON body for POST /sessions/:id/agent-answer.
type AgentAnswerRequest struct {
	PeerID    string `json:"peer_id"`
	SDPAnswer string `json:"sdp_answer"`
}

// MetaAnswerRequest is the JSON body for POST /sessions/:id/meta-answer.
// Used for outgoing calls to deliver Meta's SDP answer to the media server
// so it can complete the Peer A (Meta-side) WebRTC handshake.
type MetaAnswerRequest struct {
	SDPAnswer string `json:"sdp_answer"`
}

// AgentAnswerResponse is the JSON response for POST /sessions/:id/agent-answer.
type AgentAnswerResponse struct {
	Status    string `json:"status"`
	Recording bool   `json:"recording"`
}

// AgentReconnectRequest is the JSON body for POST /sessions/:id/agent-reconnect.
type AgentReconnectRequest struct {
	OldPeerID  string            `json:"old_peer_id"`
	NewPeerID  string            `json:"new_peer_id"`
	Role       string            `json:"role"`
	ICEServers []ICEServerConfig `json:"ice_servers"`
}

// AgentReconnectResponse is the JSON response for POST /sessions/:id/agent-reconnect.
type AgentReconnectResponse struct {
	SDPOffer   string            `json:"sdp_offer"`
	PeerID     string            `json:"peer_id"`
	ICEServers []ICEServerConfig `json:"ice_servers"`
}

// TerminateResponse is the JSON response for POST /sessions/:id/terminate.
type TerminateResponse struct {
	Status             string `json:"status"`
	RecordingFile      string `json:"recording_file,omitempty"`
	RecordingSizeBytes int64  `json:"recording_size_bytes,omitempty"`
	DurationSeconds    int    `json:"duration_seconds"`
}

// AddPeerRequest is the JSON body for POST /sessions/:id/peers.
type AddPeerRequest struct {
	PeerID     string            `json:"peer_id"`
	Role       string            `json:"role"`
	ICEServers []ICEServerConfig `json:"ice_servers"`
}

// ChangePeerRoleRequest is the JSON body for PATCH /sessions/:id/peers/:peer_id/role.
type ChangePeerRoleRequest struct {
	Role string `json:"role"`
}

// InjectAudioRequest is the JSON body for POST /sessions/:id/inject-audio.
type InjectAudioRequest struct {
	ID     string `json:"id"`
	Source string `json:"source"`
	Mode   string `json:"mode"`
	Target string `json:"target"`
	Loop   bool   `json:"loop"`
}

// RuntimeAgentRequest is the JSON body for POST /sessions/:id/runtime-agent.
type RuntimeAgentRequest struct {
	CallRef        string `json:"call_ref"`
	AccountID      string `json:"account_id"`
	ConversationID string `json:"conversation_id"`
	InboxID        string `json:"inbox_id"`
}

// RuntimeAgentResponse is the attach contract for the AI voice runtime.
type RuntimeAgentResponse struct {
	RuntimeSessionID string    `json:"runtime_session_id"`
	StreamURL        string    `json:"stream_url"`
	Codec            string    `json:"codec"`
	InputSampleRate  int       `json:"input_sample_rate"`
	OutputSampleRate int       `json:"output_sample_rate"`
	ExpiresAt        time.Time `json:"expires_at"`
}

type runtimeStreamGrant struct {
	SessionID        string
	RuntimeSessionID string
	Token            string
	CallRef          string
	AccountID        string
	ConversationID   string
	InboxID          string
	ExpiresAt        time.Time
	Consumed         bool
	ConsumedAt       time.Time
}

// HealthResponse is the JSON response for GET /health.
type HealthResponse struct {
	Status         string `json:"status"`
	ActiveSessions int    `json:"active_sessions"`
	UptimeSeconds  int    `json:"uptime_seconds"`
}

// --- Handlers ---

// Health returns the server's health status. This endpoint does not require
// authentication and is used by container orchestrators for liveness checks.
func (h *Handlers) Health(w http.ResponseWriter, r *http.Request) {
	metrics := h.manager.GetMetrics()
	writeJSON(w, http.StatusOK, HealthResponse{
		Status:         "ok",
		ActiveSessions: metrics.ActiveSessions,
		UptimeSeconds:  int(time.Since(startTime).Seconds()),
	})
}

// Metrics returns Prometheus-compatible metrics about the media server.
func (h *Handlers) Metrics(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.manager.GetMetrics())
}

// CreateSession handles POST /sessions. It creates a new call session with a
// Meta-side peer connection and returns the SDP answer (for incoming calls)
// or SDP offer (for outgoing calls).
func (h *Handlers) CreateSession(w http.ResponseWriter, r *http.Request) {
	var req CreateSessionRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.CallID == "" {
		writeError(w, http.StatusBadRequest, "call_id is required")
		return
	}
	if req.Direction != "incoming" && req.Direction != "outgoing" {
		writeError(w, http.StatusBadRequest, "direction must be 'incoming' or 'outgoing'")
		return
	}

	iceServers := toWebRTCICEServers(req.ICEServers, h.cfg)

	sess, sdpResult, err := h.manager.CreateSession(req.CallID, req.AccountID, req.Direction, req.MetaSDPOffer, iceServers)
	if err != nil {
		slog.Error("handler: failed to create session",
			"call_id", req.CallID,
			"error", err,
		)
		writeError(w, http.StatusInternalServerError, "failed to create session: "+err.Error())
		return
	}

	resp := CreateSessionResponse{
		SessionID: sess.ID,
		Status:    string(sess.Status),
	}
	if req.Direction == "incoming" {
		resp.MetaSDPAnswer = sdpResult
	} else {
		resp.MetaSDPOffer = sdpResult
	}

	slog.Info("handler: session created",
		"session_id", sess.ID,
		"call_id", req.CallID,
		"direction", req.Direction,
	)

	writeJSON(w, http.StatusCreated, resp)
}

// GetSession handles GET /sessions/{id}. It returns the current status of
// a call session.
func (h *Handlers) GetSession(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	writeJSON(w, http.StatusOK, sess.GetInfo())
}

// RuntimeAgent handles POST /sessions/{id}/runtime-agent. It reserves a
// short-lived, one-time media stream attach contract for the AI voice runtime.
func (h *Handlers) RuntimeAgent(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	if h.manager != nil && h.manager.GetSession(sessionID) == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	var req RuntimeAgentRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}
	if strings.TrimSpace(req.CallRef) == "" || strings.TrimSpace(req.AccountID) == "" {
		writeError(w, http.StatusBadRequest, "call_ref and account_id are required")
		return
	}

	resp, err := h.buildRuntimeAgentContract(sessionID, req, r.Host)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create runtime agent contract")
		return
	}

	slog.Info("handler: runtime agent contract created",
		"session_id", sessionID,
		"call_ref", req.CallRef,
		"account_id", req.AccountID,
		"runtime_session_id", resp.RuntimeSessionID,
	)
	writeJSON(w, http.StatusCreated, resp)
}

// RuntimeStream is the authenticated-by-token WebSocket endpoint for the
// transport-neutral AI voice runtime stream. It consumes the one-time grant and
// bridges runtime AUDIO_OUT frames to Meta as Opus/RTP.
func (h *Handlers) RuntimeStream(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	token := strings.TrimSpace(r.URL.Query().Get("token"))
	grant, ok, status, message := h.validateRuntimeStreamGrant(sessionID, token)
	if !ok {
		writeError(w, status, message)
		return
	}

	h.serveRuntimeStream(w, r, grant)
}

// AgentOffer handles POST /sessions/{id}/agent-offer. It creates a new
// agent-side peer connection and returns the SDP offer to send to the
// agent's browser.
func (h *Handlers) AgentOffer(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeCodedError(w, http.StatusNotFound, "media_session_closed", "session not found")
		return
	}

	var req AgentOfferRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.PeerID == "" {
		req.PeerID = fmt.Sprintf("agent_%d", time.Now().UnixNano())
	}

	role := peer.RoleActive
	if req.Role != "" {
		role = peer.PeerRole(req.Role)
	}

	iceServers := toWebRTCICEServers(req.ICEServers, h.cfg)

	sdpOffer, err := sess.CreateAgentPeer(req.PeerID, role, iceServers)
	if err != nil {
		slog.Error("handler: failed to create agent peer",
			"session_id", sessionID,
			"error", err,
		)
		if session.IsMediaLegClosed(err) {
			writeCodedError(w, http.StatusConflict, "media_leg_closed", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to create agent peer: "+err.Error())
		return
	}

	slog.Info("handler: agent offer created",
		"session_id", sessionID,
		"peer_id", req.PeerID,
	)

	writeJSON(w, http.StatusOK, AgentOfferResponse{
		SDPOffer:   sdpOffer,
		PeerID:     req.PeerID,
		ICEServers: req.ICEServers,
	})
}

// AgentAnswer handles POST /sessions/{id}/agent-answer. It sets the agent's
// SDP answer on the peer connection, completing the WebRTC handshake and
// enabling audio bridging.
func (h *Handlers) AgentAnswer(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeCodedError(w, http.StatusNotFound, "media_session_closed", "session not found")
		return
	}

	var req AgentAnswerRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.SDPAnswer == "" {
		writeError(w, http.StatusBadRequest, "sdp_answer is required")
		return
	}
	// When peer_id is omitted (single-agent sessions), fall back to the only
	// agent peer attached to the session. Rails doesn't currently surface
	// peer_id through ActionCable, so browsers just send the SDP answer.
	if req.PeerID == "" {
		if only, ok := sess.SoleAgentPeerID(); ok {
			req.PeerID = only
		} else {
			writeError(w, http.StatusBadRequest, "peer_id is required (session has multiple agent peers)")
			return
		}
	}

	if err := sess.SetAgentAnswer(req.PeerID, req.SDPAnswer); err != nil {
		slog.Error("handler: failed to set agent answer",
			"session_id", sessionID,
			"peer_id", req.PeerID,
			"error", err,
		)
		if session.IsMediaLegClosed(err) {
			writeCodedError(w, http.StatusConflict, "media_leg_closed", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to set agent answer: "+err.Error())
		return
	}

	slog.Info("handler: agent answer set",
		"session_id", sessionID,
		"peer_id", req.PeerID,
	)

	writeJSON(w, http.StatusOK, AgentAnswerResponse{
		Status:    "bridged",
		Recording: true,
	})
}

// MetaAnswer handles POST /sessions/{id}/meta-answer. It sets Meta's SDP
// answer on the Meta-side peer connection for outbound calls.
func (h *Handlers) MetaAnswer(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	var req MetaAnswerRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}
	if req.SDPAnswer == "" {
		writeError(w, http.StatusBadRequest, "sdp_answer is required")
		return
	}

	if err := sess.SetMetaAnswer(req.SDPAnswer); err != nil {
		slog.Error("handler: failed to set meta answer",
			"session_id", sessionID,
			"error", err,
		)
		writeError(w, http.StatusInternalServerError, "failed to set meta answer: "+err.Error())
		return
	}

	slog.Info("handler: meta answer set", "session_id", sessionID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// AgentReconnect handles POST /sessions/{id}/agent-reconnect. It tears down
// the old agent peer and creates a new one, returning a fresh SDP offer.
func (h *Handlers) AgentReconnect(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	var req AgentReconnectRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.NewPeerID == "" {
		req.NewPeerID = fmt.Sprintf("agent_%d", time.Now().UnixNano())
	}

	role := peer.RoleActive
	if req.Role != "" {
		role = peer.PeerRole(req.Role)
	}

	iceServers := toWebRTCICEServers(req.ICEServers, h.cfg)

	sdpOffer, err := sess.ReconnectAgent(req.OldPeerID, req.NewPeerID, role, iceServers)
	if err != nil {
		slog.Error("handler: failed to reconnect agent",
			"session_id", sessionID,
			"error", err,
		)
		writeError(w, http.StatusInternalServerError, "failed to reconnect agent: "+err.Error())
		return
	}

	slog.Info("handler: agent reconnect complete",
		"session_id", sessionID,
		"old_peer_id", req.OldPeerID,
		"new_peer_id", req.NewPeerID,
	)

	writeJSON(w, http.StatusOK, AgentReconnectResponse{
		SDPOffer:   sdpOffer,
		PeerID:     req.NewPeerID,
		ICEServers: req.ICEServers,
	})
}

// TerminateSession handles POST /sessions/{id}/terminate. It ends the call,
// closes all peer connections, and finalizes the recording.
func (h *Handlers) TerminateSession(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeJSON(w, http.StatusOK, TerminateResponse{Status: "terminated"})
		return
	}

	info := sess.GetInfo()
	if err := h.manager.TerminateSession(sessionID, "api_request"); err != nil {
		writeJSON(w, http.StatusOK, TerminateResponse{Status: "terminated"})
		return
	}

	resp := TerminateResponse{
		Status:          "terminated",
		DurationSeconds: info.DurationSeconds,
	}

	if sess.Recorder != nil {
		resp.RecordingFile = sess.RecordingFilePath()
		resp.RecordingSizeBytes = sess.Recorder.FileSize()
	}

	slog.Info("handler: session terminated",
		"session_id", sessionID,
		"duration", info.DurationSeconds,
	)

	writeJSON(w, http.StatusOK, resp)
}

// GetRecording handles GET /sessions/{id}/recording. It serves the combined
// recording file as a binary OGG download. An optional ?side=customer|agent
// query parameter returns the per-direction recording instead, which Rails
// uses to produce speaker-separated transcripts. Falls back to looking the
// files up on disk when the session has already been terminated and removed
// from the in-memory manager — Rails typically fetches per-side recordings
// shortly after calling terminate.
func (h *Handlers) GetRecording(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	side := r.URL.Query().Get("side")

	filePath, filename := h.resolveRecordingPath(sessionID, side)

	if filePath == "" {
		writeError(w, http.StatusNotFound, "no recording available")
		return
	}

	f, err := os.Open(filePath)
	if err != nil {
		writeError(w, http.StatusNotFound, "recording file not found")
		return
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to stat recording file")
		return
	}

	w.Header().Set("Content-Type", "audio/ogg")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	http.ServeContent(w, r, filePath, stat.ModTime(), f)
}

// resolveRecordingPath returns the filesystem path + download filename for a
// session's recording. It prefers the live session's recorder (for sessions
// still in memory) and falls back to deterministic on-disk paths so Rails can
// download recordings even after the session was terminated and evicted from
// the manager.
func (h *Handlers) resolveRecordingPath(sessionID, side string) (string, string) {
	var suffix, filename string
	switch side {
	case "customer":
		suffix = "_customer.ogg"
	case "agent":
		suffix = "_agent.ogg"
	default:
		suffix = ".ogg"
	}
	filename = sessionID + suffix

	if sess := h.manager.GetSession(sessionID); sess != nil {
		switch side {
		case "customer":
			return sess.RecorderCustomerPath(), filename
		case "agent":
			return sess.RecorderAgentPath(), filename
		default:
			return sess.RecordingFilePath(), filename
		}
	}

	diskPath := filepath.Join(h.cfg.RecordingsDir, filename)
	if _, err := os.Stat(diskPath); err == nil {
		return diskPath, filename
	}
	return "", filename
}

// DeleteSession handles DELETE /sessions/{id}. It terminates the session and
// removes all associated recording files.
func (h *Handlers) DeleteSession(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	if err := h.manager.DeleteSession(sessionID); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	slog.Info("handler: session deleted", "session_id", sessionID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// AddPeer handles POST /sessions/{id}/peers. It adds a new participant peer
// to an existing session (multi-participant support).
func (h *Handlers) AddPeer(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	var req AddPeerRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.PeerID == "" {
		req.PeerID = fmt.Sprintf("peer_%d", time.Now().UnixNano())
	}

	role := peer.RoleActive
	if req.Role != "" {
		role = peer.PeerRole(req.Role)
	}

	iceServers := toWebRTCICEServers(req.ICEServers, h.cfg)

	sdpOffer, err := sess.CreateAgentPeer(req.PeerID, role, iceServers)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to add peer: "+err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, AgentOfferResponse{
		SDPOffer:   sdpOffer,
		PeerID:     req.PeerID,
		ICEServers: req.ICEServers,
	})
}

// RemovePeer handles DELETE /sessions/{id}/peers/{peer_id}. It removes a
// specific participant from the session.
func (h *Handlers) RemovePeer(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	peerID := r.PathValue("peer_id")

	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	if err := sess.RemoveAgentPeer(peerID); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "removed"})
}

// ChangePeerRole handles PATCH /sessions/{id}/peers/{peer_id}/role. It
// changes the role of a connected participant.
func (h *Handlers) ChangePeerRole(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	peerID := r.PathValue("peer_id")

	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	var req ChangePeerRoleRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if err := sess.ChangeAgentRole(peerID, peer.PeerRole(req.Role)); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated", "role": req.Role})
}

// InjectAudio handles POST /sessions/{id}/inject-audio. It starts playing
// an audio file into the call's RTP stream.
func (h *Handlers) InjectAudio(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	var req InjectAudioRequest
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.ID == "" {
		req.ID = fmt.Sprintf("inj_%d", time.Now().UnixNano())
	}
	if req.Mode == "" {
		req.Mode = "replace"
	}
	if req.Target == "" {
		req.Target = "meta"
	}

	source, err := h.resolveAudioSource(req.Source)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	injector := media.NewInjector(req.ID, source, req.Mode, req.Target, req.Loop)

	// Determine the target track based on the target parameter.
	target := sess.GetInjectorTarget(req.Target)
	if target == nil {
		writeError(w, http.StatusBadRequest, "target track not available")
		return
	}

	if err := injector.Start(target); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to start injection: "+err.Error())
		return
	}

	sess.AddInjector(req.ID, injector)

	writeJSON(w, http.StatusCreated, map[string]string{
		"id":     req.ID,
		"status": "started",
	})
}

// StopInjectAudio handles DELETE /sessions/{id}/inject-audio/{inj_id}. It
// stops an active audio injection.
func (h *Handlers) StopInjectAudio(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	injID := r.PathValue("inj_id")

	sess := h.manager.GetSession(sessionID)
	if sess == nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	if err := sess.StopInjector(injID); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped"})
}

// --- Helpers ---

func (h *Handlers) resolveAudioSource(source string) (string, error) {
	source = strings.TrimSpace(source)
	if source == "" {
		return "", fmt.Errorf("source is required")
	}
	if h.cfg.AudioDir == "" {
		return "", fmt.Errorf("audio directory is not configured")
	}
	if filepath.IsAbs(source) || strings.Contains(source, "\\") || strings.Contains(source, ":") {
		return "", fmt.Errorf("audio source must be a relative path inside the configured audio directory")
	}

	base, err := filepath.Abs(filepath.Clean(h.cfg.AudioDir))
	if err != nil {
		return "", fmt.Errorf("invalid audio directory")
	}

	candidate := filepath.Join(base, source)
	candidate, err = filepath.Abs(filepath.Clean(candidate))
	if err != nil {
		return "", fmt.Errorf("invalid audio source")
	}

	rel, err := filepath.Rel(base, candidate)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("audio source must be inside the configured audio directory")
	}
	if strings.ToLower(filepath.Ext(candidate)) != ".ogg" {
		return "", fmt.Errorf("audio source must be an .ogg file")
	}

	candidate, err = filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", fmt.Errorf("audio source not found")
	}
	candidate, err = filepath.Abs(filepath.Clean(candidate))
	if err != nil {
		return "", fmt.Errorf("invalid audio source")
	}
	rel, err = filepath.Rel(base, candidate)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("audio source must be inside the configured audio directory")
	}
	if strings.ToLower(filepath.Ext(candidate)) != ".ogg" {
		return "", fmt.Errorf("audio source must be an .ogg file")
	}

	stat, err := os.Stat(candidate)
	if err != nil {
		return "", fmt.Errorf("audio source not found")
	}
	if stat.IsDir() {
		return "", fmt.Errorf("audio source must be a file")
	}

	return candidate, nil
}

func readJSON(r *http.Request, v any) error {
	defer r.Body.Close()
	limited := io.LimitReader(r.Body, maxRequestBodySize)
	err := json.NewDecoder(limited).Decode(v)
	// Tolerate empty bodies — handlers with all-optional fields treat this
	// as "use defaults" rather than failing.
	if err == io.EOF {
		return nil
	}
	return err
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func writeCodedError(w http.ResponseWriter, status int, code string, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg, "code": code, "status": code})
}

func (h *Handlers) buildRuntimeAgentContract(sessionID string, req RuntimeAgentRequest, host string) (RuntimeAgentResponse, error) {
	token, err := randomURLToken(32)
	if err != nil {
		return RuntimeAgentResponse{}, err
	}

	expiresAt := time.Now().UTC().Add(60 * time.Second)
	if strings.TrimSpace(host) == "" {
		host = "localhost:4000"
	}
	runtimeSessionID := fmt.Sprintf("rt_%s_%d", sessionID, time.Now().UnixNano())
	h.storeRuntimeStreamGrant(runtimeStreamGrant{
		SessionID:        sessionID,
		RuntimeSessionID: runtimeSessionID,
		Token:            token,
		CallRef:          strings.TrimSpace(req.CallRef),
		AccountID:        strings.TrimSpace(req.AccountID),
		ConversationID:   strings.TrimSpace(req.ConversationID),
		InboxID:          strings.TrimSpace(req.InboxID),
		ExpiresAt:        expiresAt,
	})

	return RuntimeAgentResponse{
		RuntimeSessionID: runtimeSessionID,
		StreamURL:        fmt.Sprintf("ws://%s/sessions/%s/runtime-stream?token=%s", host, sessionID, token),
		Codec:            "pcm_s16le",
		InputSampleRate:  16000,
		OutputSampleRate: 8000,
		ExpiresAt:        expiresAt,
	}, nil
}

func (h *Handlers) storeRuntimeStreamGrant(grant runtimeStreamGrant) {
	if strings.TrimSpace(grant.Token) == "" {
		return
	}
	h.cleanupRuntimeStreamGrants(time.Now().UTC())
	h.runtimeStreamGrants.Store(grant.Token, grant)
}

func (h *Handlers) validateRuntimeStreamGrant(sessionID string, token string) (runtimeStreamGrant, bool, int, string) {
	h.cleanupRuntimeStreamGrants(time.Now().UTC())
	return h.runtimeStreamGrant(sessionID, token)
}

func (h *Handlers) consumeRuntimeStreamGrant(sessionID string, token string) (runtimeStreamGrant, bool, int, string) {
	h.cleanupRuntimeStreamGrants(time.Now().UTC())
	grant, ok, status, message := h.runtimeStreamGrant(sessionID, token)
	if !ok {
		return runtimeStreamGrant{}, false, status, message
	}

	consumedGrant := grant
	consumedGrant.Consumed = true
	consumedGrant.ConsumedAt = time.Now().UTC()
	if !h.runtimeStreamGrants.CompareAndSwap(token, grant, consumedGrant) {
		return runtimeStreamGrant{}, false, http.StatusConflict, "runtime stream token already consumed"
	}

	slog.Info("handler: runtime stream grant consumed",
		"session_id", sessionID,
		"runtime_session_id", grant.RuntimeSessionID,
		"call_ref", grant.CallRef,
		"account_id", grant.AccountID,
	)
	return consumedGrant, true, http.StatusOK, ""
}

func (h *Handlers) runtimeStreamGrant(sessionID string, token string) (runtimeStreamGrant, bool, int, string) {
	if strings.TrimSpace(token) == "" {
		return runtimeStreamGrant{}, false, http.StatusUnauthorized, "runtime stream token is required"
	}

	value, ok := h.runtimeStreamGrants.Load(token)
	if !ok {
		return runtimeStreamGrant{}, false, http.StatusUnauthorized, "runtime stream token is invalid"
	}
	grant, ok := value.(runtimeStreamGrant)
	if !ok {
		h.runtimeStreamGrants.Delete(token)
		return runtimeStreamGrant{}, false, http.StatusUnauthorized, "runtime stream token is invalid"
	}
	if grant.SessionID != sessionID {
		return runtimeStreamGrant{}, false, http.StatusUnauthorized, "runtime stream token is scoped to another session"
	}
	if time.Now().UTC().After(grant.ExpiresAt) {
		h.runtimeStreamGrants.Delete(token)
		return runtimeStreamGrant{}, false, http.StatusGone, "runtime stream token expired"
	}
	if grant.Consumed {
		return runtimeStreamGrant{}, false, http.StatusConflict, "runtime stream token already consumed"
	}
	return grant, true, http.StatusOK, ""
}

func (h *Handlers) cleanupRuntimeStreamGrants(now time.Time) {
	h.runtimeStreamGrants.Range(func(key, value any) bool {
		grant, ok := value.(runtimeStreamGrant)
		if !ok {
			h.runtimeStreamGrants.Delete(key)
			return true
		}
		if grant.Consumed && !grant.ConsumedAt.IsZero() && now.Sub(grant.ConsumedAt) > time.Minute {
			h.runtimeStreamGrants.Delete(key)
		}
		return true
	})
}

func randomURLToken(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// toWebRTCICEServers converts the request ICE server configs to Pion's
// ICEServer type, merging with any STUN/TURN servers from the global config.
func toWebRTCICEServers(reqServers []ICEServerConfig, cfg *config.Config) []webrtc.ICEServer {
	servers := make([]webrtc.ICEServer, 0, len(reqServers)+2)

	// Add request-provided servers.
	for _, s := range reqServers {
		server := webrtc.ICEServer{URLs: s.URLs}
		if s.Username != "" {
			server.Username = s.Username
			server.Credential = s.Credential
			server.CredentialType = webrtc.ICECredentialTypePassword
		}
		servers = append(servers, server)
	}

	// Add global STUN servers if no STUN was provided in the request.
	hasSTUN := false
	for _, s := range reqServers {
		for _, u := range s.URLs {
			if strings.HasPrefix(u, "stun:") {
				hasSTUN = true
				break
			}
		}
	}
	if !hasSTUN && len(cfg.STUNServers) > 0 {
		servers = append(servers, webrtc.ICEServer{URLs: cfg.STUNServers})
	}

	// Add global TURN servers.
	if len(cfg.TURNServers) > 0 && cfg.TURNUsername != "" {
		servers = append(servers, webrtc.ICEServer{
			URLs:           cfg.TURNServers,
			Username:       cfg.TURNUsername,
			Credential:     cfg.TURNPassword,
			CredentialType: webrtc.ICECredentialTypePassword,
		})
	}

	return servers
}
