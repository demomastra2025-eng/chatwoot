package session

import (
	"testing"

	"github.com/pion/webrtc/v4"

	"github.com/chatwoot/chatwoot-media-server/internal/peer"
)

func TestSetAgentAnswerReturnsMediaLegClosedWhenSessionTerminated(t *testing.T) {
	sess := &Session{Status: StatusTerminated}

	err := sess.SetAgentAnswer("agent-1", "v=0")

	if !IsMediaLegClosed(err) {
		t.Fatalf("expected media leg closed error, got %v", err)
	}
}

func TestCreateAgentPeerReturnsMediaLegClosedAfterMetaDTLSFailure(t *testing.T) {
	sess := &Session{Status: StatusCreated, MetaDTLSState: webrtc.DTLSTransportStateFailed.String()}

	_, err := sess.CreateAgentPeer("agent-1", "active", nil)

	if !IsMediaLegClosed(err) {
		t.Fatalf("expected media leg closed error, got %v", err)
	}
}

func TestChangeAgentRoleSelectsSingleActivePeer(t *testing.T) {
	sess := &Session{
		AgentPeers: map[string]*peer.AgentPeer{
			"agent-1": {ID: "agent-1", Role: peer.RoleActive},
			"agent-2": {ID: "agent-2", Role: peer.RoleListenOnly},
		},
		SelectedAgentPeerID: "agent-1",
	}

	if err := sess.ChangeAgentRole("agent-2", peer.RoleActive); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if sess.SelectedAgentPeerID != "agent-2" {
		t.Fatalf("expected agent-2 selected, got %q", sess.SelectedAgentPeerID)
	}
	if sess.AgentPeers["agent-1"].Role != peer.RoleListenOnly {
		t.Fatalf("expected previous active peer demoted, got %q", sess.AgentPeers["agent-1"].Role)
	}
	if sess.AgentPeers["agent-2"].Role != peer.RoleActive {
		t.Fatalf("expected agent-2 active, got %q", sess.AgentPeers["agent-2"].Role)
	}
}
