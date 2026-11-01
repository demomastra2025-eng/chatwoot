import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ sessions: [], plugins: [], handles: [] }));
vi.mock('./janusDependencies', () => ({ createJanusDependencies: () => ({}) }));
vi.mock('janus-gateway', () => {
  class JanusMock {
    static init({ callback }) {
      callback();
    }

    constructor(options) {
      this.options = options;
      this.destroy = vi.fn();
      state.sessions.push(this);
      queueMicrotask(() => options.success());
    }

    // eslint-disable-next-line class-methods-use-this
    attach(options) {
      const handle = {
        send: vi.fn(),
        detach: vi.fn(),
        hangup: vi.fn(),
        createOffer: vi.fn(({ success }) =>
          success({ type: 'offer', sdp: 'local-sdp' })
        ),
        handleRemoteJsep: vi.fn(),
      };
      state.plugins.push(options);
      state.handles.push(handle);
      options.success(handle);
    }
  }
  return { default: JanusMock };
});

import JanusAudioBridgeCallClient, {
  isJanusAudioBridgeOffer,
} from './janusAudioBridgeCallClient';

const offer = {
  transport: 'janus_audiobridge',
  room_id: 123,
  peer_id: 'generation-1',
  pin: 'join-pin',
  token: 'join-token',
  server: 'wss://example.test/janus-sipuni?janus_ticket=one-use',
  ice_servers: [{ urls: 'stun:example.test' }],
};
let stream;
let track;
let clients;
const start = (callbacks = {}) => {
  const client = new JanusAudioBridgeCallClient();
  clients.push(client);
  const promise = client.connect(offer, { stream, ...callbacks });
  return { client, promise };
};

beforeEach(() => {
  state.sessions.length = 0;
  state.plugins.length = 0;
  state.handles.length = 0;
  clients = [];
  track = { kind: 'audio', enabled: true, stop: vi.fn() };
  stream = { getTracks: () => [track], getAudioTracks: () => [track] };
});
afterEach(() => clients.forEach(client => client.close()));

describe('JanusAudioBridgeCallClient', () => {
  it('joins the call room and waits for actual WebRTC readiness before reporting success', async () => {
    const { promise } = start();
    const connected = vi.fn();
    promise.then(connected);
    await Promise.resolve();
    const plugin = state.plugins[0];
    const handle = state.handles[0];
    expect(state.sessions[0].options.server).toBe(offer.server);
    expect(plugin.plugin).toBe('janus.plugin.audiobridge');
    expect(handle.send).toHaveBeenCalledWith(
      expect.objectContaining({
        message: {
          request: 'join',
          room: 123,
          pin: 'join-pin',
          token: 'join-token',
        },
      })
    );
    plugin.onmessage({ audiobridge: 'joined' });
    expect(handle.createOffer).toHaveBeenCalledWith(
      expect.objectContaining({
        tracks: [{ type: 'audio', capture: track, recv: true }],
      })
    );
    expect(handle.send).toHaveBeenLastCalledWith(
      expect.objectContaining({
        message: { request: 'configure', muted: false },
        jsep: { type: 'offer', sdp: 'local-sdp' },
      })
    );
    plugin.onmessage({}, { type: 'answer', sdp: 'remote-sdp' });
    expect(handle.handleRemoteJsep).toHaveBeenCalled();
    await Promise.resolve();
    expect(connected).not.toHaveBeenCalled();
    plugin.webrtcState(true);
    await promise;
    expect(connected).toHaveBeenCalledOnce();
  });

  it('negotiates once if Janus repeats the room joined event', async () => {
    const { promise } = start();
    await Promise.resolve();
    state.plugins[0].onmessage({ audiobridge: 'joined' });
    state.plugins[0].onmessage({ audiobridge: 'joined' });
    expect(state.handles[0].createOffer).toHaveBeenCalledOnce();
    state.plugins[0].webrtcState(true);
    await promise;
  });

  it('fails closed on a room permission error and releases microphone and session', async () => {
    const { promise } = start();
    const rejected = expect(promise).rejects.toThrow(
      'Janus call media connection failed'
    );
    await Promise.resolve();
    state.plugins[0].onmessage({ error: 'Unauthorized join-pin join-token' });
    await rejected;
    expect(track.stop).toHaveBeenCalledOnce();
    expect(state.sessions[0].destroy).toHaveBeenCalledOnce();
    expect(state.handles[0].detach).toHaveBeenCalledOnce();
  });

  it('cancels a pending join and ignores late Janus events', async () => {
    const { client, promise } = start();
    const rejected = expect(promise).rejects.toMatchObject({ cancelled: true });
    await Promise.resolve();
    client.close();
    state.plugins[0].onmessage({ audiobridge: 'joined' });
    state.plugins[0].webrtcState(true);
    await rejected;
    expect(state.handles[0].createOffer).not.toHaveBeenCalled();
    client.close();
    expect(state.sessions[0].destroy).toHaveBeenCalledOnce();
  });

  it('signals a disconnected call once, after having connected', async () => {
    const onDisconnected = vi.fn();
    const { promise } = start({ onDisconnected });
    await Promise.resolve();
    state.plugins[0].webrtcState(true);
    await promise;
    state.plugins[0].webrtcState(false);
    state.plugins[0].oncleanup();
    expect(onDisconnected).toHaveBeenCalledOnce();
    expect(track.stop).toHaveBeenCalledOnce();
  });

  it('releases the microphone even when an already closed transport rejects teardown', async () => {
    const { client, promise } = start();
    const rejected = expect(promise).rejects.toMatchObject({ cancelled: true });
    await Promise.resolve();
    state.handles[0].hangup.mockImplementation(() => {
      throw new Error('closed socket');
    });
    client.close();
    await rejected;
    expect(state.handles[0].detach).toHaveBeenCalledOnce();
    expect(state.sessions[0].destroy).toHaveBeenCalledOnce();
    expect(track.stop).toHaveBeenCalledOnce();
  });

  it('rejects direct SDP and incomplete or unsafe room identifiers', async () => {
    expect(isJanusAudioBridgeOffer({ sdp_offer: 'direct-gateway' })).toBe(
      false
    );
    expect(
      isJanusAudioBridgeOffer({
        ...offer,
        room_id: Number.MAX_SAFE_INTEGER + 1,
      })
    ).toBe(false);
    expect(isJanusAudioBridgeOffer({ ...offer, token: null })).toBe(false);
    const client = new JanusAudioBridgeCallClient();
    await expect(
      client.connect({ sdp_offer: 'direct-gateway' }, { stream })
    ).rejects.toThrow('Invalid Janus');
    expect(state.sessions).toHaveLength(0);
  });
});
