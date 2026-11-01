import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { mount } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';

const state = vi.hoisted(() => ({ clients: [], reconnect: vi.fn() }));
vi.mock('dashboard/api/channel/voice/janusAudioBridgeCallClient', () => ({
  isJanusAudioBridgeOffer: offer => offer?.transport === 'janus_audiobridge',
  default: class FakeJanusClient {
    constructor() {
      state.clients.push(this);
      this.close = vi.fn();
      this.connect = vi.fn(
        () =>
          new Promise(resolve => {
            this.resolve = resolve;
          })
      );
    }
  },
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
        ? { reconnect: state.reconnect }
        : original.callsApiFor(value),
  };
});

import {
  clearPreparedInboundAgentAnswer,
  handleCallAgentOffer,
  handleAgentOffer,
  reconnectTelegramJanusMedia,
  useWhatsappCallSession,
} from '../useWhatsappCallSession';

const offer = { transport: 'janus_audiobridge', peer_id: 'peer-1' };

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

beforeEach(() => {
  setActivePinia(createPinia());
  vi.spyOn(console, 'info').mockImplementation(() => {});
  useWhatsappCallsStore().setActiveCall({
    id: 1,
    provider: 'telegram_personal',
  });
  state.clients.length = 0;
  state.reconnect.mockReset();
  track = { kind: 'audio', stop: vi.fn() };
  Object.defineProperty(navigator, 'mediaDevices', {
    configurable: true,
    value: {
      getUserMedia: vi.fn().mockResolvedValue({
        getTracks: () => [track],
        getAudioTracks: () => [track],
      }),
    },
  });
});
afterEach(() => {
  wrapper?.unmount();
  wrapper = null;
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  clearPreparedInboundAgentAnswer({}, { cleanupWebrtc: true });
});

describe('Telegram Janus call session', () => {
  it('deduplicates an accept response and readiness event for the same media generation', async () => {
    const first = handleCallAgentOffer(1, offer, {
      provider: 'telegram_personal',
    });
    const duplicate = handleCallAgentOffer(
      1,
      { ...offer, server: 'fresh-ticket-url' },
      { provider: 'telegram_personal' }
    );
    await vi.waitFor(() =>
      expect(state.clients[0].connect).toHaveBeenCalledOnce()
    );
    expect(state.clients).toHaveLength(1);
    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledOnce();
    expect(state.clients[0].connect).toHaveBeenCalledOnce();
    state.clients[0].resolve();
    await expect(first).resolves.toEqual({ success: true });
    await expect(duplicate).resolves.toEqual({ success: true });
  });

  it('never sends Telegram through the direct SDP transport', async () => {
    await expect(
      handleAgentOffer(1, 'sdp', [], { provider: 'telegram_personal' })
    ).rejects.toThrow('require Janus');
    await expect(
      handleCallAgentOffer(
        1,
        { sdp_offer: 'sdp' },
        { provider: 'telegram_personal' }
      )
    ).rejects.toThrow('require Janus');
    expect(navigator.mediaDevices.getUserMedia).not.toHaveBeenCalled();
    expect(state.clients).toHaveLength(0);
  });

  it('replaces the old media generation and rejects its late connection completion', async () => {
    const first = handleCallAgentOffer(1, offer, {
      provider: 'telegram_personal',
    });
    const rejected = expect(first).rejects.toMatchObject({ cancelled: true });
    await vi.waitFor(() =>
      expect(state.clients[0].connect).toHaveBeenCalledOnce()
    );
    const second = handleCallAgentOffer(
      1,
      { ...offer, peer_id: 'peer-2' },
      { provider: 'telegram_personal' }
    );
    await vi.waitFor(() =>
      expect(state.clients[1].connect).toHaveBeenCalledOnce()
    );
    expect(state.clients[0].close).toHaveBeenCalledOnce();
    expect(track.stop).toHaveBeenCalled();
    state.clients[0].resolve();
    await rejected;
    state.clients[1].resolve();
    await expect(second).resolves.toEqual({ success: true });
  });

  it.each(['automatic', 'manual'])(
    'preserves mute through %s reconnection until an explicit unmute',
    async mode => {
      const store = useWhatsappCallsStore();
      store.setActiveCall({
        id: 1,
        callId: 'call-1',
        provider: 'telegram_personal',
        direction: 'incoming',
        serverRelay: true,
        isMuted: true,
      });
      const ui = mountCallSession();
      const first = handleCallAgentOffer(1, offer, {
        provider: 'telegram_personal',
      });
      await vi.waitFor(() =>
        expect(state.clients[0].connect).toHaveBeenCalledOnce()
      );
      expect(track.enabled).toBe(false);
      state.clients[0].resolve();
      await first;
      const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
      navigator.mediaDevices.getUserMedia.mockResolvedValue({
        getTracks: () => [freshTrack],
        getAudioTracks: () => [freshTrack],
      });
      const newOffer = { ...offer, peer_id: 'peer-2' };
      state.reconnect.mockResolvedValue({ data: newOffer });
      const reconnecting =
        mode === 'automatic'
          ? reconnectTelegramJanusMedia(1)
          : handleCallAgentOffer(1, newOffer, {
              provider: 'telegram_personal',
            });
      await vi.waitFor(() =>
        expect(state.clients[1].connect).toHaveBeenCalledOnce()
      );
      expect(freshTrack.enabled).toBe(false);
      expect(ui.isMuted.value).toBe(true);
      expect(store.activeCall.isMuted).toBe(true);
      state.clients[1].resolve();
      await reconnecting;
      expect(freshTrack.enabled).toBe(false);
      ui.toggleMute();
      expect(freshTrack.enabled).toBe(true);
      expect(ui.isMuted.value).toBe(false);
      expect(store.activeCall.isMuted).toBe(false);
    }
  );

  it('keeps a WhatsApp microphone muted when permission resolves after the mute action', async () => {
    const store = useWhatsappCallsStore();
    store.setActiveCall({
      id: 99,
      provider: 'whatsapp',
      direction: 'incoming',
      serverRelay: true,
    });
    const ui = mountCallSession();
    const freshTrack = { kind: 'audio', enabled: true, stop: vi.fn() };
    let resolvePermission;
    navigator.mediaDevices.getUserMedia.mockReturnValue(
      new Promise(resolve => {
        resolvePermission = resolve;
      })
    );
    const pc = {
      localDescription: { type: 'answer', sdp: 'local-answer' },
      iceGatheringState: 'complete',
      addTrack: vi.fn(attached => expect(attached.enabled).toBe(false)),
      setRemoteDescription: vi.fn(async () => {}),
      createAnswer: vi.fn(async () => ({
        type: 'answer',
        sdp: 'local-answer',
      })),
      setLocalDescription: vi.fn(async () => {}),
      close: vi.fn(),
    };
    vi.stubGlobal(
      'RTCPeerConnection',
      vi.fn(() => pc)
    );
    WhatsappCallsAPI.agentAnswer.mockResolvedValue({ data: { success: true } });
    const connecting = handleAgentOffer(99, 'wa-offer', [], {
      provider: 'whatsapp',
    });
    ui.toggleMute();
    expect(ui.isMuted.value).toBe(true);
    resolvePermission({
      getTracks: () => [freshTrack],
      getAudioTracks: () => [freshTrack],
    });
    await expect(connecting).resolves.toEqual({ success: true });
    expect(pc.addTrack).toHaveBeenCalledOnce();
    expect(freshTrack.enabled).toBe(false);
    expect(ui.isMuted.value).toBe(true);
    ui.toggleMute();
    expect(freshTrack.enabled).toBe(true);
    expect(ui.isMuted.value).toBe(false);
  });

  it('stops microphone permission resolving after the call was cancelled', async () => {
    let resolvePermission;
    navigator.mediaDevices.getUserMedia.mockReturnValue(
      new Promise(resolve => {
        resolvePermission = resolve;
      })
    );
    const pending = handleCallAgentOffer(1, offer, {
      provider: 'telegram_personal',
    });
    const rejected = expect(pending).rejects.toMatchObject({ cancelled: true });
    clearPreparedInboundAgentAnswer({}, { cleanupWebrtc: true });
    resolvePermission({
      getTracks: () => [track],
      getAudioTracks: () => [track],
    });
    await rejected;
    expect(track.stop).toHaveBeenCalledOnce();
    expect(state.clients[0].connect).not.toHaveBeenCalled();
  });
});
