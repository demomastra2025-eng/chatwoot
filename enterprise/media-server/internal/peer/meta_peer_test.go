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

func TestSelectMetaLocalAudioCodecMatchesSipG711Offer(t *testing.T) {
	offer := "v=0\r\n" +
		"m=audio 9 UDP/TLS/RTP/SAVPF 0 8\r\n" +
		"a=rtpmap:0 PCMU/8000\r\n" +
		"a=rtpmap:8 PCMA/8000\r\n"

	codec := selectMetaLocalAudioCodec(offer)
	if codec.MimeType != webrtc.MimeTypePCMU {
		t.Fatalf("expected PCMU for SIP G.711 offer, got %s", codec.MimeType)
	}
	if codec.ClockRate != 8000 {
		t.Fatalf("expected 8kHz PCMU clock, got %d", codec.ClockRate)
	}
}

func TestSelectMetaLocalAudioCodecKeepsOpusForMetaOffer(t *testing.T) {
	offer := "v=0\r\n" +
		"m=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\n" +
		"a=rtpmap:111 opus/48000/2\r\n" +
		"a=rtpmap:0 PCMU/8000\r\n"

	codec := selectMetaLocalAudioCodec(offer)
	if codec.MimeType != webrtc.MimeTypeOpus {
		t.Fatalf("expected Opus when offered first, got %s", codec.MimeType)
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
