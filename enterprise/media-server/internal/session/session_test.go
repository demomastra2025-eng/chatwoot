package session

import (
	"testing"

	"github.com/pion/webrtc/v4"
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
