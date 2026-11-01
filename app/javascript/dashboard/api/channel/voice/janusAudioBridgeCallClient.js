import Janus from 'janus-gateway';
import { createJanusDependencies } from './janusDependencies';

export const isJanusAudioBridgeOffer = offer =>
  offer?.transport === 'janus_audiobridge' &&
  Number.isSafeInteger(offer.room_id) &&
  offer.room_id > 0 &&
  Boolean(offer.server && offer.pin && offer.token && offer.peer_id);

// The browser only joins a room issued by Rails for its accepted call. Room
// creation/destruction and its administrative secret remain in the gateway.
export default class JanusAudioBridgeCallClient {
  constructor() {
    this.closed = false;
    this.session = null;
    this.handle = null;
    this.stream = null;
    this.remoteStream = null;
    this.connected = false;
    this.offered = false;
    this.timer = null;
  }

  connect(offer, { stream, onRemoteStream, onDisconnected } = {}) {
    if (!isJanusAudioBridgeOffer(offer) || !stream?.getAudioTracks?.().length) {
      return Promise.reject(
        new Error('Invalid Janus call media configuration')
      );
    }
    this.stream = stream;
    this.onRemoteStream = onRemoteStream;
    this.onDisconnected = onDisconnected;
    return new Promise((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
      this.timer = setTimeout(() => this.fail(), 15000);
      try {
        Janus.init({
          debug: false,
          dependencies: createJanusDependencies(),
          callback: () => {
            if (this.closed) return;
            this.session = new Janus({
              server: offer.server,
              iceServers: offer.ice_servers || [],
              destroyOnUnload: false,
              success: () => this.attach(offer),
              error: () => this.fail(),
              destroyed: () => this.fail(),
            });
          },
        });
      } catch {
        this.fail();
      }
    });
  }

  attach(offer) {
    if (this.closed) return;
    this.session.attach({
      plugin: 'janus.plugin.audiobridge',
      success: handle => {
        if (this.closed) {
          handle.detach?.();
          return;
        }
        this.handle = handle;
        handle.send({
          message: {
            request: 'join',
            room: offer.room_id,
            pin: offer.pin,
            token: offer.token,
          },
          error: () => this.fail(),
        });
      },
      error: () => this.fail(),
      onmessage: (message, jsep) => this.onMessage(message, jsep),
      webrtcState: connected => {
        if (this.closed) return;
        if (!connected) {
          this.fail();
          return;
        }
        this.connected = true;
        clearTimeout(this.timer);
        this.resolve?.();
        this.resolve = null;
        this.reject = null;
      },
      onremotetrack: (track, _mid, enabled) => {
        if (this.closed || track.kind !== 'audio') return;
        if (!this.remoteStream) this.remoteStream = new MediaStream();
        if (enabled) {
          this.remoteStream.addTrack(track);
          this.onRemoteStream?.(this.remoteStream);
        } else {
          this.remoteStream.removeTrack(track);
        }
      },
      oncleanup: () => this.fail(),
      detached: () => this.fail(),
    });
  }

  onMessage(message, jsep) {
    if (this.closed) return;
    if (message?.error || message?.audiobridge === 'destroyed') {
      this.fail();
      return;
    }
    if (jsep) {
      this.handle.handleRemoteJsep({ jsep, error: () => this.fail() });
    }
    if (message?.audiobridge !== 'joined' || this.offered) return;
    this.offered = true;
    this.handle.createOffer({
      tracks: [
        { type: 'audio', capture: this.stream.getAudioTracks()[0], recv: true },
      ],
      success: localJsep => {
        if (this.closed) return;
        this.handle.send({
          message: { request: 'configure', muted: false },
          jsep: localJsep,
          error: () => this.fail(),
        });
      },
      error: () => this.fail(),
    });
  }

  fail() {
    if (this.closed) return;
    const wasConnected = this.connected;
    this.reject?.(new Error('Janus call media connection failed'));
    this.close();
    if (wasConnected) this.onDisconnected?.();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.timer);
    const error = new Error('Janus call media connection cancelled');
    error.cancelled = true;
    this.reject?.(error);
    this.resolve = null;
    this.reject = null;
    // A lost signalling socket must not prevent releasing the microphone.
    [
      () => this.handle?.hangup?.(),
      () => this.handle?.detach?.(),
      () => this.session?.destroy?.(),
    ].forEach(teardown => {
      try {
        teardown();
      } catch {
        // The transport may already have disappeared.
      }
    });
    this.stream?.getTracks?.().forEach(track => track.stop());
    this.remoteStream?.getTracks?.().forEach(track => track.stop());
    this.handle = null;
    this.session = null;
  }
}
