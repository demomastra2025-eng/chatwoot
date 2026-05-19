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
