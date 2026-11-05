import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { mount } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';

const state = vi.hoisted(() => ({
  peers: [],
  reconnect: vi.fn(),
  accept: vi.fn(),
  agentAnswer: vi.fn(),
  remoteGate: null,
  gathering: false,
  janus: vi.fn(),
}));
vi.mock('dashboard/api/channel/voice/janusAudioBridgeCallClient', () => ({
  default: state.janus,
}));
vi.mock('shared/helpers/mitt', () => ({ emitter: { emit: vi.fn() } }));
vi.mock('dashboard/api/auth', () => ({ default: {} }));
vi.mock('dashboard/api/whatsappCalls', () => ({
  default: { agentAnswer: vi.fn() },
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/api/telegramPersonalCalls', async importOriginal => {
  const original = await importOriginal();
  return {
    ...original,
    callsApiFor: value =>
      original.isTelegramPersonalProvider(value)
        ? {
            reconnect: state.reconnect,
            accept: state.accept,
            agentAnswer: state.agentAnswer,
          }
        : original.callsApiFor(value),
  };
});

import {
  clearPreparedInboundAgentAnswer,
  handleCallAgentOffer,
  handleAgentOffer,
  reconnectTelegramMedia,
  prewarmInboundAgentAnswerForCall,
  useWhatsappCallSession,
  acceptWhatsappCallById,
} from '../useWhatsappCallSession';

const offer = {
  sdp_offer: 'v=0\r\na=ice-ufrag:gateway583\r\n',
  ice_servers: [{ urls: 'stun:example.invalid:3478' }],
};
const options = { provider: 'telegram_personal' };
let track;
let wrapper;
function mountCallSession() {
  let api;
  wrapper = mount(
    defineComponent({
      setup() {
        api = useWhatsappCallSession();
        return () => h('div');
      },
    })
  );
  return api;
}
function microphone(audioTrack = track) {
  return { getTracks: () => [audioTrack], getAudioTracks: () => [audioTrack] };
}
function deferred() {
  let resolve;
  const promise = new Promise(done => {
    resolve = done;
  });
  return { promise, resolve };
}

beforeEach(() => {
  setActivePinia(createPinia());
  vi.spyOn(console, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  useWhatsappCallsStore().setActiveCall({
    id: 1,
    callId: 'tg-call',
    provider: 'telegram_personal',
    direction: 'incoming',
  });
  state.peers.length = 0;
  state.remoteGate = null;
  state.gathering = false;
  state.agentAnswer.mockResolvedValue({ data: { success: true } });
  WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });
  track = { kind: 'audio', enabled: true, stop: vi.fn() };
  Object.defineProperty(navigator, 'mediaDevices', {
    configurable: true,
    value: { getUserMedia: vi.fn().mockResolvedValue(microphone()) },
  });
  vi.stubGlobal('WebSocket', vi.fn());
  vi.stubGlobal(
    'RTCPeerConnection',
    vi.fn(function Peer(config) {
      this.config = config;
      this.iceGatheringState = state.gathering ? 'gathering' : 'complete';
      this.connectionState = 'new';
      this.localDescription = { type: 'answer', sdp: 'local-answer-with-ice' };
      this.addTrack = vi.fn();
      const gate = state.remoteGate;
      this.setRemoteDescription = vi.fn(
        () => gate?.promise || Promise.resolve()
      );
      this.createAnswer = vi.fn(async () => this.localDescription);
      this.setLocalDescription = vi.fn(async () => {});
      this.close = vi.fn();
      state.peers.push(this);
    })
  );
});
afterEach(() => {
  wrapper?.unmount();
  wrapper = null;
  clearPreparedInboundAgentAnswer({}, { cleanupWebrtc: true });
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('Telegram gateway583 direct SDP call session', () => {
  it.each(['incoming', 'outbound'])(
    'answers the native %s SDP/ICE offer once without creating Janus or WebSocket',
    async direction => {
      useWhatsappCallsStore().updateActiveCall({ direction });
      await expect(handleCallAgentOffer(1, offer, options)).resolves.toEqual({
        success: true,
      });
      const [pc] = state.peers;
      expect(pc.config).toEqual({ iceServers: offer.ice_servers });
      expect(pc.addTrack).toHaveBeenCalledWith(track, expect.anything());
      expect(pc.setRemoteDescription).toHaveBeenCalledWith({
        type: 'offer',
        sdp: offer.sdp_offer,
      });
      expect(state.agentAnswer).toHaveBeenCalledWith(
        1,
        'local-answer-with-ice',
        expect.any(Object)
      );
      expect(WhatsappCallsAPI.agentAnswer).not.toHaveBeenCalled();
      expect(state.janus).not.toHaveBeenCalled();
      expect(WebSocket).not.toHaveBeenCalled();
      const remote = {};
      vi.spyOn(HTMLMediaElement.prototype, 'play').mockResolvedValue();
      pc.ontrack({ streams: [remote] });
      const remoteAudio = Array.from(document.querySelectorAll('audio')).at(-1);
      expect(remoteAudio.srcObject).toBe(remote);
      clearPreparedInboundAgentAnswer({}, { cleanupWebrtc: true });
      expect(pc.close).toHaveBeenCalledOnce();
      expect(track.stop).toHaveBeenCalledOnce();
      expect(remoteAudio.isConnected).toBe(false);
    }
  );

  it('deduplicates synchronous and event-triggered native offers with no peer_id', async () => {
    state.remoteGate = deferred();
    const first = handleCallAgentOffer(1, offer, options);
    const duplicate = handleAgentOffer(
      1,
      offer.sdp_offer,
      offer.ice_servers,
      options
    );
    await vi.waitFor(() => expect(state.peers).toHaveLength(1));
    state.remoteGate.resolve();
    await Promise.all([first, duplicate]);
    await handleCallAgentOffer(1, { ...offer }, options);
    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledOnce();
    expect(state.agentAnswer).toHaveBeenCalledOnce();
  });

  it('replaces a fresh SDP without peer_id and cancels the old late negotiation', async () => {
    const gate = deferred();
    state.remoteGate = gate;
    const first = handleCallAgentOffer(1, offer, options);
    const rejected = expect(first).rejects.toMatchObject({ cancelled: true });
    await vi.waitFor(() => expect(state.peers).toHaveLength(1));
    state.remoteGate = null;
    await handleCallAgentOffer(
      1,
      { ...offer, sdp_offer: 'fresh-sdp' },
      options
    );
    gate.resolve();
    await rejected;
    expect(state.peers[0].close).toHaveBeenCalled();
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(state.peers[1].setRemoteDescription).toHaveBeenCalledWith({
      type: 'offer',
      sdp: 'fresh-sdp',
    });
  });

  it.each(['automatic', 'manual'])(
    'preserves mute through %s reconnection until explicit unmute',
    async mode => {
      const store = useWhatsappCallsStore();
      store.updateActiveCall({ serverRelay: true, isMuted: true });
      const ui = mountCallSession();
      await handleCallAgentOffer(1, offer, options);
      expect(track.enabled).toBe(false);
      const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
      navigator.mediaDevices.getUserMedia.mockResolvedValue(
        microphone(freshTrack)
      );
      const newOffer = { ...offer, sdp_offer: 'fresh-sdp' };
      state.reconnect.mockResolvedValue({ data: newOffer });
      await (mode === 'automatic'
        ? reconnectTelegramMedia(1)
        : handleCallAgentOffer(1, newOffer, options));
      expect(freshTrack.enabled).toBe(false);
      expect(ui.isMuted.value).toBe(true);
      ui.toggleMute();
      expect(freshTrack.enabled).toBe(true);
      expect(store.activeCall.isMuted).toBe(false);
    }
  );

  it('reconnects a failed direct peer only once and keeps the current owner', async () => {
    const store = useWhatsappCallsStore();
    await handleCallAgentOffer(1, offer, options);
    const gate = deferred();
    state.reconnect.mockReturnValue(gate.promise);
    const pc = state.peers[0];
    pc.connectionState = 'failed';
    pc.onconnectionstatechange();
    pc.onconnectionstatechange();
    expect(state.reconnect).toHaveBeenCalledOnce();
    expect(store.activeCall.agentWebrtcConnecting).toBe(true);
    gate.resolve({ data: { ...offer, sdp_offer: 'reconnected-sdp' } });
    await vi.waitFor(() => expect(state.agentAnswer).toHaveBeenCalledTimes(2));
    expect(store.activeCall.id).toBe(1);
  });

  it('does not prewarm Telegram media from a ringing broadcast', () => {
    expect(
      prewarmInboundAgentAnswerForCall({
        provider: 'telegram_personal',
        agentOffer: offer,
      })
    ).toBeNull();
    expect(navigator.mediaDevices.getUserMedia).not.toHaveBeenCalled();
  });

  it.each(['widget', 'bubble'])(
    'preserves explicit mute while %s acceptance is pending and starts microphone from the gesture',
    async path => {
      const store = useWhatsappCallsStore();
      store.clearActiveCall();
      const call = {
        id: 1,
        callId: 'tg-accept',
        provider: 'telegram_personal',
        direction: 'incoming',
        mediaServerEnabled: true,
      };
      store.addIncomingCall(call);
      const ui = mountCallSession();
      const gate = deferred();
      state.accept.mockImplementation(() => {
        expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledOnce();
        return gate.promise;
      });
      const accepting =
        path === 'widget'
          ? ui.acceptCall(call)
          : acceptWhatsappCallById(1, 'telegram_personal');
      const generation = store.activeCallGeneration;
      expect(store.activeCall.providerAccepting).toBe(true);
      ui.toggleMute();
      gate.resolve({
        data: { id: 1, status: 'in_progress', agent_offer: offer },
      });
      await accepting;
      expect(track.enabled).toBe(false);
      expect(store.activeCallGeneration).toBe(generation);
      expect(store.activeCall.isMuted).toBe(true);
      expect(state.agentAnswer).toHaveBeenCalledOnce();
    }
  );

  it.each(['widget', 'bubble'])(
    'discards late %s acceptance after another provider owns the same database id',
    async path => {
      const store = useWhatsappCallsStore();
      store.clearActiveCall();
      const call = {
        id: 1,
        callId: 'tg-old',
        provider: 'telegram_personal',
        direction: 'incoming',
        mediaServerEnabled: true,
      };
      store.addIncomingCall(call);
      const ui = mountCallSession();
      const gate = deferred();
      state.accept.mockReturnValue(gate.promise);
      const accepting =
        path === 'widget'
          ? ui.acceptCall(call)
          : acceptWhatsappCallById(1, 'telegram_personal');
      const observed =
        path === 'bubble'
          ? expect(accepting).rejects.toMatchObject({ cancelled: true })
          : accepting;
      store.handleCallEnded('tg-old', 1);
      store.setActiveCall({
        id: 1,
        callId: 'wa-new',
        provider: 'whatsapp',
        isMuted: false,
        agentWebrtcConnected: true,
      });
      const generation = store.activeCallGeneration;
      gate.resolve({
        data: { id: 1, status: 'in_progress', agent_offer: offer },
      });
      await observed;
      expect(state.peers).toHaveLength(0);
      expect(store.activeCall).toMatchObject({
        callId: 'wa-new',
        provider: 'whatsapp',
        isMuted: false,
        agentWebrtcConnected: true,
      });
      expect(store.activeCallGeneration).toBe(generation);
    }
  );

  it('stops microphone permission resolving after cancellation', async () => {
    const gate = deferred();
    navigator.mediaDevices.getUserMedia.mockReturnValue(gate.promise);
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toMatchObject({ cancelled: true });
    clearPreparedInboundAgentAnswer({}, { cleanupWebrtc: true });
    gate.resolve(microphone());
    await rejected;
    expect(track.stop).toHaveBeenCalledOnce();
    expect(state.peers).toHaveLength(0);
    expect(state.agentAnswer).not.toHaveBeenCalled();
  });

  it('rejects a same-id cross-provider replacement before sending an SDP answer', async () => {
    const gate = deferred();
    navigator.mediaDevices.getUserMedia.mockReturnValue(gate.promise);
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toMatchObject({ cancelled: true });
    useWhatsappCallsStore().setActiveCall({ id: 1, provider: 'whatsapp' });
    gate.resolve(microphone());
    await rejected;
    expect(track.stop).toHaveBeenCalledOnce();
    expect(state.agentAnswer).not.toHaveBeenCalled();
  });

  it('waits for bundled ICE completion and sends the complete answer exactly once', async () => {
    state.gathering = true;
    const pending = handleCallAgentOffer(1, offer, options);
    await vi.waitFor(() =>
      expect(state.peers[0]?.onicecandidate).toBeTypeOf('function')
    );
    const pc = state.peers[0];
    pc.onicecandidate({ candidate: { candidate: 'first candidate' } });
    await Promise.resolve();
    expect(state.agentAnswer).not.toHaveBeenCalled();
    pc.localDescription = {
      type: 'answer',
      sdp: 'complete-answer-with-all-candidates',
    };
    pc.iceGatheringState = 'complete';
    pc.onicegatheringstatechange();
    await pending;
    expect(state.agentAnswer).toHaveBeenCalledWith(
      1,
      'complete-answer-with-all-candidates',
      expect.any(Object)
    );
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(pc.onicecandidate).toBeNull();
  });

  it('rejects an ICE deadline without posting a partial answer', async () => {
    vi.useFakeTimers();
    state.gathering = true;
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toThrow(
      'ICE gathering did not complete'
    );
    await vi.advanceTimersByTimeAsync(10001);
    await rejected;
    expect(state.agentAnswer).not.toHaveBeenCalled();
    expect(state.peers[0].close).toHaveBeenCalled();
    expect(track.stop).toHaveBeenCalled();
  });

  it('cancels an ICE wait immediately on cleanup and never sends a late answer', async () => {
    state.gathering = true;
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toMatchObject({ cancelled: true });
    await vi.waitFor(() =>
      expect(state.peers[0]?.onicecandidate).toBeTypeOf('function')
    );
    const pc = state.peers[0];
    clearPreparedInboundAgentAnswer({}, { cleanupWebrtc: true });
    await rejected;
    expect(pc.onicecandidate).toBeNull();
    expect(state.agentAnswer).not.toHaveBeenCalled();
  });

  it.each([
    {},
    { transport: 'janus_audiobridge', room_id: 10 },
    { ...offer, transport: 'janus_audiobridge' },
  ])(
    'rejects an invalid or deferred Janus descriptor without opening media: %j',
    async invalid => {
      await expect(handleCallAgentOffer(1, invalid, options)).rejects.toThrow(
        'direct SDP offer'
      );
      expect(navigator.mediaDevices.getUserMedia).not.toHaveBeenCalled();
      expect(state.janus).not.toHaveBeenCalled();
      expect(WebSocket).not.toHaveBeenCalled();
    }
  );

  it('cleans up a microphone denial without posting SDP or opening a fallback', async () => {
    navigator.mediaDevices.getUserMedia.mockRejectedValue(
      new Error('microphone denied')
    );
    await expect(handleCallAgentOffer(1, offer, options)).rejects.toThrow(
      'microphone denied'
    );
    expect(state.peers).toHaveLength(0);
    expect(state.agentAnswer).not.toHaveBeenCalled();
    expect(WebSocket).not.toHaveBeenCalled();
  });

  it('closes the peer after an invalid remote SDP without posting an answer', async () => {
    const original = RTCPeerConnection.getMockImplementation();
    RTCPeerConnection.mockImplementation(function InvalidPeer(config) {
      original.call(this, config);
      this.setRemoteDescription.mockRejectedValue(
        new Error('invalid remote SDP')
      );
    });
    await expect(handleCallAgentOffer(1, offer, options)).rejects.toThrow(
      'invalid remote SDP'
    );
    expect(state.peers[0].close).toHaveBeenCalled();
    expect(track.stop).toHaveBeenCalled();
    expect(state.agentAnswer).not.toHaveBeenCalled();
  });

  it('stops microphone and peer on an SDP answer API failure without transport fallback', async () => {
    state.agentAnswer.mockRejectedValue(new Error('agent answer rejected'));
    await expect(handleCallAgentOffer(1, offer, options)).rejects.toThrow(
      'agent answer rejected'
    );
    expect(state.peers[0].close).toHaveBeenCalled();
    expect(track.stop).toHaveBeenCalled();
    expect(state.janus).not.toHaveBeenCalled();
    expect(state.agentAnswer).toHaveBeenCalledOnce();
  });

  it('keeps the WhatsApp direct SDP API and mute behavior', async () => {
    const store = useWhatsappCallsStore();
    store.setActiveCall({
      id: 99,
      provider: 'whatsapp',
      direction: 'incoming',
      serverRelay: true,
    });
    const ui = mountCallSession();
    const gate = deferred();
    navigator.mediaDevices.getUserMedia.mockReturnValue(gate.promise);
    const pending = handleAgentOffer(99, 'wa-offer', [], {
      provider: 'whatsapp',
    });
    ui.toggleMute();
    gate.resolve(microphone());
    await pending;
    expect(track.enabled).toBe(false);
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledOnce();
    expect(state.agentAnswer).not.toHaveBeenCalled();
    ui.toggleMute();
    expect(track.enabled).toBe(true);
  });
});
