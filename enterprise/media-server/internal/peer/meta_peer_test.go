package peer

import (
	"testing"

	"github.com/pion/webrtc/v4"
)

func TestIncomingMetaPeerUsesClientDTLSRole(t *testing.T) {
	if got := metaAnsweringDTLSRole(); got != webrtc.DTLSRoleClient {
		t.Fatalf("expected incoming Meta answer to use DTLS client/active role, got %v", got)
	}
}

func TestMetaPeerOnTrackReadyReplaysAlreadyReceivedTrack(t *testing.T) {
	track := &webrtc.TrackRemote{}
	metaPeer := &MetaPeer{audioTrack: track}

	called := false
	metaPeer.OnTrackReady(func(receivedTrack *webrtc.TrackRemote) {
		called = true
		if receivedTrack != track {
			t.Fatalf("expected existing track to be replayed")
		}
	})

	if !called {
		t.Fatal("expected OnTrackReady to fire when Meta track was already available")
	}
}

func TestAgentPeerOnTrackReadyReplaysAlreadyReceivedTrack(t *testing.T) {
	track := &webrtc.TrackRemote{}
	agentPeer := &AgentPeer{audioTrack: track}

	called := false
	agentPeer.OnTrackReady(func(receivedTrack *webrtc.TrackRemote) {
		called = true
		if receivedTrack != track {
			t.Fatalf("expected existing agent track to be replayed")
		}
	})

	if !called {
		t.Fatal("expected OnTrackReady to fire when agent track was already available")
	}
}
