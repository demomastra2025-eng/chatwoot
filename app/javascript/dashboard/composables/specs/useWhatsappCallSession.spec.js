import { describe, it, beforeEach, expect, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { acceptWhatsappCallById } from '../useWhatsappCallSession';
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
      'agent-answer-sdp'
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
});
