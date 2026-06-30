import Janus from 'janus-gateway';
import * as webRTCAdapterModule from 'webrtc-adapter';
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
const WEBPHONE_INCOMING_CALL_WAIT_MS = 20_000;
const WEBPHONE_INCOMING_CALL_POLL_MS = 100;
const WEBPHONE_MICROPHONE_PREWARM_TTL_MS = 90_000;
const WEBPHONE_OUTBOUND_SETUP_TIMEOUT_MS = 45_000;

const screenSharingExtension = {
  init: () => {},
  isInstalled: () => true,
  getScreen: callback =>
    callback(new Error('Screen sharing is not supported for Sipuni calls')),
};

const resolveWebRTCAdapter = () => {
  const candidates = [
    webRTCAdapterModule?.default?.default,
    webRTCAdapterModule?.default,
    webRTCAdapterModule,
    typeof window !== 'undefined' ? window.adapter : null,
  ];

  return (
    candidates.find(candidate => candidate?.browserDetails) ||
    candidates.find(candidate => candidate?.default?.browserDetails)?.default ||
    null
  );
};

const createJanusHttpError = (message, extra = {}) =>
  Object.assign(new Error(message), extra);

const janusHttpAPICall = (url, options = {}) => {
  const fetchOptions = {
    method: options.verb,
    headers: {
      Accept: 'application/json, text/plain, */*',
    },
    cache: 'no-cache',
  };

  if (options.verb === 'POST') {
    fetchOptions.headers['Content-Type'] = 'application/json';
  }

  if (options.withCredentials !== undefined) {
    fetchOptions.credentials =
      options.withCredentials === true
        ? 'include'
        : options.withCredentials || 'omit';
  }

  if (options.body) {
    fetchOptions.body = JSON.stringify(options.body);
  }

  let request = fetch(url, fetchOptions).catch(error =>
    Promise.reject(
      createJanusHttpError('Probably a network error, is the server down?', {
        error,
      })
    )
  );

  if (options.timeout) {
    const timeout = new Promise((_resolve, reject) => {
      const timerId = window.setTimeout(() => {
        window.clearTimeout(timerId);
        reject(
          createJanusHttpError('Request timed out', {
            timeout: options.timeout,
          })
        );
      }, options.timeout);
    });
    request = Promise.race([request, timeout]);
  }

  request
    .then(response => {
      if (!response.ok) {
        return Promise.reject(
          createJanusHttpError('API call failed', { response })
        );
      }

      if (typeof options.success !== 'function') return null;

      return response
        .json()
        .then(parsed => options.success(parsed))
        .catch(error =>
          Promise.reject(
            createJanusHttpError('Failed to parse response body', {
              error,
              response,
            })
          )
        );
    })
    .catch(error => {
      if (typeof options.error === 'function') {
        options.error(error.message || '<< internal error >>', error);
      }
    });

  return request;
};

const createJanusDependencies = () => {
  const webRTCAdapter = resolveWebRTCAdapter();
  if (!webRTCAdapter) {
    throw new Error('WebRTC adapter is not available for Janus');
  }

  return {
    newWebSocket: (server, proto) => new WebSocket(server, proto),
    extension: screenSharingExtension,
    isArray: Array.isArray,
    webRTCAdapter,
    httpAPICall: janusHttpAPICall,
  };
};

const stopMediaStream = stream => {
  if (!stream || typeof stream.getTracks !== 'function') return;

  stream.getTracks().forEach(track => track.stop());
};

const hasLiveAudioTrack = stream => {
  if (!stream || typeof stream.getAudioTracks !== 'function') return false;

  return stream.getAudioTracks().some(track => track.readyState !== 'ended');
};

const getMediaDevices = () => {
  if (typeof navigator === 'undefined') return null;
  return navigator.mediaDevices || null;
};

class JanusSipuniVoiceClient extends EventTarget {
  constructor() {
    super();
    this.janus = null;
    this.sipHandle = null;
    this.remoteAudioElement = null;
    this.remoteStream = null;
    this.remoteTracks = {};
    this.localTracks = {};
    this.sessionConfig = null;
    this.sessionSignature = null;
    this.inboxId = null;
    this.initialized = false;
    this.registered = false;
    this.registrationPromise = null;
    this.registrationResolve = null;
    this.registrationReject = null;
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.presenceHeartbeatTimer = null;
    this.currentCallRef = null;
    this.currentCallDirection = null;
    this.microphonePrewarmStream = null;
    this.microphonePrewarmPromise = null;
    this.microphonePrewarmTimer = null;
    this.microphonePrewarmGeneration = 0;
    this.outboundSetupTimer = null;
    this.destroyingDevice = false;
  }

  static normalizeSessionConfig(sessionConfig = {}) {
    const sip = sessionConfig.sip || {};
    return {
      ...sessionConfig,
      provider: 'sipuni',
      callingSupported:
        sessionConfig.callingSupported ??
        sessionConfig.calling_supported ??
        true,
      janusServer: sessionConfig.janusServer || sessionConfig.janus_server,
      iceServers: sessionConfig.iceServers || sessionConfig.ice_servers || [],
      sip: {
        username:
          sip.username ||
          sessionConfig.sipUsername ||
          sessionConfig.sip_username,
        authUsername:
          sip.authUsername ||
          sip.auth_username ||
          sessionConfig.sipAuthUsername ||
          sessionConfig.sip_auth_username ||
          sip.username ||
          sessionConfig.sipUsername ||
          sessionConfig.sip_username,
        password:
          sip.password ||
          sessionConfig.sipPassword ||
          sessionConfig.sip_password,
        host: sip.host || sessionConfig.sipHost || sessionConfig.sip_host,
        port: sip.port || sessionConfig.sipPort || sessionConfig.sip_port,
        transport:
          sip.transport ||
          sessionConfig.sipTransport ||
          sessionConfig.sip_transport ||
          'udp',
        uri: sip.uri || sessionConfig.sipUri || sessionConfig.sip_uri,
        proxy: sip.proxy || sessionConfig.sipProxy || sessionConfig.sip_proxy,
        displayName:
          sip.displayName ||
          sip.display_name ||
          sessionConfig.displayName ||
          sessionConfig.display_name,
        internalExtension:
          sip.internalExtension ||
          sip.internal_extension ||
          sessionConfig.internalExtension ||
          sessionConfig.internal_extension,
      },
    };
  }

  static hasCompleteContract(sessionConfig) {
    const sip = sessionConfig.sip || {};
    return Boolean(
      sessionConfig.janusServer &&
        sip.username &&
        sip.password &&
        sip.host &&
        (sip.uri || JanusSipuniVoiceClient.sipUri(sip.username, sip.host))
    );
  }

  static sipUri(username, host) {
    if (!username || !host) return null;
    return `sip:${username}@${host}`;
  }

  static dialUri(toNumber, host) {
    const target = String(toNumber || '')
      .replace(/^tel:/i, '')
      .replace(/[^\d+]/g, '');
    if (!target || !host) return null;
    return `sip:${target}@${host}`;
  }

  static initJanus() {
    if (Janus.initDone) return Promise.resolve();
    if (JanusSipuniVoiceClient.initPromise) {
      return JanusSipuniVoiceClient.initPromise;
    }

    JanusSipuniVoiceClient.initPromise = new Promise(resolve => {
      Janus.init({
        debug: false,
        dependencies: createJanusDependencies(),
        callback: resolve,
      });
    });
    return JanusSipuniVoiceClient.initPromise;
  }

  sessionState(sessionConfig = this.sessionConfig) {
    const normalized =
      JanusSipuniVoiceClient.normalizeSessionConfig(sessionConfig);
    return {
      provider: 'sipuni',
      callingSupported: normalized.callingSupported !== false,
      registered: this.registered,
      pendingIncomingCall: Boolean(this.pendingIncomingCall),
      internalExtension: normalized.sip?.internalExtension,
    };
  }

  async initializeDevice(sessionConfig, { inboxId = null } = {}) {
    const normalized =
      JanusSipuniVoiceClient.normalizeSessionConfig(sessionConfig);

    if (!normalized.callingSupported) {
      await this.destroyDevice({
        preserveMicrophonePrewarm: true,
      });
      this.sessionConfig = normalized;
      this.inboxId = inboxId;
      return this.sessionState(normalized);
    }

    if (!JanusSipuniVoiceClient.hasCompleteContract(normalized)) {
      await this.destroyDevice({
        preserveMicrophonePrewarm: true,
      });
      this.sessionConfig = normalized;
      this.inboxId = inboxId;
      throw new Error(
        'Browser calling is not configured for this Sipuni agent'
      );
    }

    const signature = JSON.stringify({
      janusServer: normalized.janusServer,
      sipUri: normalized.sip.uri,
      username: normalized.sip.username,
      host: normalized.sip.host,
      proxy: normalized.sip.proxy,
      inboxId,
      internalExtension: normalized.sip.internalExtension,
    });

    if (this.initialized && this.sessionSignature === signature) {
      this.sessionConfig = normalized;
      this.inboxId = inboxId;
      await this.ensureRegistered();
      return this.sessionState(normalized);
    }

    await this.destroyDevice({
      preserveMicrophonePrewarm: true,
    });

    this.sessionConfig = normalized;
    this.inboxId = inboxId;
    this.sessionSignature = signature;
    this.remoteAudioElement = this.ensureRemoteAudioElement();
    await JanusSipuniVoiceClient.initJanus();
    this.janus = await this.createJanusSession(normalized);
    this.sipHandle = await this.attachSipPlugin();
    await this.register();
    this.initialized = true;

    return this.sessionState(normalized);
  }

  createJanusSession(sessionConfig) {
    return new Promise((resolve, reject) => {
      const janus = new Janus({
        server: sessionConfig.janusServer,
        iceServers: sessionConfig.iceServers,
        success: () => resolve(janus),
        error: error => reject(error),
        destroyed: () => this.handleJanusDestroyed(),
      });
    });
  }

  attachSipPlugin() {
    return new Promise((resolve, reject) => {
      this.janus.attach({
        plugin: 'janus.plugin.sip',
        opaqueId: `sipuni-${Date.now()}`,
        success: pluginHandle => resolve(pluginHandle),
        error: error => reject(error),
        onmessage: (msg, jsep) => this.handleSipMessage(msg, jsep),
        onlocaltrack: (track, on) => this.handleLocalTrack(track, on),
        onremotetrack: (track, mid, on) =>
          this.handleRemoteTrack(track, mid, on),
        oncleanup: () => this.handlePeerCleanup(),
        mediaState: (medium, on) => this.handleMediaState(medium, on),
        webrtcState: on => {
          if (!on && this.hasActiveCall) this.handleCallDisconnected();
        },
      });
    });
  }

  register() {
    if (!this.sipHandle || !this.sessionConfig) return Promise.resolve();
    if (this.registrationPromise) return this.registrationPromise;

    const sip = this.sessionConfig.sip;
    const register = {
      request: 'register',
      username:
        sip.uri || JanusSipuniVoiceClient.sipUri(sip.username, sip.host),
      authuser: sip.authUsername,
      display_name: sip.displayName,
      secret: sip.password,
      proxy: sip.proxy,
    };

    this.registrationPromise = new Promise((resolve, reject) => {
      this.registrationResolve = resolve;
      this.registrationReject = reject;
      this.sipHandle.send({ message: register });
    }).finally(() => {
      this.registrationPromise = null;
      this.registrationResolve = null;
      this.registrationReject = null;
    });

    return this.registrationPromise;
  }

  ensureRegistered() {
    if (this.registered) return Promise.resolve();
    return this.register();
  }

  handleSipMessage(msg = {}, jsep = null) {
    const error = msg.error;
    if (error) {
      this.registrationReject?.(new Error(String(error)));
      if (this.hasActiveCall || this.pendingIncomingCall) {
        this.handleCallDisconnected();
      }
      return;
    }

    const result = msg.result || {};
    const event = result.event;
    const callId = msg.call_id || result.call_id || result.callId;

    if (event === 'registration_failed') {
      this.registered = false;
      this.reportPresence(false);
      this.registrationReject?.(
        new Error(`${result.code || ''} ${result.reason || ''}`.trim())
      );
      this.dispatchEvent(createCallUnregisteredEvent({ provider: 'sipuni' }));
      return;
    }

    if (event === 'registered') {
      this.markRegistered();
      this.registrationResolve?.(this.sessionState());
      this.dispatchEvent(createCallRegisteredEvent({ provider: 'sipuni' }));
      return;
    }

    if (event === 'incomingcall') {
      this.pendingIncomingCall = {
        jsep,
        result,
        callId,
        offerless: !jsep,
      };
      this.currentCallRef = this.currentCallRef || callId;
      this.currentCallDirection = 'inbound';
      this.dispatchEvent(
        createCallIncomingEvent({
          provider: 'sipuni',
          callRef: this.currentCallRef,
          from: result.username || result.displayname,
        })
      );
      return;
    }

    if (event === 'calling') {
      this.hasActiveCall = true;
      return;
    }

    if (event === 'progress') {
      this.clearOutboundSetupTimer();
      if (jsep) this.handleRemoteJsep(jsep);
      this.hasActiveCall = true;
      this.playRemoteAudio();
      return;
    }

    if (event === 'accepted') {
      this.clearOutboundSetupTimer();
      if (jsep) this.handleRemoteJsep(jsep);
      this.pendingIncomingCall = null;
      this.hasActiveCall = true;
      this.stopMicrophonePrewarm();
      this.playRemoteAudio();
      return;
    }

    if (event === 'hangup') {
      this.clearOutboundSetupTimer();
      this.sipHandle?.hangup();
      this.handleCallDisconnected({
        code: result.code,
        reason: result.reason,
      });
      return;
    }

    if (event === 'updatingcall' && jsep) {
      this.answerUpdate(jsep);
    }
  }

  handleRemoteJsep(jsep) {
    this.sipHandle?.handleRemoteJsep({
      jsep,
      error: () => this.handleCallDisconnected({ reason: 'remote_jsep_error' }),
    });
  }

  handleLocalTrack(track, on) {
    if (!track || track.kind !== 'audio') return;

    const trackId = track.id || `audio-${Object.keys(this.localTracks).length}`;
    if (!on) {
      this.localTracks[trackId]?.stop?.();
      track.stop?.();
      delete this.localTracks[trackId];
      return;
    }

    this.localTracks[trackId] = track;
  }

  stopLocalTracks() {
    Object.values(this.localTracks).forEach(track => track?.stop?.());
    this.localTracks = {};
  }

  handleMediaState(medium, on) {
    if (medium === 'audio' && on) this.hasActiveCall = true;
  }

  handleRemoteTrack(track, mid, on) {
    if (!on) {
      delete this.remoteTracks[mid];
      this.rebuildRemoteStream();
      return;
    }

    if (track.kind !== 'audio') return;

    this.remoteTracks[mid] = track;
    this.rebuildRemoteStream();
  }

  rebuildRemoteStream() {
    const tracks = Object.values(this.remoteTracks);
    this.remoteStream = tracks.length ? new MediaStream(tracks) : null;
    this.attachRemoteStream();
  }

  attachRemoteStream() {
    if (this.remoteAudioElement) {
      if (this.remoteStream && typeof Janus.attachMediaStream === 'function') {
        Janus.attachMediaStream(this.remoteAudioElement, this.remoteStream);
      } else {
        this.remoteAudioElement.srcObject = this.remoteStream;
      }
      this.playRemoteAudio();
    }
  }

  playRemoteAudio() {
    const playResult = this.remoteAudioElement?.play?.();
    playResult?.catch?.(() => {});
  }

  handlePeerCleanup() {
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.stopLocalTracks();
  }

  handleJanusDestroyed() {
    const hadCall =
      this.pendingIncomingCall || this.hasActiveCall || this.currentCallRef;
    this.initialized = false;
    this.registered = false;
    this.stopPresenceHeartbeat();
    this.clearOutboundSetupTimer();
    if (!this.destroyingDevice) this.reportPresence(false);
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopLocalTracks();
    if (hadCall)
      this.dispatchEvent(createCallDisconnectedEvent(this.callEventDetail()));
  }

  handleCallDisconnected(extra = {}) {
    const hadCall =
      this.pendingIncomingCall || this.hasActiveCall || this.currentCallRef;
    const detail = { ...this.callEventDetail(), ...extra };
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopMicrophonePrewarm();
    this.clearOutboundSetupTimer();
    this.stopLocalTracks();
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.resetCurrentCall();
    if (hadCall) this.dispatchEvent(createCallDisconnectedEvent(detail));
  }

  callEventDetail() {
    return {
      provider: 'sipuni',
      callRef: this.currentCallRef,
      callDirection: this.currentCallDirection,
    };
  }

  resetCurrentCall() {
    this.currentCallRef = null;
    this.currentCallDirection = null;
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

  async waitForPendingIncomingCall(timeoutMs = WEBPHONE_INCOMING_CALL_WAIT_MS) {
    if (this.pendingIncomingCall) return this.pendingIncomingCall;

    const deadline = Date.now() + timeoutMs;
    while (!this.pendingIncomingCall && Date.now() < deadline) {
      // eslint-disable-next-line no-await-in-loop
      await new Promise(resolve => {
        window.setTimeout(resolve, WEBPHONE_INCOMING_CALL_POLL_MS);
      });
    }

    return this.pendingIncomingCall;
  }

  async joinClientCall({
    callRef = null,
    callDirection,
    toNumber = null,
  } = {}) {
    if (!this.sipHandle || !this.initialized) return null;

    this.currentCallRef = callRef || this.currentCallRef;
    this.currentCallDirection = callDirection || this.currentCallDirection;
    await this.ensureRegistered();

    if (callDirection === 'outbound') {
      return this.startOutboundCall(toNumber);
    }

    const incomingCall = await this.waitForPendingIncomingCall();
    if (!incomingCall) {
      this.stopMicrophonePrewarm();
      return null;
    }

    return this.acceptIncomingCall(incomingCall);
  }

  startOutboundCall(toNumber) {
    const sip = this.sessionConfig.sip;
    const uri = JanusSipuniVoiceClient.dialUri(toNumber, sip.host);
    if (!uri) return Promise.resolve(null);

    this.stopMicrophonePrewarm();
    this.hasActiveCall = true;
    this.currentCallDirection = 'outbound';
    return new Promise((resolve, reject) => {
      this.sipHandle.createOffer({
        tracks: [{ type: 'audio', capture: true, recv: true }],
        success: jsep => {
          this.sipHandle.send({
            message: {
              request: 'call',
              uri,
              autoaccept_reinvites: false,
            },
            jsep,
          });
          this.scheduleOutboundSetupTimeout();
          resolve({ provider: 'sipuni', calling: true, uri });
        },
        error: error => {
          this.hasActiveCall = false;
          this.clearOutboundSetupTimer();
          this.stopLocalTracks();
          reject(error);
        },
      });
    });
  }

  acceptIncomingCall(incomingCall) {
    this.stopMicrophonePrewarm();
    const method = incomingCall.offerless
      ? this.sipHandle.createOffer.bind(this.sipHandle)
      : this.sipHandle.createAnswer.bind(this.sipHandle);

    return new Promise((resolve, reject) => {
      method({
        jsep: incomingCall.jsep,
        tracks: [{ type: 'audio', capture: true, recv: true }],
        success: jsep => {
          this.sipHandle.send({
            message: { request: 'accept', autoaccept_reinvites: false },
            jsep,
          });
          this.pendingIncomingCall = null;
          this.hasActiveCall = true;
          resolve({ provider: 'sipuni', answered: true });
        },
        error: reject,
      });
    });
  }

  answerUpdate(jsep) {
    this.sipHandle?.createAnswer({
      jsep,
      tracks: [{ type: 'audio', capture: true, recv: true }],
      success: answer => {
        this.sipHandle?.send({
          message: { request: 'update' },
          jsep: answer,
        });
      },
      error: () => {},
    });
  }

  async rejectIncomingCall() {
    this.clearOutboundSetupTimer();
    if (!this.sipHandle || !this.pendingIncomingCall) {
      this.stopMicrophonePrewarm();
      this.stopLocalTracks();
      return null;
    }

    this.sipHandle.send({ message: { request: 'decline' } });
    this.sipHandle.hangup();
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopMicrophonePrewarm();
    this.stopLocalTracks();
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.resetCurrentCall();
    return { provider: 'sipuni', declined: true };
  }

  async endClientCall() {
    this.stopMicrophonePrewarm();
    this.clearOutboundSetupTimer();
    const hadCall =
      this.pendingIncomingCall || this.hasActiveCall || this.currentCallRef;

    if (!this.sipHandle) {
      this.stopLocalTracks();
      this.resetCurrentCall();
      return null;
    }

    try {
      const request = this.pendingIncomingCall ? 'decline' : 'hangup';
      this.sipHandle.send({ message: { request } });
      this.sipHandle.hangup();
    } catch {
      // Hangup is best-effort; browser tracks must still be released.
    }
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopLocalTracks();
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.resetCurrentCall();
    return hadCall ? { provider: 'sipuni', ended: true } : null;
  }

  scheduleOutboundSetupTimeout() {
    this.clearOutboundSetupTimer();
    this.outboundSetupTimer = window.setTimeout(() => {
      this.outboundSetupTimer = null;
      if (this.currentCallDirection !== 'outbound') return;

      try {
        this.sipHandle?.send?.({ message: { request: 'hangup' } });
        this.sipHandle?.hangup?.();
      } catch {
        // Local cleanup below is authoritative for the browser media state.
      }
      this.handleCallDisconnected({ reason: 'sip_outbound_setup_timeout' });
    }, WEBPHONE_OUTBOUND_SETUP_TIMEOUT_MS);
  }

  clearOutboundSetupTimer() {
    if (!this.outboundSetupTimer) return;

    window.clearTimeout(this.outboundSetupTimer);
    this.outboundSetupTimer = null;
  }

  scheduleMicrophonePrewarmCleanup(ttlMs) {
    this.clearMicrophonePrewarmTimer();
    this.microphonePrewarmTimer = window.setTimeout(() => {
      this.stopMicrophonePrewarm();
    }, ttlMs);
  }

  clearMicrophonePrewarmTimer() {
    if (!this.microphonePrewarmTimer) return;

    window.clearTimeout(this.microphonePrewarmTimer);
    this.microphonePrewarmTimer = null;
  }

  async prewarmMicrophone({ ttlMs = WEBPHONE_MICROPHONE_PREWARM_TTL_MS } = {}) {
    if (hasLiveAudioTrack(this.microphonePrewarmStream)) {
      this.scheduleMicrophonePrewarmCleanup(ttlMs);
      return { provider: 'sipuni', prewarmed: true, reused: true };
    }

    if (this.microphonePrewarmPromise) return this.microphonePrewarmPromise;

    const mediaDevices = getMediaDevices();
    if (typeof mediaDevices?.getUserMedia !== 'function') {
      return {
        provider: 'sipuni',
        prewarmed: false,
        reason: 'media_devices_unavailable',
      };
    }

    const generation = this.microphonePrewarmGeneration;
    this.microphonePrewarmPromise = mediaDevices
      .getUserMedia({ audio: true, video: false })
      .then(stream => {
        if (generation !== this.microphonePrewarmGeneration) {
          stopMediaStream(stream);
          return { provider: 'sipuni', prewarmed: false, reason: 'cancelled' };
        }

        this.microphonePrewarmStream = stream;
        this.scheduleMicrophonePrewarmCleanup(ttlMs);
        return { provider: 'sipuni', prewarmed: true };
      })
      .catch(error => ({
        provider: 'sipuni',
        prewarmed: false,
        reason: error?.name || 'microphone_unavailable',
      }))
      .finally(() => {
        if (generation === this.microphonePrewarmGeneration) {
          this.microphonePrewarmPromise = null;
        }
      });

    return this.microphonePrewarmPromise;
  }

  stopMicrophonePrewarm() {
    this.microphonePrewarmGeneration += 1;
    this.clearMicrophonePrewarmTimer();
    stopMediaStream(this.microphonePrewarmStream);
    this.microphonePrewarmStream = null;
    this.microphonePrewarmPromise = null;
    return { provider: 'sipuni', stopped: true };
  }

  reportPresence(registered) {
    VoiceAPI.updateWebphonePresence(registered, {
      inboxId: this.inboxId,
    }).catch(() => {});
  }

  markRegistered() {
    this.registered = true;
    this.reportPresence(true);
    this.startPresenceHeartbeat();
  }

  startPresenceHeartbeat() {
    this.stopPresenceHeartbeat();
    this.presenceHeartbeatTimer = window.setInterval(() => {
      if (this.registered) this.reportPresence(true);
    }, WEBPHONE_PRESENCE_REFRESH_INTERVAL_MS);
  }

  stopPresenceHeartbeat() {
    if (!this.presenceHeartbeatTimer) return;

    window.clearInterval(this.presenceHeartbeatTimer);
    this.presenceHeartbeatTimer = null;
  }

  async destroyDevice({
    preserveMicrophonePrewarm = false,
    preserveSessionConfig = false,
  } = {}) {
    const currentHandle = this.sipHandle;
    const currentJanus = this.janus;
    const shouldReportOffline =
      this.initialized || this.registered || Boolean(currentHandle);

    this.sipHandle = null;
    this.janus = null;
    this.initialized = false;
    this.registered = false;
    this.registrationPromise = null;
    this.registrationResolve = null;
    this.registrationReject = null;
    this.stopPresenceHeartbeat();
    this.clearOutboundSetupTimer();
    if (shouldReportOffline) this.reportPresence(false);
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    if (!preserveMicrophonePrewarm) this.stopMicrophonePrewarm();
    this.stopLocalTracks();
    this.resetCurrentCall();
    this.remoteTracks = {};
    this.rebuildRemoteStream();

    if (!preserveSessionConfig) {
      this.sessionConfig = null;
      this.sessionSignature = null;
      this.inboxId = null;
    }

    try {
      currentHandle?.send?.({ message: { request: 'unregister' } });
      currentHandle?.detach?.();
    } catch {
      // Janus detach is best-effort during route changes and reloads.
    }

    this.destroyingDevice = true;
    try {
      currentJanus?.destroy?.();
    } finally {
      this.destroyingDevice = false;
    }
  }
}

JanusSipuniVoiceClient.initPromise = null;

export default new JanusSipuniVoiceClient();
