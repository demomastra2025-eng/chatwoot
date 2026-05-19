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
	if !stats.BidirectionalReady() {
		t.Fatal("expected bidirectional RTP snapshot to be ready")
	}
}

func TestBridgeSnapshotRequiresBothRTPDirectionsForReadiness(t *testing.T) {
	stats := BridgeSnapshot{AgentToMetaPackets: 10, MetaToAgentPackets: 0}
	if stats.BidirectionalReady() {
		t.Fatal("expected missing Meta->agent RTP to fail readiness")
	}

	stats = BridgeSnapshot{AgentToMetaPackets: 0, MetaToAgentPackets: 10}
	if stats.BidirectionalReady() {
		t.Fatal("expected missing agent->Meta RTP to fail readiness")
	}
}

func TestBridgeAllowsOnlyOneMetaForwarder(t *testing.T) {
	bridge := NewBridge("sess-test", nil, nil)

	if !bridge.beginMetaForwarding() {
		t.Fatal("expected first Meta forwarder to start")
	}
	if bridge.beginMetaForwarding() {
		t.Fatal("expected duplicate Meta forwarder to be rejected")
	}
}

func TestBridgeAllowsOnlyOneAgentForwarderPerPeer(t *testing.T) {
	bridge := NewBridge("sess-test", nil, nil)

	if !bridge.beginAgentForwarding("agent-1") {
		t.Fatal("expected first agent forwarder to start")
	}
	if bridge.beginAgentForwarding("agent-1") {
		t.Fatal("expected duplicate agent forwarder to be rejected")
	}
	if !bridge.beginAgentForwarding("agent-2") {
		t.Fatal("expected different peer to start independently")
	}

	bridge.finishAgentForwarding("agent-1")
	if !bridge.beginAgentForwarding("agent-1") {
		t.Fatal("expected agent forwarder to restart after previous loop ended")
	}
}
