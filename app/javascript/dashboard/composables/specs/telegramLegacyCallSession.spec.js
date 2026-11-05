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
  autoConnect: true,
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
            get url() {
              return original.callsApiFor(value).url;
            },
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
const answerSdp = [
  'v=0',
  'o=- 1 1 IN IP4 127.0.0.1',
  's=-',
  't=0 0',
  'm=audio 49152 UDP/TLS/RTP/SAVPF 111',
  'a=ice-ufrag:browser583',
  'a=ice-pwd:abcdefghijklmnopqrstuvwx',
  `a=fingerprint:sha-256 ${Array(32).fill('AB').join(':')}`,
  'a=setup:active',
  'a=candidate:1 1 UDP 2122260223 192.0.2.10 49152 typ host',
  '',
].join('\r\n');
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
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}

beforeEach(() => {
  window.history.replaceState({}, '', '/app/accounts/1/conversations/1');
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
  state.autoConnect = true;
  state.agentAnswer.mockImplementation(async () => {
    if (state.autoConnect) state.peers.at(-1).connectionState = 'connected';
    return { data: { success: true } };
  });
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
      this.localDescription = { type: 'answer', sdp: answerSdp };
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
  window.history.replaceState({}, '', '/');
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
        answerSdp,
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
      sdp: answerSdp,
    };
    pc.iceGatheringState = 'complete';
    pc.onicegatheringstatechange();
    await pending;
    expect(state.agentAnswer).toHaveBeenCalledWith(
      1,
      answerSdp,
      expect.any(Object)
    );
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(pc.onicecandidate).toBeNull();
  });

  it('posts a valid candidate snapshot once at the deadline, then waits for connected', async () => {
    vi.useFakeTimers();
    state.gathering = true;
    state.autoConnect = false;
    const done = vi.fn();
    const pending = handleCallAgentOffer(1, offer, options).then(done);
    await vi.advanceTimersByTimeAsync(10001);
    const pc = state.peers[0];
    expect(pc.iceGatheringState).toBe('gathering');
    expect(state.agentAnswer).toHaveBeenCalledExactlyOnceWith(
      1,
      answerSdp,
      expect.any(Object)
    );
    expect(done).not.toHaveBeenCalled();
    pc.connectionState = 'connected';
    pc.onconnectionstatechange();
    await pending;
    expect(done).toHaveBeenCalledWith({ success: true });
    expect(state.agentAnswer).toHaveBeenCalledOnce();
  });

  it.each([
    ['no candidates', answerSdp.replace(/^a=candidate:.*\r\n/m, '')],
    [
      'malformed candidate',
      answerSdp.replace('192.0.2.10 49152', 'not-an-address 99999'),
    ],
    ['arbitrary nonempty text', 'local-answer-with-ice'],
    ['rejected audio', answerSdp.replace('m=audio 49152', 'm=audio 0')],
    ['no ICE password', answerSdp.replace(/^a=ice-pwd:.*\r\n/m, '')],
    [
      'TCP-only unsupported native candidate',
      answerSdp.replace('1 1 UDP', '1 1 TCP'),
    ],
    [
      'component2-only candidate',
      answerSdp.replace('candidate:1 1 UDP', 'candidate:1 2 UDP'),
    ],
  ])(
    'rejects %s at the ICE deadline without posting an answer',
    async (_name, sdp) => {
      vi.useFakeTimers();
      state.gathering = true;
      const pending = handleCallAgentOffer(1, offer, options);
      const rejected = expect(pending).rejects.toMatchObject({
        stage: 'ice_candidates',
        retryable: false,
      });
      await vi.advanceTimersByTimeAsync(1);
      state.peers[0].localDescription = { type: 'answer', sdp };
      await vi.advanceTimersByTimeAsync(10000);
      await rejected;
      expect(state.agentAnswer).not.toHaveBeenCalled();
      expect(state.peers[0].close).toHaveBeenCalledOnce();
      expect(track.stop).toHaveBeenCalledOnce();
    }
  );

  it('rejects answer200 without connected and reclaims resources with no retry', async () => {
    vi.useFakeTimers();
    state.autoConnect = false;
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toMatchObject({
      stage: 'peer_connection',
      retryable: false,
    });
    await vi.advanceTimersByTimeAsync(10001);
    await rejected;
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(state.peers).toHaveLength(1);
    expect(state.peers[0].close).toHaveBeenCalledOnce();
    expect(state.peers[0].onconnectionstatechange).toBeNull();
    expect(track.stop).toHaveBeenCalledOnce();
  });

  it('does not return a deferred Telegram success before its answer and actual connection', async () => {
    state.autoConnect = false;
    const done = vi.fn();
    const pending = handleCallAgentOffer(1, offer, {
      ...options,
      deferPost: true,
    }).then(done);
    await vi.waitFor(() =>
      expect(state.peers[0]?.onconnectionstatechange).toBeTypeOf('function')
    );
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(done).not.toHaveBeenCalled();
    state.peers[0].connectionState = 'connected';
    state.peers[0].onconnectionstatechange();
    await pending;
    expect(done).toHaveBeenCalledWith({ success: true });
  });

  it('observes connected reached before the answer POST resolves', async () => {
    const gate = deferred();
    state.agentAnswer.mockReturnValue(gate.promise);
    const done = vi.fn();
    const pending = handleCallAgentOffer(1, offer, options).then(done);
    await vi.waitFor(() => expect(state.agentAnswer).toHaveBeenCalledOnce());
    state.peers[0].connectionState = 'connected';
    expect(done).not.toHaveBeenCalled();
    gate.resolve({ data: { success: true } });
    await pending;
    expect(done).toHaveBeenCalledWith({ success: true });
  });

  it('never resends an answer after an ambiguously failed POST marked retryable', async () => {
    const error = Object.assign(
      new Error('synthetic answer transport timeout'),
      { retryable: true }
    );
    state.agentAnswer.mockRejectedValue(error);
    await expect(handleCallAgentOffer(1, offer, options)).rejects.toMatchObject(
      { retryable: false }
    );
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(state.peers).toHaveLength(1);
    expect(track.stop).toHaveBeenCalledOnce();
  });

  it('rejects a failed connection after the single answer without retrying', async () => {
    state.autoConnect = false;
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toMatchObject({
      stage: 'peer_connection',
      retryable: false,
    });
    await vi.waitFor(() =>
      expect(state.peers[0]?.onconnectionstatechange).toBeTypeOf('function')
    );
    state.peers[0].connectionState = 'failed';
    state.peers[0].onconnectionstatechange();
    await rejected;
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(state.peers).toHaveLength(1);
    expect(track.stop).toHaveBeenCalledOnce();
  });

  it('cancels a superseded connection wait without closing the new peer', async () => {
    vi.useFakeTimers();
    state.autoConnect = false;
    const old = handleCallAgentOffer(1, offer, options);
    const rejected = expect(old).rejects.toMatchObject({ cancelled: true });
    await vi.advanceTimersByTimeAsync(1);
    expect(state.peers[0].onconnectionstatechange).toBeTypeOf('function');
    state.autoConnect = true;
    await handleCallAgentOffer(
      1,
      { ...offer, sdp_offer: 'new-generation-sdp' },
      options
    );
    await rejected;
    await vi.advanceTimersByTimeAsync(20000);
    expect(state.peers).toHaveLength(2);
    expect(state.peers[0].close).toHaveBeenCalled();
    expect(state.peers[1].close).not.toHaveBeenCalled();
    expect(state.agentAnswer).toHaveBeenCalledTimes(2);
  });

  it('fences the real media answer when the account changes during microphone permission', async () => {
    const gate = deferred();
    navigator.mediaDevices.getUserMedia.mockReturnValue(gate.promise);
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toMatchObject({ cancelled: true });
    window.history.replaceState({}, '', '/app/accounts/2/conversations/1');
    gate.resolve(microphone());
    await rejected;
    expect(state.agentAnswer).not.toHaveBeenCalled();
    expect(state.reconnect).not.toHaveBeenCalled();
    expect(track.stop).toHaveBeenCalled();
  });

  it('fences an account change during bounded ICE gathering before the answer POST', async () => {
    vi.useFakeTimers();
    state.gathering = true;
    const pending = handleCallAgentOffer(1, offer, options);
    const rejected = expect(pending).rejects.toMatchObject({ cancelled: true });
    await vi.advanceTimersByTimeAsync(1);
    window.history.replaceState({}, '', '/app/accounts/2/conversations/1');
    await vi.advanceTimersByTimeAsync(10000);
    await rejected;
    expect(state.agentAnswer).not.toHaveBeenCalled();
    expect(state.peers[0].close).toHaveBeenCalled();
  });

  it('rejects an answer response after switching accounts without declaring media ready', async () => {
    const gate = deferred();
    state.agentAnswer.mockReturnValue(gate.promise);
    const done = vi.fn();
    const pending = handleCallAgentOffer(1, offer, options).then(done);
    const rejected = expect(pending).rejects.toMatchObject({ cancelled: true });
    await vi.waitFor(() => expect(state.agentAnswer).toHaveBeenCalledOnce());
    window.history.replaceState({}, '', '/app/accounts/2/conversations/1');
    state.peers[0].connectionState = 'connected';
    gate.resolve({ data: { success: true } });
    await rejected;
    expect(done).not.toHaveBeenCalled();
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(track.stop).toHaveBeenCalled();
  });

  it('does not reconnect an old call under the new account API URL', async () => {
    await handleCallAgentOffer(1, offer, options);
    window.history.replaceState({}, '', '/app/accounts/2/conversations/1');
    await expect(reconnectTelegramMedia(1)).rejects.toMatchObject({
      cancelled: true,
    });
    expect(state.reconnect).not.toHaveBeenCalled();
    expect(state.agentAnswer).toHaveBeenCalledOnce();
  });

  it('discards an old-account reconnect response before creating media', async () => {
    await handleCallAgentOffer(1, offer, options);
    const gate = deferred();
    state.reconnect.mockReturnValue(gate.promise);
    const pending = reconnectTelegramMedia(1);
    window.history.replaceState({}, '', '/app/accounts/2/conversations/1');
    gate.resolve({ data: { ...offer, sdp_offer: 'late-old-account-offer' } });
    await pending;
    expect(state.peers).toHaveLength(1);
    expect(state.agentAnswer).toHaveBeenCalledOnce();
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

  it.each(['new-call', 'same-call-fresh-sdp'])(
    'cancels a late old answer rejection without closing %s media or retrying',
    async replacement => {
      const gate = deferred();
      state.agentAnswer.mockReturnValueOnce(gate.promise);
      const first = handleCallAgentOffer(1, offer, options);
      const observed = first.catch(error => error);
      await vi.waitFor(() => expect(state.agentAnswer).toHaveBeenCalledOnce());
      const nextId = replacement === 'new-call' ? 2 : 1;
      if (nextId === 2) {
        useWhatsappCallsStore().setActiveCall({
          id: 2,
          provider: 'telegram_personal',
          direction: 'incoming',
        });
      }
      const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
      navigator.mediaDevices.getUserMedia.mockResolvedValue(
        microphone(freshTrack)
      );
      const freshOffer = { ...offer, sdp_offer: 'fresh-replacement-sdp' };
      await handleCallAgentOffer(nextId, freshOffer, options);
      const freshPc = state.peers[1];
      gate.reject(
        Object.assign(new Error('old answer failed late'), { retryable: true })
      );
      expect(await observed).toMatchObject({ cancelled: true });
      expect(freshPc.close).not.toHaveBeenCalled();
      expect(freshTrack.stop).not.toHaveBeenCalled();
      expect(state.agentAnswer).toHaveBeenCalledTimes(2);
      await handleCallAgentOffer(nextId, freshOffer, options);
      expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledTimes(2);
    }
  );

  it('cancels a late old microphone rejection without touching fresh media', async () => {
    const gate = deferred();
    navigator.mediaDevices.getUserMedia.mockReturnValueOnce(gate.promise);
    const first = handleCallAgentOffer(1, offer, options);
    const observed = first.catch(error => error);
    useWhatsappCallsStore().setActiveCall({
      id: 2,
      provider: 'telegram_personal',
      direction: 'incoming',
    });
    const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
    navigator.mediaDevices.getUserMedia.mockResolvedValue(
      microphone(freshTrack)
    );
    await handleCallAgentOffer(
      2,
      { ...offer, sdp_offer: 'fresh-call-sdp' },
      options
    );
    gate.reject(new Error('old microphone request failed late'));
    expect(await observed).toMatchObject({ cancelled: true });
    expect(state.peers[0].close).not.toHaveBeenCalled();
    expect(freshTrack.stop).not.toHaveBeenCalled();
    expect(state.agentAnswer).toHaveBeenCalledOnce();
  });

  it('ignores late old answer success and remote audio after a same-call SDP replacement', async () => {
    const gate = deferred();
    state.agentAnswer.mockReturnValueOnce(gate.promise);
    const first = handleCallAgentOffer(1, offer, options);
    const observed = first.catch(error => error);
    await vi.waitFor(() => expect(state.agentAnswer).toHaveBeenCalledOnce());
    const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
    navigator.mediaDevices.getUserMedia.mockResolvedValue(
      microphone(freshTrack)
    );
    await handleCallAgentOffer(
      1,
      { ...offer, sdp_offer: 'same-call-fresh-sdp' },
      options
    );
    vi.spyOn(HTMLMediaElement.prototype, 'play').mockResolvedValue();
    const freshStream = {};
    state.peers[1].ontrack({ streams: [freshStream] });
    const audio = Array.from(document.querySelectorAll('audio')).at(-1);
    state.peers[0].ontrack({ streams: [{}] });
    expect(audio.srcObject).toBe(freshStream);
    const currentDisconnect = state.peers[1].onconnectionstatechange;
    gate.resolve({ data: { success: true } });
    expect(await observed).toMatchObject({ cancelled: true });
    expect(state.peers[1].onconnectionstatechange).toBe(currentDisconnect);
    expect(state.peers[1].close).not.toHaveBeenCalled();
    expect(freshTrack.stop).not.toHaveBeenCalled();
  });

  it('does not stop a track reused by the current SDP when an old answer fails', async () => {
    const gate = deferred();
    state.agentAnswer.mockReturnValueOnce(gate.promise);
    const first = handleCallAgentOffer(1, offer, options);
    const observed = first.catch(error => error);
    await vi.waitFor(() => expect(state.agentAnswer).toHaveBeenCalledOnce());
    // Separate MediaStreams can contain the same live track.
    navigator.mediaDevices.getUserMedia.mockResolvedValue(microphone(track));
    await handleCallAgentOffer(
      1,
      { ...offer, sdp_offer: 'reused-track-sdp' },
      options
    );
    const stopsBeforeStaleFailure = track.stop.mock.calls.length;
    gate.reject(new Error('old answer failed late'));
    expect(await observed).toMatchObject({ cancelled: true });
    expect(track.stop).toHaveBeenCalledTimes(stopsBeforeStaleFailure);
    expect(state.peers[1].close).not.toHaveBeenCalled();
  });

  it('protects a current stream from an old permission result arriving after its timeout', async () => {
    vi.useFakeTimers();
    const gate = deferred();
    navigator.mediaDevices.getUserMedia.mockReturnValueOnce(gate.promise);
    const first = handleCallAgentOffer(1, offer, options);
    const observed = first.catch(error => error);
    await vi.advanceTimersByTimeAsync(15001);
    expect(await observed).toMatchObject({ stage: 'get_user_media' });
    const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
    const freshStream = microphone(freshTrack);
    navigator.mediaDevices.getUserMedia.mockResolvedValue(freshStream);
    await handleCallAgentOffer(
      1,
      { ...offer, sdp_offer: 'fresh-permission-sdp' },
      options
    );
    gate.resolve(freshStream);
    await vi.advanceTimersByTimeAsync(0);
    expect(freshTrack.stop).not.toHaveBeenCalled();
    expect(state.peers[0].close).not.toHaveBeenCalled();
  });

  it('preserves one legitimate Telegram retry and deduplicates its successful SDP', async () => {
    const original = RTCPeerConnection.getMockImplementation();
    RTCPeerConnection.mockImplementationOnce(
      function RetryableLocalPeer(config) {
        original.call(this, config);
        this.createAnswer.mockRejectedValueOnce(
          Object.assign(new Error('retryable local SDP failure before POST'), {
            retryable: true,
          })
        );
      }
    );
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    await handleCallAgentOffer(1, offer, options);
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    await handleCallAgentOffer(1, offer, options);
    expect(state.agentAnswer).toHaveBeenCalledOnce();
    expect(state.peers[1].close).not.toHaveBeenCalled();
  });

  it('applies the stale failure guard to WhatsApp without closing its fresh peer', async () => {
    useWhatsappCallsStore().setActiveCall({ id: 99, provider: 'whatsapp' });
    const gate = deferred();
    WhatsappCallsAPI.agentAnswer.mockReturnValueOnce(gate.promise);
    const first = handleAgentOffer(99, 'old-wa-sdp', [], {
      provider: 'whatsapp',
    });
    const observed = first.catch(error => error);
    await vi.waitFor(() =>
      expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledOnce()
    );
    const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
    navigator.mediaDevices.getUserMedia.mockResolvedValue(
      microphone(freshTrack)
    );
    await handleAgentOffer(99, 'fresh-wa-sdp', [], { provider: 'whatsapp' });
    gate.reject(
      Object.assign(new Error('old WhatsApp answer failed late'), {
        retryable: true,
      })
    );
    expect(await observed).toMatchObject({ cancelled: true });
    expect(state.peers[1].close).not.toHaveBeenCalled();
    expect(freshTrack.stop).not.toHaveBeenCalled();
    expect(WhatsappCallsAPI.agentAnswer).toHaveBeenCalledTimes(2);
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
