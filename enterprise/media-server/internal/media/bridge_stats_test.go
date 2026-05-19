package media

import "testing"

func TestBridgeSnapshotTracksBidirectionalRTP(t *testing.T) {
	bridge := NewBridge("sess-test", nil, nil)

	bridge.recordMetaPacket(12)
	bridge.recordMetaPacket(8)
	bridge.recordAgentPacket(32)
	bridge.recordAgentPacket(10)

	stats := bridge.Snapshot()
	if stats.MetaToAgentPackets != 2 {
		t.Fatalf("expected 2 Meta->agent packets, got %d", stats.MetaToAgentPackets)
	}
	if stats.MetaToAgentPayloadBytes != 20 {
		t.Fatalf("expected 20 Meta->agent payload bytes, got %d", stats.MetaToAgentPayloadBytes)
	}
	if stats.AgentToMetaPackets != 2 {
		t.Fatalf("expected 2 agent->Meta packets, got %d", stats.AgentToMetaPackets)
	}
	if stats.AgentToMetaPayloadBytes != 42 {
		t.Fatalf("expected 42 agent->Meta payload bytes, got %d", stats.AgentToMetaPayloadBytes)
	}
}
