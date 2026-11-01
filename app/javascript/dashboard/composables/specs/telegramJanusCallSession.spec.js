import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const state = vi.hoisted(() => ({ clients: [] }));
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

import {
  clearPreparedInboundAgentAnswer,
  handleCallAgentOffer,
  handleAgentOffer,
} from '../useWhatsappCallSession';

const offer = { transport: 'janus_audiobridge', peer_id: 'peer-1' };

let track;
beforeEach(() => {
  setActivePinia(createPinia());
  state.clients.length = 0;
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
afterEach(() => clearPreparedInboundAgentAnswer({}, { cleanupWebrtc: true }));

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
