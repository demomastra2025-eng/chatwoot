import { Web } from 'sip.js';
import VoiceAPI from './voiceAPIClient';

const createCallDisconnectedEvent = detail =>
  new CustomEvent('call:disconnected', { detail });

const createCallIncomingEvent = detail =>
  new CustomEvent('call:incoming', { detail });

const createCallRegisteredEvent = detail =>
  new CustomEvent('call:registered', { detail });

const createCallUnregisteredEvent = detail =>
  new CustomEvent('call:unregistered', { detail });

const WEBPHONE_PRESENCE_REFRESH_INTERVAL_MS = 60_000;
const WEBPHONE_INCOMING_CALL_WAIT_MS = 7_000;
const WEBPHONE_INCOMING_CALL_POLL_MS = 100;

class FonosterVoiceClient extends EventTarget {
  constructor() {
    super();
    this.simpleUser = null;
    this.remoteAudioElement = null;
    this.sessionConfig = null;
    this.sessionSignature = null;
    this.inboxId = null;
    this.initialized = false;
    this.connected = false;
    this.registered = false;
    this.pendingIncomingCall = false;
    this.hasActiveCall = false;
    this.registrationPromise = null;
    this.presenceHeartbeatTimer = null;
  }

  static normalizeSessionConfig(sessionConfig = {}) {
    return {
      ...sessionConfig,
      provider: sessionConfig.provider || 'fonoster',
      callingSupported:
        sessionConfig.callingSupported ??
        sessionConfig.calling_supported ??
        true,
      signalingServer:
        sessionConfig.signalingServer || sessionConfig.signaling_server,
      targetAor:
        sessionConfig.targetAor ||
        sessionConfig.target_aor ||
        sessionConfig.aor,
    };
  }

  sessionState(sessionConfig = this.sessionConfig) {
    const normalized =
      FonosterVoiceClient.normalizeSessionConfig(sessionConfig);
    return {
      provider: normalized.provider || 'fonoster',
      callingSupported: normalized.callingSupported !== false,
      targetAor: normalized.targetAor,
      registered: this.registered,
      pendingIncomingCall: this.pendingIncomingCall,
    };
  }

  async initializeDevice(sessionConfig, { inboxId = null } = {}) {
    const normalized =
      FonosterVoiceClient.normalizeSessionConfig(sessionConfig);
    const previousToken = this.sessionConfig?.token;
    this.sessionConfig = normalized;
    this.inboxId = inboxId;

    if (!normalized.callingSupported) {
      return this.sessionState(normalized);
    }

    const signature = JSON.stringify({
      username: normalized.username,
      domain: normalized.domain,
      signalingServer: normalized.signalingServer,
      targetAor: normalized.targetAor,
    });

    if (!FonosterVoiceClient.hasCompleteContract(normalized)) {
      throw new Error(
        'Browser calling is not configured for this Fonoster agent'
      );
    }

    if (this.initialized && this.sessionSignature === signature) {
      await this.ensureConnectedAndRegistered({
        refreshRegistration:
          Boolean(previousToken) && previousToken !== normalized.token,
      });
      return this.sessionState(normalized);
    }

    await this.destroyDevice({ preserveSessionConfig: true });

    this.sessionSignature = signature;
    this.remoteAudioElement = this.ensureRemoteAudioElement();

    const delegate = {
      onCallReceived: () => {
        this.pendingIncomingCall = true;
        this.hasActiveCall = false;
        this.dispatchEvent(
          createCallIncomingEvent({
            provider: 'fonoster',
            targetAor: normalized.targetAor,
          })
        );
      },
      onCallAnswered: () => {
        this.pendingIncomingCall = false;
        this.hasActiveCall = true;
        this.remoteAudioElement?.play?.().catch(() => {});
      },
      onCallHangup: () => {
        const hadCall = this.pendingIncomingCall || this.hasActiveCall;
        this.pendingIncomingCall = false;
        this.hasActiveCall = false;
        if (hadCall) {
          this.dispatchEvent(
            createCallDisconnectedEvent({ provider: 'fonoster' })
          );
        }
      },
      onRegistered: () => {
        this.markRegistered();
        this.dispatchEvent(createCallRegisteredEvent({ provider: 'fonoster' }));
      },
      onUnregistered: () => {
        this.registered = false;
        this.stopPresenceHeartbeat();
        FonosterVoiceClient.reportPresence(false);
        this.dispatchEvent(
          createCallUnregisteredEvent({ provider: 'fonoster' })
        );
      },
      onServerConnect: () => {
        this.connected = true;
      },
      onServerDisconnect: () => {
        const hadCall = this.pendingIncomingCall || this.hasActiveCall;
        const wasRegistered = this.registered;
        this.connected = false;
        this.registered = false;
        this.stopPresenceHeartbeat();
        FonosterVoiceClient.reportPresence(false);
        if (wasRegistered) {
          this.dispatchEvent(
            createCallUnregisteredEvent({ provider: 'fonoster' })
          );
        }
        this.pendingIncomingCall = false;
        this.hasActiveCall = false;
        if (hadCall) {
          this.dispatchEvent(
            createCallDisconnectedEvent({ provider: 'fonoster' })
          );
        }
      },
    };

    this.simpleUser = new Web.SimpleUser(normalized.signalingServer, {
      aor: normalized.targetAor,
      delegate,
      media: {
        constraints: { audio: true, video: false },
        remote: { audio: this.remoteAudioElement },
      },
      userAgentOptions: {
        displayName: normalized.displayName,
        authorizationUsername: normalized.username,
        authorizationPassword: normalized.token,
        allowLegacyNotifications: false,
        logBuiltinEnabled: false,
        logConfiguration: false,
        logLevel: 'error',
        transportOptions: {
          server: normalized.signalingServer,
          keepAliveInterval: 15,
        },
      },
    });

    await this.simpleUser.connect();
    this.connected = true;
    await this.register();
    this.markRegistered();
    this.initialized = true;

    return this.sessionState(normalized);
  }

  static hasCompleteContract(sessionConfig) {
    return (
      sessionConfig.token &&
      sessionConfig.username &&
      sessionConfig.domain &&
      sessionConfig.signalingServer &&
      sessionConfig.targetAor
    );
  }

  ensureRemoteAudioElement() {
    if (typeof document === 'undefined') return null;
    if (this.remoteAudioElement?.isConnected) return this.remoteAudioElement;

    const audio = document.createElement('audio');
    audio.setAttribute('autoplay', 'true');
    audio.setAttribute('playsinline', 'true');
    audio.style.display = 'none';
    document.body.appendChild(audio);
    return audio;
  }

  async register() {
    if (!this.simpleUser) return;
    if (this.registrationPromise) {
      await this.registrationPromise;
      return;
    }

    this.registrationPromise = this.simpleUser
      .register({
        requestOptions: {
          extraHeaders: [`X-Connect-Token: ${this.sessionConfig.token}`],
        },
      })
      .finally(() => {
        this.registrationPromise = null;
      });

    await this.registrationPromise;
  }

  static reportPresence(registered) {
    VoiceAPI.updateWebphonePresence(registered).catch(() => {});
  }

  markRegistered() {
    this.registered = true;
    FonosterVoiceClient.reportPresence(true);
    this.startPresenceHeartbeat();
  }

  startPresenceHeartbeat() {
    this.stopPresenceHeartbeat();
    this.presenceHeartbeatTimer = window.setInterval(() => {
      if (this.registered) {
        FonosterVoiceClient.reportPresence(true);
      }
    }, WEBPHONE_PRESENCE_REFRESH_INTERVAL_MS);
  }

  stopPresenceHeartbeat() {
    if (!this.presenceHeartbeatTimer) return;

    window.clearInterval(this.presenceHeartbeatTimer);
    this.presenceHeartbeatTimer = null;
  }

  async ensureConnectedAndRegistered({ refreshRegistration = false } = {}) {
    if (!this.simpleUser) return;
    if (!this.simpleUser.isConnected()) {
      await this.simpleUser.connect();
      this.connected = true;
    }
    if (!this.registered || refreshRegistration) {
      await this.register();
      this.markRegistered();
    }
  }

  async waitForPendingIncomingCall(timeoutMs = WEBPHONE_INCOMING_CALL_WAIT_MS) {
    if (this.pendingIncomingCall) return true;

    const deadline = Date.now() + timeoutMs;
    while (!this.pendingIncomingCall && Date.now() < deadline) {
      // eslint-disable-next-line no-await-in-loop
      await new Promise(resolve => {
        window.setTimeout(resolve, WEBPHONE_INCOMING_CALL_POLL_MS);
      });
    }

    return this.pendingIncomingCall;
  }

  async joinClientCall() {
    if (!this.simpleUser || !this.initialized) return null;

    await this.ensureConnectedAndRegistered();

    const hasIncomingCall = await this.waitForPendingIncomingCall();
    if (!hasIncomingCall) {
      return null;
    }

    await this.simpleUser.answer();
    this.pendingIncomingCall = false;
    this.hasActiveCall = true;
    return { provider: 'fonoster', answered: true };
  }

  async rejectIncomingCall() {
    if (!this.simpleUser || !this.pendingIncomingCall) return null;

    await this.simpleUser.decline();
    this.pendingIncomingCall = false;
    this.hasActiveCall = false;
    return { provider: 'fonoster', declined: true };
  }

  async endClientCall() {
    if (
      !this.simpleUser ||
      (!this.pendingIncomingCall && !this.hasActiveCall)
    ) {
      return null;
    }

    await this.simpleUser.hangup();
    this.pendingIncomingCall = false;
    this.hasActiveCall = false;
    return { provider: 'fonoster', ended: true };
  }

  async destroyDevice({ preserveSessionConfig = false } = {}) {
    const currentUser = this.simpleUser;

    this.simpleUser = null;
    this.initialized = false;
    this.connected = false;
    this.registered = false;
    this.stopPresenceHeartbeat();
    FonosterVoiceClient.reportPresence(false);
    this.pendingIncomingCall = false;
    this.hasActiveCall = false;
    this.registrationPromise = null;

    if (!preserveSessionConfig) {
      this.sessionConfig = null;
      this.sessionSignature = null;
      this.inboxId = null;
    }

    if (!currentUser) return;

    try {
      await currentUser.unregister().catch(() => {});
      await currentUser.disconnect().catch(() => {});
    } finally {
      if (this.remoteAudioElement) {
        const stream = this.remoteAudioElement.srcObject;
        if (stream && typeof stream.getTracks === 'function') {
          stream.getTracks().forEach(track => track.stop());
        }
        this.remoteAudioElement.pause?.();
        this.remoteAudioElement.srcObject = null;
      }
    }
  }
}

export default new FonosterVoiceClient();
