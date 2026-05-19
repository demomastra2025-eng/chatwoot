import { describe, it, beforeEach, expect, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import {
  acceptWhatsappCallById,
  handleAgentOffer,
  WHATSAPP_CALL_MEDIA_LEG_CLOSED_MESSAGE,
} from '../useWhatsappCallSession';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import { emitter } from 'shared/helpers/mitt';

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    emit: vi.fn(),
  },
}));

vi.mock('dashboard/api/auth', () => ({
  default: {
    hasAuthCookie: vi.fn(() => false),
    getAuthData: vi.fn(() => ({})),
  },
}));

vi.mock('dashboard/api/whatsappCalls', () => ({
  default: {
    show: vi.fn(),
    accept: vi.fn(),
    agentAnswer: vi.fn(),
  },
}));

class FakeRTCPeerConnection {
  constructor() {
    this.localDescription = { sdp: 'agent-answer-sdp' };
    this.iceGatheringState = 'complete';
    this.ontrack = null;
    this.onicecandidate = null;
  }

  addTrack = vi.fn();

  setRemoteDescription = vi.fn(async () => Promise.resolve());

  createAnswer = vi.fn(async () => ({
    type: 'answer',
    sdp: 'agent-answer-sdp',
  }));

  setLocalDescription = vi.fn(async answer => {
    this.localDescription = answer;
  });

  close = vi.fn();
}

describe('useWhatsappCallSession', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    vi.spyOn(console, 'info').mockImplementation(() => {});

    Object.defineProperty(global.navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: vi.fn().mockResolvedValue({
          getTracks: () => [{ stop: vi.fn() }],
        }),
      },
    });

    global.RTCPeerConnection = FakeRTCPeerConnection;
  });

  it('prewarms server-relay inbound microphone in parallel with accept request', async () => {
    let resolveMedia;
    navigator.mediaDevices.getUserMedia.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveMedia = resolve;
        })
    );

    let resolveAccept;
    WhatsappCallsAPI.show.mockResolvedValue({
      data: {
        id: 46,
        call_id: 'wacid-46',
        status: 'ringing',
        direction: 'incoming',
        inbox_id: 57,
        conversation_id: 13746,
        conversation_display_id: 484,
        media_server_enabled: true,
        caller: { name: 'Ahan' },
      },
    });
    WhatsappCallsAPI.accept.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveAccept = resolve;
        })
    );
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    const resultPromise = acceptWhatsappCallById(46);
    await Promise.resolve();
    await Promise.resolve();

    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledWith({
      audio: true,
    });
    expect(WhatsappCallsAPI.accept).toHaveBeenCalledWith(46);
    expect(
      navigator.mediaDevices.getUserMedia.mock.invocationCallOrder[0]
    ).toBeLessThan(WhatsappCallsAPI.accept.mock.invocationCallOrder[0]);

    resolveAccept({
      data: {
        id: 46,
        status: 'in_progress',
        media_session_id: 'sess-46',
        agent_offer: {
          sdp_offer: 'agent-offer-sdp',
          ice_servers: [],
        },
      },
    });
    await Promise.resolve();
    resolveMedia({ getTracks: () => [{ stop: vi.fn() }] });

    const result = await resultPromise;
    expect(result.success).toBe(true);
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      46,
      'agent-answer-sdp',
      expect.objectContaining({
        direction: 'incoming',
        context: 'accept-response',
        stages: expect.any(Object),
      })
    );
  });

  it('completes server-relay browser handshake from accept response even if ActionCable agent_offer was missed', async () => {
    WhatsappCallsAPI.show.mockResolvedValue({
      data: {
        id: 42,
        call_id: 'wacid-42',
        status: 'ringing',
        direction: 'incoming',
        inbox_id: 57,
        conversation_id: 13743,
        conversation_display_id: 481,
        media_server_enabled: true,
        caller: { name: 'Ahan' },
      },
    });
    WhatsappCallsAPI.accept.mockResolvedValue({
      data: {
        id: 42,
        status: 'in_progress',
        media_session_id: 'sess-42',
        agent_offer: {
          sdp_offer: 'agent-offer-sdp',
          ice_servers: [],
        },
      },
    });
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    const result = await acceptWhatsappCallById(42);
    const callsStore = useWhatsappCallsStore();

    expect(result.success).toBe(true);
    expect(callsStore.activeCall).toMatchObject({
      id: 42,
      callId: 'wacid-42',
      conversationId: 13743,
      conversationDisplayId: 481,
      serverRelay: true,
      status: 'connected',
      agentWebrtcConnected: true,
      agentWebrtcConnecting: false,
    });
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      42,
      'agent-answer-sdp',
      expect.objectContaining({
        direction: 'incoming',
        context: 'accept-response',
        stages: expect.any(Object),
      })
    );
    expect(emitter.emit).toHaveBeenCalledWith(
      'whatsapp_call:agent_webrtc_connected'
    );
  });

  it('keeps an accepted server-relay call active when local agent WebRTC answer fails', async () => {
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});
    WhatsappCallsAPI.show.mockResolvedValue({
      data: {
        id: 43,
        call_id: 'wacid-43',
        status: 'ringing',
        direction: 'incoming',
        inbox_id: 57,
        conversation_id: 13744,
        conversation_display_id: 482,
        media_server_enabled: true,
        caller: { name: 'Ahan' },
      },
    });
    WhatsappCallsAPI.accept.mockResolvedValue({
      data: {
        id: 43,
        status: 'in_progress',
        media_session_id: 'sess-43',
        agent_offer: {
          sdp_offer: 'agent-offer-sdp',
          ice_servers: [],
        },
      },
    });
    WhatsappCallsAPI.agentAnswer.mockRejectedValue(
      new Error('agent answer failed')
    );

    const result = await acceptWhatsappCallById(43);
    const callsStore = useWhatsappCallsStore();

    expect(result.success).toBe(true);
    expect(callsStore.activeCall).toMatchObject({
      id: 43,
      callId: 'wacid-43',
      serverRelay: true,
      status: 'in_progress',
      agentWebrtcConnected: false,
      agentWebrtcConnecting: false,
    });
    expect(callsStore.incomingCalls).toHaveLength(0);
    expect(emitter.emit).not.toHaveBeenCalledWith(
      'whatsapp_call:agent_webrtc_connected'
    );
    consoleError.mockRestore();
  });

  it('clears the active server-relay call when media leg already closed during agent answer', async () => {
    WhatsappCallsAPI.show.mockResolvedValue({
      data: {
        id: 44,
        call_id: 'wacid-44',
        status: 'ringing',
        direction: 'incoming',
        inbox_id: 57,
        conversation_id: 13745,
        conversation_display_id: 483,
        media_server_enabled: true,
        caller: { name: 'Ahan' },
      },
    });
    WhatsappCallsAPI.accept.mockResolvedValue({
      data: {
        id: 44,
        status: 'in_progress',
        media_session_id: 'sess-44',
        agent_offer: {
          sdp_offer: 'agent-offer-sdp',
          ice_servers: [],
        },
      },
    });
    WhatsappCallsAPI.agentAnswer.mockRejectedValue({
      response: { data: { code: 'media_leg_closed' } },
    });

    const result = await acceptWhatsappCallById(44);
    const callsStore = useWhatsappCallsStore();

    expect(result.success).toBe(true);
    expect(callsStore.activeCall).toBeNull();
    expect(callsStore.isReconnecting).toBe(false);
    expect(emitter.emit).toHaveBeenCalledWith('newToastMessage', {
      message: WHATSAPP_CALL_MEDIA_LEG_CLOSED_MESSAGE,
      action: null,
    });
  });

  it('posts agent answer after the first ICE candidate instead of waiting for ICE gathering complete', async () => {
    vi.useFakeTimers();

    try {
      global.RTCPeerConnection = vi.fn(() => {
        const pc = new FakeRTCPeerConnection();
        pc.iceGatheringState = 'gathering';
        pc.setLocalDescription = vi.fn(async answer => {
          pc.localDescription = answer;
          setTimeout(() => {
            pc.onicecandidate?.({ candidate: { candidate: 'candidate:1' } });
          }, 25);
        });
        return pc;
      });
      WhatsappCallsAPI.agentAnswer.mockResolvedValue({
        data: { success: true },
      });

      const answerPromise = handleAgentOffer(45, 'agent-offer-sdp', [], {
        direction: 'incoming',
        context: 'test-fast-ice',
      });
      await vi.advanceTimersByTimeAsync(25);
      await answerPromise;

      expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
        45,
        'agent-answer-sdp',
        expect.objectContaining({
          direction: 'incoming',
          context: 'test-fast-ice',
          stages: expect.any(Object),
        })
      );
    } finally {
      vi.useRealTimers();
    }
  });

  it('uses a fresh browser audio stream for outbound offers after an inbound prewarm', async () => {
    const inboundStop = vi.fn();
    const outboundStop = vi.fn();
    const inboundTrack = { id: 'inbound-track', stop: inboundStop };
    const outboundTrack = { id: 'outbound-track', stop: outboundStop };
    const inboundStream = { getTracks: () => [inboundTrack] };
    const outboundStream = { getTracks: () => [outboundTrack] };

    navigator.mediaDevices.getUserMedia
      .mockResolvedValueOnce(inboundStream)
      .mockResolvedValueOnce(outboundStream);

    const pcs = [];
    global.RTCPeerConnection = vi.fn(() => {
      const pc = new FakeRTCPeerConnection();
      pcs.push(pc);
      return pc;
    });
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    await handleAgentOffer(46, 'inbound-offer-sdp', [], {
      direction: 'incoming',
      context: 'accept-response',
      usePrewarmedStream: true,
    });
    await handleAgentOffer(47, 'outbound-offer-sdp', [], {
      direction: 'outbound',
      context: 'outbound-connect',
    });

    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledTimes(2);
    expect(pcs[0].addTrack).toHaveBeenCalledWith(inboundTrack, inboundStream);
    expect(pcs[1].addTrack).toHaveBeenCalledWith(outboundTrack, outboundStream);
    expect(outboundStop).not.toHaveBeenCalled();
  });

  it('sends sanitized timing telemetry with agent answer', async () => {
    const consoleInfo = vi.spyOn(console, 'info').mockImplementation(() => {});
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    await handleAgentOffer(48, 'agent-offer-sdp', [], {
      direction: 'outbound',
      context: 'outbound-connect',
    });

    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      48,
      'agent-answer-sdp',
      expect.objectContaining({
        direction: 'outbound',
        context: 'outbound-connect',
        stages: expect.objectContaining({
          offer_received_ms: expect.any(Number),
          get_user_media_start_ms: expect.any(Number),
          get_user_media_ok_ms: expect.any(Number),
          set_local_description_ok_ms: expect.any(Number),
          agent_answer_post_start_ms: expect.any(Number),
        }),
      })
    );
    expect(consoleInfo).toHaveBeenCalledWith(
      '[WhatsApp Call][timing]',
      expect.objectContaining({
        callId: 48,
        direction: 'outbound',
        context: 'outbound-connect',
        stage: 'agent_answer_ok',
      })
    );
    consoleInfo.mockRestore();
  });
});
