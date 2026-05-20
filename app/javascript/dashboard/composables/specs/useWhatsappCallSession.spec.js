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

const flushMicrotasks = (count = 1) =>
  Array.from({ length: count }).reduce(
    promise => promise.then(() => Promise.resolve()),
    Promise.resolve()
  );

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

  it('attaches the microphone with addTrack for server-relay agent answers', async () => {
    const audioTrack = { kind: 'audio', stop: vi.fn() };
    const replaceTrack = vi.fn(async () => Promise.resolve());
    const addTransceiver = vi.fn(() => ({ sender: { replaceTrack } }));
    const pc = new FakeRTCPeerConnection();
    pc.addTransceiver = addTransceiver;
    global.RTCPeerConnection = vi.fn(() => pc);
    navigator.mediaDevices.getUserMedia.mockResolvedValue({
      getAudioTracks: () => [audioTrack],
      getTracks: () => [audioTrack],
    });
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    const result = await handleAgentOffer(44, 'agent-offer-sdp', [], {
      direction: 'outbound',
      context: 'outbound-connect',
    });

    expect(result.success).toBe(true);
    expect(addTransceiver).not.toHaveBeenCalled();
    expect(replaceTrack).not.toHaveBeenCalled();
    expect(pc.addTrack).toHaveBeenCalledWith(
      audioTrack,
      expect.objectContaining({ getTracks: expect.any(Function) })
    );
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      44,
      'agent-answer-sdp',
      expect.objectContaining({
        direction: 'outbound',
        context: 'outbound-connect',
      })
    );
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

  it('prepares inbound browser answer while accept is in flight but posts only after accept succeeds', async () => {
    let resolveAccept;
    let acceptResolved = false;
    const pcs = [];
    global.RTCPeerConnection = vi.fn(() => {
      const pc = new FakeRTCPeerConnection();
      pcs.push(pc);
      return pc;
    });

    const callsStore = useWhatsappCallsStore();
    callsStore.addIncomingCall({
      id: 52,
      callId: 'wacid-52',
      status: 'ringing',
      direction: 'incoming',
      inboxId: 57,
      conversationId: 13752,
      conversationDisplayId: 492,
      mediaServerEnabled: true,
      mediaSessionId: 'sess-52',
      agentOffer: {
        sdp_offer: 'prepared-agent-offer-sdp',
        ice_servers: [],
        peer_id: 'peer-52',
      },
      caller: { name: 'Ahan' },
    });
    WhatsappCallsAPI.accept.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveAccept = data => {
            acceptResolved = true;
            resolve(data);
          };
        })
    );
    WhatsappCallsAPI.agentAnswer.mockImplementation(() => {
      expect(acceptResolved).toBe(true);
      return Promise.resolve({ data: { success: true } });
    });

    const resultPromise = acceptWhatsappCallById(52);
    await flushMicrotasks(100);

    expect(WhatsappCallsAPI.accept).toHaveBeenCalledWith(52);
    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledTimes(1);
    expect(WhatsappCallsAPI.agentAnswer).not.toHaveBeenCalled();
    expect(pcs[0].setRemoteDescription).toHaveBeenCalledWith({
      type: 'offer',
      sdp: 'prepared-agent-offer-sdp',
    });
    expect(pcs[0].createAnswer).toHaveBeenCalled();
    expect(pcs[0].setLocalDescription).toHaveBeenCalled();

    resolveAccept({
      data: {
        id: 52,
        status: 'in_progress',
        media_session_id: 'sess-52',
      },
    });

    const result = await resultPromise;
    expect(result.success).toBe(true);
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      52,
      'agent-answer-sdp',
      expect.objectContaining({
        direction: 'incoming',
        context: 'pre-accept-agent-answer',
        stages: expect.objectContaining({
          agent_answer_ready_ms: expect.any(Number),
          agent_answer_post_start_ms: expect.any(Number),
        }),
      }),
      'peer-52'
    );
  });

  it('cancels the prepared inbound answer when provider accept fails', async () => {
    let resolveMedia;
    const lateStop = vi.fn();
    navigator.mediaDevices.getUserMedia.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveMedia = resolve;
        })
    );

    const callsStore = useWhatsappCallsStore();
    callsStore.addIncomingCall({
      id: 53,
      callId: 'wacid-53',
      status: 'ringing',
      direction: 'incoming',
      inboxId: 57,
      conversationId: 13753,
      conversationDisplayId: 493,
      mediaServerEnabled: true,
      mediaSessionId: 'sess-53',
      agentOffer: {
        sdp_offer: 'prepared-agent-offer-sdp',
        ice_servers: [],
      },
      caller: { name: 'Ahan' },
    });
    WhatsappCallsAPI.accept.mockRejectedValue({ response: { status: 422 } });

    const resultPromise = acceptWhatsappCallById(53);
    await flushMicrotasks(10);
    await expect(resultPromise).rejects.toMatchObject({
      response: { status: 422 },
    });

    resolveMedia({ getTracks: () => [{ stop: lateStop }] });
    await flushMicrotasks(10);

    expect(WhatsappCallsAPI.agentAnswer).not.toHaveBeenCalled();
    expect(lateStop).toHaveBeenCalled();
    expect(callsStore.activeCall).toBeNull();
    expect(callsStore.incomingCalls).toHaveLength(0);
  });

  it('uses a fresh mic/WebRTC path when accept returns a different agent offer', async () => {
    let resolveStaleMedia;
    const staleStop = vi.fn();
    const freshStop = vi.fn();
    const staleStream = { getTracks: () => [{ stop: staleStop }] };
    const freshStream = { getTracks: () => [{ stop: freshStop }] };
    navigator.mediaDevices.getUserMedia
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveStaleMedia = resolve;
          })
      )
      .mockResolvedValueOnce(freshStream);

    const pcs = [];
    global.RTCPeerConnection = vi.fn(() => {
      const pc = new FakeRTCPeerConnection();
      pcs.push(pc);
      return pc;
    });

    const callsStore = useWhatsappCallsStore();
    callsStore.addIncomingCall({
      id: 54,
      callId: 'wacid-54',
      status: 'ringing',
      direction: 'incoming',
      inboxId: 57,
      conversationId: 13754,
      conversationDisplayId: 494,
      mediaServerEnabled: true,
      mediaSessionId: 'sess-54',
      agentOffer: {
        sdp_offer: 'stale-prepared-agent-offer-sdp',
        ice_servers: [],
        peer_id: 'stale-peer',
      },
      caller: { name: 'Ahan' },
    });
    WhatsappCallsAPI.accept.mockResolvedValue({
      data: {
        id: 54,
        status: 'in_progress',
        media_session_id: 'sess-54',
        agent_offer: {
          sdp_offer: 'fresh-accept-agent-offer-sdp',
          ice_servers: [],
          peer_id: 'fresh-peer',
        },
      },
    });
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    const result = await acceptWhatsappCallById(54);

    expect(result.success).toBe(true);
    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledTimes(2);
    expect(pcs).toHaveLength(1);
    expect(pcs[0].setRemoteDescription).toHaveBeenCalledWith({
      type: 'offer',
      sdp: 'fresh-accept-agent-offer-sdp',
    });
    expect(freshStop).not.toHaveBeenCalled();
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      54,
      'agent-answer-sdp',
      expect.objectContaining({ context: 'accept-response' }),
      'fresh-peer'
    );

    resolveStaleMedia(staleStream);
    await flushMicrotasks(10);
    expect(staleStop).toHaveBeenCalled();
    expect(freshStop).not.toHaveBeenCalled();
  });

  it('accepts the Meta call before connecting a prepared inbound agent offer', async () => {
    const callsStore = useWhatsappCallsStore();
    callsStore.addIncomingCall({
      id: 47,
      callId: 'wacid-47',
      status: 'ringing',
      direction: 'incoming',
      inboxId: 57,
      conversationId: 13747,
      conversationDisplayId: 485,
      mediaServerEnabled: true,
      mediaSessionId: 'sess-47',
      agentOffer: {
        sdp_offer: 'prepared-agent-offer-sdp',
        ice_servers: [],
      },
      caller: { name: 'Ahan' },
    });
    WhatsappCallsAPI.accept.mockResolvedValue({
      data: {
        id: 47,
        status: 'in_progress',
        media_session_id: 'sess-47',
      },
    });
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    const result = await acceptWhatsappCallById(47);

    expect(result.success).toBe(true);
    expect(WhatsappCallsAPI.accept).toHaveBeenCalledWith(47);
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      47,
      'agent-answer-sdp',
      expect.objectContaining({
        direction: 'incoming',
        context: 'pre-accept-agent-answer',
        stages: expect.any(Object),
      })
    );
    expect(WhatsappCallsAPI.accept.mock.invocationCallOrder[0]).toBeLessThan(
      WhatsappCallsAPI.agentAnswer.mock.invocationCallOrder[0]
    );
    expect(callsStore.activeCall).toMatchObject({
      id: 47,
      serverRelay: true,
      agentWebrtcConnected: true,
      status: 'connected',
    });
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

  it('clears the temporary active call when server-relay accept fails', async () => {
    WhatsappCallsAPI.show.mockResolvedValue({
      data: {
        id: 41,
        call_id: 'wacid-41',
        status: 'ringing',
        direction: 'incoming',
        inbox_id: 57,
        conversation_id: 13741,
        conversation_display_id: 480,
        media_server_enabled: true,
        caller: { name: 'Ahan' },
      },
    });
    WhatsappCallsAPI.accept.mockRejectedValue({ response: { status: 422 } });

    await expect(acceptWhatsappCallById(41)).rejects.toMatchObject({
      response: { status: 422 },
    });

    const callsStore = useWhatsappCallsStore();
    expect(callsStore.activeCall).toBeNull();
    expect(callsStore.incomingCalls).toHaveLength(0);
    expect(WhatsappCallsAPI.agentAnswer).not.toHaveBeenCalled();
  });

  it('uses a pending ActionCable agent offer that arrives while accept is in flight', async () => {
    let resolveAccept;
    WhatsappCallsAPI.show.mockResolvedValue({
      data: {
        id: 40,
        call_id: 'wacid-40',
        status: 'ringing',
        direction: 'incoming',
        inbox_id: 57,
        conversation_id: 13740,
        conversation_display_id: 479,
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

    const resultPromise = acceptWhatsappCallById(40);
    await Promise.resolve();
    await Promise.resolve();

    const callsStore = useWhatsappCallsStore();
    expect(callsStore.activeCall).toMatchObject({
      id: 40,
      providerAccepting: true,
    });
    callsStore.storePendingAgentOffer({
      id: 40,
      call_id: 'wacid-40',
      peer_id: 'peer-40',
      sdp_offer: 'inflight-actioncable-offer',
      ice_servers: [],
    });

    resolveAccept({
      data: {
        id: 40,
        status: 'in_progress',
        media_session_id: 'sess-40',
      },
    });

    const result = await resultPromise;

    expect(result.success).toBe(true);
    expect(WhatsappCallsAPI.accept.mock.invocationCallOrder[0]).toBeLessThan(
      WhatsappCallsAPI.agentAnswer.mock.invocationCallOrder[0]
    );
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      40,
      'agent-answer-sdp',
      expect.objectContaining({ context: 'accept-response' }),
      'peer-40'
    );
    expect(callsStore.activeCall.providerAccepting).toBe(false);
  });

  it('uses a pending early ActionCable agent offer when accept response has no offer', async () => {
    const pcs = [];
    global.RTCPeerConnection = vi.fn(() => {
      const pc = new FakeRTCPeerConnection();
      pcs.push(pc);
      return pc;
    });
    const callsStore = useWhatsappCallsStore();
    callsStore.storePendingAgentOffer({
      id: 49,
      call_id: 'wacid-49',
      sdp_offer: 'early-actioncable-offer',
      ice_servers: [],
    });
    WhatsappCallsAPI.show.mockResolvedValue({
      data: {
        id: 49,
        call_id: 'wacid-49',
        status: 'ringing',
        direction: 'incoming',
        inbox_id: 57,
        conversation_id: 13749,
        conversation_display_id: 489,
        media_server_enabled: true,
        caller: { name: 'Ahan' },
      },
    });
    WhatsappCallsAPI.accept.mockResolvedValue({
      data: {
        id: 49,
        status: 'in_progress',
        media_session_id: 'sess-49',
      },
    });
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });

    const result = await acceptWhatsappCallById(49);

    expect(result.success).toBe(true);
    expect(pcs[0].setRemoteDescription).toHaveBeenCalledWith({
      type: 'offer',
      sdp: 'early-actioncable-offer',
    });
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
      49,
      'agent-answer-sdp',
      expect.objectContaining({ context: 'pre-accept-agent-answer' })
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

  it('retries the agent WebRTC negotiation once when a local step stalls', async () => {
    vi.useFakeTimers();
    const consoleWarn = vi.spyOn(console, 'warn').mockImplementation(() => {});

    try {
      const stalledPc = new FakeRTCPeerConnection();
      stalledPc.setLocalDescription = vi.fn(() => new Promise(() => {}));
      const retryPc = new FakeRTCPeerConnection();
      const pcs = [stalledPc, retryPc];
      global.RTCPeerConnection = vi.fn(() => pcs.shift());
      WhatsappCallsAPI.agentAnswer.mockResolvedValue({
        data: { success: true },
      });

      const answerPromise = handleAgentOffer(50, 'agent-offer-sdp', [], {
        direction: 'incoming',
        context: 'stall-retry',
      });

      await vi.advanceTimersByTimeAsync(3000);
      await answerPromise;

      expect(global.RTCPeerConnection).toHaveBeenCalledTimes(2);
      expect(stalledPc.close).toHaveBeenCalled();
      expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledWith(
        50,
        'agent-answer-sdp',
        expect.objectContaining({ context: 'stall-retry' })
      );
      expect(consoleWarn).toHaveBeenCalledWith(
        '[WhatsApp Call] Retrying agent WebRTC negotiation after local failure',
        expect.objectContaining({ callId: 50, attempt: 1 })
      );
    } finally {
      consoleWarn.mockRestore();
      vi.useRealTimers();
    }
  });

  it('stops a microphone stream that resolves after media acquisition timeout', async () => {
    vi.useFakeTimers();
    const lateStop = vi.fn();
    let resolveMedia;
    navigator.mediaDevices.getUserMedia.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveMedia = resolve;
        })
    );

    try {
      const answerPromise = handleAgentOffer(51, 'agent-offer-sdp', [], {
        direction: 'outbound',
        context: 'late-media-timeout',
      });
      const rejectionExpectation = expect(answerPromise).rejects.toThrow(
        'get_user_media timed out'
      );

      await vi.advanceTimersByTimeAsync(15000);
      await rejectionExpectation;

      resolveMedia({ getTracks: () => [{ stop: lateStop }] });
      await Promise.resolve();

      expect(lateStop).toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });
});
