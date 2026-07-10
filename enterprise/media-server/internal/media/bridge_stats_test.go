package media

import (
	"testing"

	"github.com/pion/rtp"
)

type testAudioConsumer struct{}

func (*testAudioConsumer) OnAudioFrame(string, string, *rtp.Packet) {}

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

func TestBridgeSnapshotCountsRuntimeAgentAudioAsAgentToMeta(t *testing.T) {
	bridge := NewBridge("sess-runtime", nil, nil)
	bridge.recordMetaPacket(20)
	bridge.RecordRuntimeAgentPacket(40)

	stats := bridge.Snapshot()
	if stats.AgentToMetaPackets != 1 {
		t.Fatalf("expected runtime AI audio to count as agent->Meta RTP, got %d", stats.AgentToMetaPackets)
	}
	if stats.AgentToMetaPayloadBytes != 40 {
		t.Fatalf("expected runtime AI payload bytes, got %d", stats.AgentToMetaPayloadBytes)
	}
	if !stats.BidirectionalReady() {
		t.Fatal("expected runtime AI call with customer RTP and AI RTP to be media-ready")
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

func TestBridgeRemovesRuntimeAudioConsumer(t *testing.T) {
	bridge := NewBridge("sess-test", nil, nil)
	consumer := &testAudioConsumer{}

	bridge.AddConsumer(consumer)
	bridge.RemoveConsumer(consumer)

	if len(bridge.consumers) != 0 {
		t.Fatalf("consumer count = %d, want 0", len(bridge.consumers))
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
