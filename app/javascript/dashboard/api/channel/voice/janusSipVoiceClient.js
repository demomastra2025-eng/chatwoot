import Janus from 'janus-gateway';
import * as webRTCAdapterModule from 'webrtc-adapter';
import VoiceAPI from './voiceAPIClient';
import JanusAiMediaBridge from './janusAiMediaBridge';

const createCallDisconnectedEvent = detail =>
  new CustomEvent('call:disconnected', { detail });

const createCallIncomingEvent = detail =>
  new CustomEvent('call:incoming', { detail });

const createCallConnectedEvent = detail =>
  new CustomEvent('call:connected', { detail });

const createCallRegisteredEvent = detail =>
  new CustomEvent('call:registered', { detail });

const createCallUnregisteredEvent = detail =>
  new CustomEvent('call:unregistered', { detail });

const createCallStageEvent = detail =>
  new CustomEvent('call:stage', { detail });

const WEBPHONE_PRESENCE_REFRESH_INTERVAL_MS = 30_000;
const WEBPHONE_SIP_REGISTRATION_REFRESH_INTERVAL_MS = 60_000;
const WEBPHONE_REGISTRATION_TIMEOUT_MS = 8_000;
const WEBPHONE_INCOMING_CALL_WAIT_MS = 20_000;
const WEBPHONE_INCOMING_CALL_POLL_MS = 100;
const WEBPHONE_INCOMING_ACCEPT_TIMEOUT_MS = 10_000;
const WEBPHONE_MICROPHONE_PREWARM_TTL_MS = 90_000;
const WEBPHONE_MICROPHONE_PREWARM_TIMEOUT_MS = 10_000;
const WEBPHONE_MICROPHONE_PREWARM_CANCEL_WAIT_MS = 500;
const WEBPHONE_MICROPHONE_RELEASE_SETTLE_MS = 150;
const WEBPHONE_OUTBOUND_START_TIMEOUT_MS = 20_000;
const WEBPHONE_OUTBOUND_SETUP_TIMEOUT_MS = 45_000;
const WEBPHONE_POST_CALL_REGISTRATION_REFRESH_DELAY_MS = 250;
const WEBPHONE_BROWSER_FALLBACK_RECORDING_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
]);
const WEBPHONE_RECORDING_MIME_TYPES = [
  'audio/webm;codecs=opus',
  'audio/webm',
  'audio/ogg;codecs=opus',
  'audio/ogg',
];
const WEBPHONE_RECORDING_AUDIO_BITS_PER_SECOND = 128_000;
const WEBPHONE_RECORDING_LOCAL_GAIN = 1;
const WEBPHONE_RECORDING_REMOTE_GAIN = 1;
const WEBPHONE_RECORDING_MAX_GAIN = 3;
const WEBPHONE_AUDIO_CAPTURE_CONSTRAINTS = {
  autoGainControl: true,
  channelCount: 1,
  echoCancellation: true,
  noiseSuppression: true,
  sampleRate: 48_000,
};

const screenSharingExtension = {
  init: () => {},
  isInstalled: () => true,
  getScreen: callback =>
    callback(new Error('Screen sharing is not supported for Janus SIP calls')),
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

const wait = ms =>
  new Promise(resolve => {
    window.setTimeout(resolve, ms);
  });

const hasLiveAudioTrack = stream => {
  if (!stream || typeof stream.getAudioTracks !== 'function') return false;

  return stream.getAudioTracks().some(track => track.readyState !== 'ended');
};

const getMediaDevices = () => {
  if (typeof navigator === 'undefined') return null;
  return navigator.mediaDevices || null;
};

export class JanusSipVoiceClient extends EventTarget {
  constructor() {
    super();
    this.janus = null;
    this.janusGeneration = 0;
    this.handledJanusFailureGeneration = null;
    this.sipHandle = null;
    this.sipHandleGeneration = 0;
    this.sipHandleRecoveryPromise = null;
    this.remoteAudioElement = null;
    this.remoteStream = null;
    this.remoteTracks = {};
    this.localTracks = {};
    this.sessionConfig = null;
    this.sessionSignature = null;
    this.sessionKey = null;
    this.sipProfileId = null;
    this.inboxId = null;
    this.janusUniqueId = null;
    this.janusMasterId = null;
    this.registrationInstanceId = null;
    this.initialized = false;
    this.initializationPromise = null;
    this.registered = false;
    this.registrationPromise = null;
    this.registrationAckPromise = null;
    this.registrationResolve = null;
    this.registrationReject = null;
    this.registrationTimer = null;
    this.registrationTimedOut = false;
    this.pendingIncomingCall = null;
    this.incomingAcceptPromise = null;
    this.incomingAcceptResolve = null;
    this.incomingAcceptReject = null;
    this.incomingAcceptTimer = null;
    this.hasActiveCall = false;
    this.presenceHeartbeatTimer = null;
    this.sipRegistrationRefreshTimer = null;
    this.presenceRefreshPromise = null;
    this.sipRegistrationRefreshPromise = null;
    this.presenceReportPromise = null;
    this.presenceHeartbeatFailureCount = 0;
    this.currentCallRef = null;
    this.currentCallDirection = null;
    this.microphonePrewarmStream = null;
    this.microphonePrewarmPromise = null;
    this.microphonePrewarmTimer = null;
    this.microphonePrewarmGeneration = 0;
    this.outboundAttempt = null;
    this.outboundAttemptSequence = 0;
    this.pendingOutboundJoin = null;
    this.retiredOutboundJanusCallIds = new Set();
    this.outboundSetupTimer = null;
    this.aiMediaBridge = null;
    this.currentCallHandledByAi = false;
    this.registrationRecoveryTimer = null;
    this.registrationRecoveryPromise = null;
    this.destroyingDevice = false;
    this.callMediaAccepted = false;
    this.callConnectedDispatched = false;
    this.mediaRecorder = null;
    this.recordedChunks = [];
    this.recordingAudioContext = null;
    this.recordingDestination = null;
    this.recordingSources = [];
    this.recordingCallRef = null;
    this.recordingProvider = null;
    this.recordingDirection = null;
    this.recordingStartedAt = null;
    this.recordingMimeType = null;
    this.recordingStopping = false;
    this.janusServerRecordingStarted = false;
    this.janusServerRecordingStarting = false;
    this.janusServerRecordingFailed = false;
    this.janusServerRecordingFilename = null;
  }

  static janusServerSignature(janusServer) {
    if (!janusServer) return janusServer;

    try {
      const url = new URL(janusServer);
      // The one-time ticket rotates on every token refresh but does not change
      // the underlying Janus registration endpoint.
      url.searchParams.delete('janus_ticket');
      return url.toString();
    } catch {
      return janusServer;
    }
  }

  static normalizeSessionConfig(sessionConfig = {}) {
    const sip = sessionConfig.sip || {};
    const dialing = sessionConfig.dialing || sessionConfig.dialing_config || {};
    return {
      ...sessionConfig,
      provider:
        sessionConfig.provider ||
        sessionConfig.provider_kind ||
        sessionConfig.providerKind ||
        sip.provider ||
        null,
      callingSupported:
        sessionConfig.callingSupported ??
        sessionConfig.calling_supported ??
        true,
      janusServer: sessionConfig.janusServer || sessionConfig.janus_server,
      iceServers: sessionConfig.iceServers || sessionConfig.ice_servers || [],
      sessionKey:
        sessionConfig.sessionKey ||
        sessionConfig.session_key ||
        sessionConfig.webphoneSessionKey ||
        sessionConfig.webphone_session_key,
      sipProfileId:
        sessionConfig.sipProfileId || sessionConfig.sip_profile_id || null,
      registrationConfigVersion:
        sessionConfig.registrationConfigVersion ||
        sessionConfig.registration_config_version ||
        null,
      accountId: sessionConfig.accountId || sessionConfig.account_id || null,
      inboxId: sessionConfig.inboxId || sessionConfig.inbox_id || null,
      recordingStrategy:
        sessionConfig.recordingStrategy ||
        sessionConfig.recording_strategy ||
        null,
      recordingFallbackStrategy:
        sessionConfig.recordingFallbackStrategy ||
        sessionConfig.recording_fallback_strategy ||
        null,
      janusRecording:
        sessionConfig.janusRecording || sessionConfig.janus_recording || {},
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
        outboundDialFormat:
          sip.outboundDialFormat ||
          sip.outbound_dial_format ||
          dialing.outboundDialFormat ||
          dialing.outbound_dial_format ||
          sessionConfig.outboundDialFormat ||
          sessionConfig.outbound_dial_format,
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
        (sip.uri || JanusSipVoiceClient.sipUri(sip.username, sip.host))
    );
  }

  static sipUri(username, host) {
    if (!username || !host) return null;
    return `sip:${username}@${host}`;
  }

  static dialTarget(
    toNumber,
    { provider = null, outboundDialFormat = null } = {}
  ) {
    const target = String(toNumber || '')
      .replace(/^tel:/i, '')
      .replace(/[^\d+]/g, '');

    if (
      ['kazakhstan_trunk', 'kz_trunk', 'national_trunk_8'].includes(
        outboundDialFormat
      )
    ) {
      return target.replace(/^\+?7(?=\d{10}$)/, '8');
    }

    if (['e164', 'e164_plus', 'plus_e164'].includes(outboundDialFormat)) {
      if (/^8(?=\d{10}$)/.test(target)) return target.replace(/^8/, '+7');
      if (/^7(?=\d{10}$)/.test(target)) return `+${target}`;
      return target;
    }

    if (provider === 'asterisk_analog') {
      return target.replace(/^\+/, '');
    }

    return target;
  }

  static dialUri(
    toNumber,
    host,
    { provider = null, outboundDialFormat = null } = {}
  ) {
    const target = JanusSipVoiceClient.dialTarget(toNumber, {
      provider,
      outboundDialFormat,
    });
    if (!target || !host) return null;
    return `sip:${target}@${host}`;
  }

  static initJanus() {
    if (Janus.initDone) return Promise.resolve();
    if (JanusSipVoiceClient.initPromise) {
      return JanusSipVoiceClient.initPromise;
    }

    JanusSipVoiceClient.initPromise = new Promise(resolve => {
      Janus.init({
        debug: false,
        dependencies: createJanusDependencies(),
        callback: resolve,
      });
    });
    return JanusSipVoiceClient.initPromise;
  }

  currentProvider() {
    return this.sessionConfig?.provider || null;
  }

  sessionState(sessionConfig = this.sessionConfig) {
    const normalized =
      JanusSipVoiceClient.normalizeSessionConfig(sessionConfig);
    return {
      provider: normalized.provider,
      sessionKey: normalized.sessionKey,
      sipProfileId: normalized.sipProfileId,
      registrationConfigVersion: normalized.registrationConfigVersion,
      inboxId: this.inboxId || normalized.inboxId,
      callingSupported: normalized.callingSupported !== false,
      registered: this.registered,
      pendingIncomingCall: Boolean(this.pendingIncomingCall),
      internalExtension: normalized.sip?.internalExtension,
      recordingStrategy: normalized.recordingStrategy,
      recordingFallbackStrategy: normalized.recordingFallbackStrategy,
    };
  }

  async initializeDevice(sessionConfig, { inboxId = null } = {}) {
    if (this.sipHandleRecoveryPromise) {
      await this.sipHandleRecoveryPromise;
    }
    if (this.initializationPromise) return this.initializationPromise;

    this.initializationPromise = this.performInitializeDevice(sessionConfig, {
      inboxId,
    }).finally(() => {
      this.initializationPromise = null;
    });

    return this.initializationPromise;
  }

  async performInitializeDevice(sessionConfig, { inboxId = null } = {}) {
    const normalized =
      JanusSipVoiceClient.normalizeSessionConfig(sessionConfig);
    const resolvedInboxId = inboxId || normalized.inboxId || null;

    if (!normalized.callingSupported) {
      await this.destroyDevice({
        preserveMicrophonePrewarm: true,
      });
      this.sessionConfig = normalized;
      this.sessionKey = normalized.sessionKey;
      this.sipProfileId = normalized.sipProfileId;
      this.inboxId = resolvedInboxId;
      return this.sessionState(normalized);
    }

    if (!JanusSipVoiceClient.hasCompleteContract(normalized)) {
      await this.destroyDevice({
        preserveMicrophonePrewarm: true,
      });
      this.sessionConfig = normalized;
      this.sessionKey = normalized.sessionKey;
      this.sipProfileId = normalized.sipProfileId;
      this.inboxId = resolvedInboxId;
      throw new Error('Browser calling is not configured for this SIP agent');
    }

    const signature = JSON.stringify({
      janusServer: JanusSipVoiceClient.janusServerSignature(
        normalized.janusServer
      ),
      sipUri: normalized.sip.uri,
      username: normalized.sip.username,
      host: normalized.sip.host,
      proxy: normalized.sip.proxy,
      inboxId: resolvedInboxId,
      sessionKey: normalized.sessionKey,
      sipProfileId: normalized.sipProfileId,
      registrationConfigVersion: normalized.registrationConfigVersion,
      internalExtension: normalized.sip.internalExtension,
    });

    if (this.initialized && this.sessionSignature === signature) {
      this.sessionConfig = normalized;
      this.sessionKey = normalized.sessionKey;
      this.sipProfileId = normalized.sipProfileId;
      this.inboxId = resolvedInboxId;
      await this.ensureRegistered();
      return this.sessionState(normalized);
    }

    await this.destroyDevice({
      preserveMicrophonePrewarm: true,
    });
    const initializationGeneration = this.janusGeneration;

    this.sessionConfig = normalized;
    this.sessionKey = normalized.sessionKey;
    this.sipProfileId = normalized.sipProfileId;
    this.inboxId = resolvedInboxId;
    this.sessionSignature = signature;
    this.remoteAudioElement = this.ensureRemoteAudioElement();
    await JanusSipVoiceClient.initJanus();
    if (initializationGeneration !== this.janusGeneration) {
      throw new Error('stale_janus_initialization');
    }
    const expectedJanusGeneration = initializationGeneration + 1;
    const janus = await this.createJanusSession(normalized);
    if (expectedJanusGeneration !== this.janusGeneration) {
      janus?.destroy?.();
      throw new Error('stale_janus_session');
    }
    this.janus = janus;
    const expectedSipHandleGeneration = this.sipHandleGeneration + 1;
    const sipHandle = await this.attachSipPlugin();
    if (
      expectedJanusGeneration !== this.janusGeneration ||
      expectedSipHandleGeneration !== this.sipHandleGeneration
    ) {
      sipHandle?.detach?.();
      throw new Error('stale_sip_handle');
    }
    this.sipHandle = sipHandle;
    await this.register();
    if (
      expectedJanusGeneration !== this.janusGeneration ||
      expectedSipHandleGeneration !== this.sipHandleGeneration
    ) {
      throw new Error('stale_sip_registration');
    }
    this.initialized = true;

    return this.sessionState(normalized);
  }

  createJanusSession(sessionConfig) {
    this.janusGeneration += 1;
    const generation = this.janusGeneration;
    let connected = false;
    return new Promise((resolve, reject) => {
      const janus = new Janus({
        server: sessionConfig.janusServer,
        iceServers: sessionConfig.iceServers,
        success: () => {
          if (generation !== this.janusGeneration) {
            janus?.destroy?.();
            reject(new Error('stale_janus_session'));
            return;
          }
          connected = true;
          resolve(janus);
        },
        error: error => {
          if (!connected) {
            reject(error);
            return;
          }
          if (generation === this.janusGeneration) {
            this.handleJanusDestroyed({
              reason: 'janus_transport_error',
              error,
            });
          }
        },
        destroyed: () => {
          if (generation === this.janusGeneration) {
            const error = new Error('janus_destroyed');
            this.handleJanusDestroyed({
              reason: 'janus_destroyed',
              error,
            });
            if (!connected) reject(error);
          }
        },
      });
    });
  }

  attachSipPlugin() {
    const janusGeneration = this.janusGeneration;
    this.sipHandleGeneration += 1;
    const sipHandleGeneration = this.sipHandleGeneration;
    const isCurrent = () =>
      janusGeneration === this.janusGeneration &&
      sipHandleGeneration === this.sipHandleGeneration;
    const ifCurrent =
      callback =>
      (...args) => {
        if (isCurrent()) callback(...args);
      };
    return new Promise((resolve, reject) => {
      this.janus.attach({
        plugin: 'janus.plugin.sip',
        opaqueId: `janus-sip-${Date.now()}`,
        success: pluginHandle => {
          if (isCurrent()) {
            resolve(pluginHandle);
            return;
          }
          pluginHandle?.detach?.();
          reject(new Error('stale_sip_handle'));
        },
        error: error => reject(error),
        onmessage: ifCurrent((msg, jsep) => this.handleSipMessage(msg, jsep)),
        onlocaltrack: ifCurrent((track, on) =>
          this.handleLocalTrack(track, on)
        ),
        onremotetrack: ifCurrent((track, mid, on) =>
          this.handleRemoteTrack(track, mid, on)
        ),
        oncleanup: ifCurrent(() => this.handlePeerCleanup()),
        mediaState: ifCurrent((medium, on) =>
          this.handleMediaState(medium, on)
        ),
        webrtcState: ifCurrent(on => {
          if (!on && this.hasActiveCall) this.handleCallDisconnected();
        }),
      });
    });
  }

  register({ refresh = false } = {}) {
    if (!this.sipHandle || !this.sessionConfig) return Promise.resolve();
    if (this.registrationPromise) return this.registrationPromise;

    const sip = this.sessionConfig.sip;
    const register = {
      request: 'register',
      username: sip.uri || JanusSipVoiceClient.sipUri(sip.username, sip.host),
      authuser: sip.authUsername,
      display_name: sip.displayName,
      secret: sip.password,
      proxy: sip.proxy,
    };
    if (refresh) register.refresh = true;

    this.registrationTimedOut = false;

    const registrationPromise = new Promise((resolve, reject) => {
      this.registrationResolve = resolve;
      this.registrationReject = reject;
      this.registrationTimer = window.setTimeout(() => {
        this.registrationTimedOut = true;
        const error = new Error('sip_registration_timeout');
        this.transitionToUnregistered('sip_registration_timeout');
        reject(error);
      }, WEBPHONE_REGISTRATION_TIMEOUT_MS);

      try {
        this.sipHandle.send({ message: register });
      } catch (error) {
        reject(error);
      }
    });
    const trackedRegistrationPromise = registrationPromise.finally(() => {
      if (this.registrationPromise !== trackedRegistrationPromise) return;

      this.clearRegistrationTimer();
      this.registrationPromise = null;
      this.registrationResolve = null;
      this.registrationReject = null;
    });
    this.registrationPromise = trackedRegistrationPromise;

    return trackedRegistrationPromise;
  }

  clearRegistrationTimer() {
    if (!this.registrationTimer) return;

    window.clearTimeout(this.registrationTimer);
    this.registrationTimer = null;
  }

  async ensureRegistered({ refresh = false } = {}) {
    if (this.sipHandleRecoveryPromise) {
      await this.sipHandleRecoveryPromise;
    }
    if (!this.janus || !this.sipHandle) {
      throw new Error('sip_device_not_ready');
    }
    if (this.registered) {
      if (refresh) return this.register({ refresh: true });
      return undefined;
    }
    return this.register();
  }

  recoverSipHandleAfterOutboundFailure() {
    if (this.sipHandleRecoveryPromise) return this.sipHandleRecoveryPromise;
    if (
      !this.janus ||
      !this.sessionConfig ||
      this.destroyingDevice ||
      !JanusSipVoiceClient.hasCompleteContract(this.sessionConfig)
    ) {
      return Promise.resolve(false);
    }

    const currentJanus = this.janus;
    const currentHandle = this.sipHandle;
    const recoveryPromise = (async () => {
      this.transitionToUnregistered('outbound_sip_handle_reset');
      this.initialized = false;
      this.registrationAckPromise = null;
      this.janusGeneration += 1;
      this.sipHandleGeneration += 1;
      this.janus = null;
      this.sipHandle = null;

      try {
        currentHandle?.send?.({ message: { request: 'unregister' } });
      } catch {
        // The failed handle may already reject SIP messages.
      }
      try {
        currentHandle?.detach?.();
      } catch {
        // The failed handle may already be detached.
      }
      try {
        currentJanus?.destroy?.();
      } catch {
        // Generation fencing makes delayed callbacks from this session stale.
      }

      return false;
    })();

    const trackedRecoveryPromise = recoveryPromise.finally(() => {
      if (this.sipHandleRecoveryPromise === trackedRecoveryPromise) {
        this.sipHandleRecoveryPromise = null;
      }
    });
    this.sipHandleRecoveryPromise = trackedRecoveryPromise;
    return trackedRecoveryPromise;
  }

  handleSipMessage(msg = {}, jsep = null) {
    const error = msg.error;
    if (error) {
      if (this.janusServerRecordingStarting) {
        this.markJanusServerRecordingStartFailed();
        return;
      }

      const normalizedError = String(error).toLowerCase();
      if (normalizedError.includes('already registered')) {
        if (this.registrationTimedOut) return;

        this.completeRegistration({}, msg);
        return;
      }

      if (
        normalizedError.includes('register first') ||
        normalizedError.includes('not registered')
      ) {
        this.transitionToUnregistered(String(error));
      }

      this.registrationReject?.(new Error(String(error)));
      this.rejectIncomingAccept(new Error(String(error)));
      if (this.outboundAttempt && !this.outboundAttempt.startSettled) {
        this.failOutboundAttempt(
          this.outboundAttemptError('sip_outbound_call_failed', {
            cause: error,
          })
        );
        return;
      }
      if (this.hasActiveCall || this.pendingIncomingCall) {
        this.handleCallDisconnected();
      }
      return;
    }

    const result = msg.result || {};
    const event = result.event;
    const callId = msg.call_id || result.call_id || result.callId;

    if (
      this.janusServerRecordingStarting &&
      this.janusServerRecordingStartedEvent(result)
    ) {
      this.markJanusServerRecordingStarted();
      return;
    }

    if (
      this.janusServerRecordingStarted &&
      this.janusServerRecordingStoppedEvent(result)
    ) {
      this.resetJanusServerRecordingState();
      return;
    }

    if (event === 'registration_failed') {
      const reason = `${result.code || ''} ${result.reason || ''}`.trim();
      this.clearRegistrationTimer();
      const registrationError = Object.assign(
        new Error(reason || 'sip_registration_failed'),
        {
          sipCode: result.code,
          sipReason: result.reason,
        }
      );
      this.transitionToUnregistered(reason || 'sip_registration_failed', {
        sipCode: result.code,
        sipReason: result.reason,
      });
      this.registrationReject?.(registrationError);
      return;
    }

    if (event === 'unregistered') {
      this.transitionToUnregistered(result.reason || 'sip_unregistered', {
        sipCode: result.code,
        sipReason: result.reason,
      });
      return;
    }

    if (event === 'registered') {
      if (this.registrationTimedOut) return;

      this.completeRegistration(result, msg);
      return;
    }

    if (event === 'incomingcall') {
      if (this.cancelPendingOutboundJoin('incoming_call_preempted')) {
        this.resetCurrentCall();
      }
      if (this.outboundAttempt && !this.outboundAttempt.sipCallSent) {
        this.failOutboundAttempt(
          this.outboundAttemptError('incoming_call_preempted')
        );
      }
      this.pendingIncomingCall = {
        jsep,
        result,
        callId,
        offerless: !jsep,
      };
      this.currentCallRef = this.currentCallRef || callId;
      this.currentCallDirection = 'inbound';
      this.callMediaAccepted = false;
      this.dispatchEvent(
        createCallIncomingEvent({
          ...this.sessionEventDetail(),
          callRef: this.currentCallRef,
          from: result.username || result.displayname,
        })
      );
      return;
    }

    if (event === 'calling') {
      if (!this.outboundAttempt || this.currentCallDirection !== 'outbound') {
        return;
      }
      if (!this.isCurrentOutboundJanusEvent(callId)) return;

      this.captureOutboundJanusCallId(callId);
      this.hasActiveCall = true;
      this.resolveOutboundAttemptStart('calling');
      this.scheduleOutboundSetupTimeout();
      this.dispatchCallStage('calling', { janusCallId: callId });
      return;
    }

    if (event === 'ringing') {
      if (!this.outboundAttempt || this.currentCallDirection !== 'outbound') {
        return;
      }
      if (!this.isCurrentOutboundJanusEvent(callId)) return;

      this.captureOutboundJanusCallId(callId);
      this.hasActiveCall = true;
      this.resolveOutboundAttemptStart('ringing');
      this.dispatchCallStage('ringing', { janusCallId: callId });
      return;
    }

    if (event === 'progress') {
      if (!this.outboundAttempt || this.currentCallDirection !== 'outbound') {
        return;
      }
      if (!this.isCurrentOutboundJanusEvent(callId)) return;

      this.captureOutboundJanusCallId(callId);
      this.clearOutboundSetupTimer();
      if (jsep) this.handleRemoteJsep(jsep);
      this.hasActiveCall = true;
      this.resolveOutboundAttemptStart('progress');
      this.dispatchCallStage('progress', { janusCallId: callId });
      this.playRemoteAudio();
      return;
    }

    if (event === 'accepted') {
      const isOutboundAccept =
        this.currentCallDirection === 'outbound' && this.outboundAttempt;
      const isInboundAccept =
        this.currentCallDirection === 'inbound' &&
        (this.pendingIncomingCall || this.incomingAcceptPromise);
      if (!isOutboundAccept && !isInboundAccept) return;
      if (isOutboundAccept && !this.isCurrentOutboundJanusEvent(callId)) return;

      this.captureOutboundJanusCallId(callId);
      this.clearOutboundSetupTimer();
      if (jsep) this.handleRemoteJsep(jsep);
      this.pendingIncomingCall = null;
      this.hasActiveCall = true;
      this.callMediaAccepted = true;
      this.stopMicrophonePrewarm();
      this.playRemoteAudio();
      this.startRecordingIfReady();
      this.resolveOutboundAttemptStart('accepted');
      this.dispatchCallStage('accepted', { janusCallId: callId });
      this.resolveIncomingAccept({
        ...this.sessionEventDetail(),
        callRef: this.currentCallRef,
        callDirection: this.currentCallDirection,
        answered: true,
      });
      this.dispatchCallConnected();
      return;
    }

    if (event === 'hangup') {
      if (this.currentCallDirection === 'outbound') {
        if (!this.outboundAttempt) return;
        if (!this.isCurrentOutboundJanusEvent(callId)) return;
      } else if (this.currentCallDirection !== 'inbound') {
        return;
      }

      this.clearOutboundSetupTimer();
      this.sipHandle?.hangup();
      this.rejectIncomingAccept(
        new Error(result.reason || 'incoming_call_hangup_before_accept')
      );
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
    this.startRecordingIfReady();
  }

  stopLocalTracks() {
    Object.values(this.localTracks).forEach(track => track?.stop?.());
    this.localTracks = {};
  }

  handleMediaState(medium, on) {
    if (medium !== 'audio' || !on) return;

    this.hasActiveCall = true;
    this.startRecordingIfReady();
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
    this.aiMediaBridge?.attachRemoteStream(this.remoteStream);
    this.startRecordingIfReady();
  }

  rebuildRemoteStream() {
    const tracks = Object.values(this.remoteTracks);
    this.remoteStream = tracks.length ? new MediaStream(tracks) : null;
    this.attachRemoteStream();
    this.aiMediaBridge?.attachRemoteStream(this.remoteStream);
  }

  attachRemoteStream() {
    if (this.isAiBridgeCall()) {
      this.detachRemoteAudioElement();
      return;
    }

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
    if (this.isAiBridgeCall()) return;

    const playResult = this.remoteAudioElement?.play?.();
    playResult?.catch?.(() => {});
  }

  handlePeerCleanup() {
    const hadCall =
      this.pendingIncomingCall || this.hasActiveCall || this.currentCallRef;
    if (hadCall) {
      this.handleCallDisconnected({ reason: 'remote_hangup' });
      return;
    }

    this.stopRecordings({ reason: 'peer_cleanup' });
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.stopLocalTracks();
  }

  handleJanusDestroyed({ reason = 'janus_destroyed', error = null } = {}) {
    const failedGeneration = this.janusGeneration;
    if (this.handledJanusFailureGeneration === failedGeneration) return;

    this.handledJanusFailureGeneration = failedGeneration;
    this.janusGeneration += 1;
    const hadCall =
      this.pendingIncomingCall || this.hasActiveCall || this.currentCallRef;
    const shouldRecoverDevice = !this.destroyingDevice;
    const eventDetail = this.callEventDetail();
    this.initialized = false;
    this.registered = false;
    this.clearOutboundSetupTimer();
    this.cancelPendingOutboundJoin(reason);
    this.registrationReject?.(error || new Error(reason));
    this.finishOutboundAttempt(this.outboundAttemptError(reason));
    this.rejectIncomingAccept(error || new Error(reason));
    if (shouldRecoverDevice) {
      this.transitionToUnregistered(reason, {
        transportError: error?.message || null,
      });
    } else {
      this.clearRegistrationIdentifiers();
      this.stopPresenceHeartbeat();
    }
    this.sipHandleGeneration += 1;
    this.sipHandle = null;
    this.janus = null;
    this.stopRecordings({ reason });
    this.stopAiMediaBridge();
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopLocalTracks();
    if (hadCall) {
      this.dispatchEvent(
        createCallDisconnectedEvent({ ...eventDetail, reason })
      );
    }
  }

  handleCallDisconnected(extra = {}) {
    const hadCall =
      this.pendingIncomingCall || this.hasActiveCall || this.currentCallRef;
    const detail = { ...this.callEventDetail(), ...extra };
    this.cancelPendingOutboundJoin(extra.reason || 'call_disconnected');
    this.finishOutboundAttempt(
      this.outboundAttemptError(extra.reason || 'call_disconnected')
    );
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopMicrophonePrewarm();
    this.clearOutboundSetupTimer();
    this.rejectIncomingAccept(new Error(extra.reason || 'call_disconnected'));
    this.stopRecordings({
      reason: extra.reason || 'call_disconnected',
    });
    this.stopAiMediaBridge();
    this.stopLocalTracks();
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.resetCurrentCall();
    this.schedulePostCallRegistrationRecovery();
    if (hadCall) this.dispatchEvent(createCallDisconnectedEvent(detail));
  }

  callEventDetail() {
    return {
      ...this.sessionEventDetail(),
      callRef: this.currentCallRef,
      callDirection: this.currentCallDirection,
      callMediaAccepted: this.callMediaAccepted,
      callMode: this.currentCallHandledByAi ? 'ai' : 'operator',
      aiBridge: this.currentCallHandledByAi,
    };
  }

  dispatchCallConnected() {
    if (this.callConnectedDispatched) return;

    this.callConnectedDispatched = true;
    this.dispatchEvent(createCallConnectedEvent(this.callEventDetail()));
  }

  sessionEventDetail() {
    return {
      provider: this.currentProvider(),
      sessionKey: this.sessionKey,
      sipProfileId: this.sipProfileId,
      registrationInstanceId: this.registrationInstanceId,
      registrationConfigVersion: this.sessionConfig?.registrationConfigVersion,
      inboxId: this.inboxId,
      janusSessionId: this.janusSessionId(),
      janusHandleId: this.janusHandleId(),
      janusUniqueId: this.janusUniqueId,
      janusMasterId: this.janusMasterId,
      internalExtension: this.sessionConfig?.sip?.internalExtension,
      sipUsername: this.sessionConfig?.sip?.username,
      sipHost: this.sessionConfig?.sip?.host,
      agentAor:
        this.sessionConfig?.sip?.uri ||
        JanusSipVoiceClient.sipUri(
          this.sessionConfig?.sip?.username,
          this.sessionConfig?.sip?.host
        ),
    };
  }

  janusSessionId() {
    if (typeof this.janus?.getSessionId === 'function') {
      return this.janus.getSessionId();
    }

    return this.janus?.sessionId || this.janus?.session_id || null;
  }

  janusHandleId() {
    if (typeof this.sipHandle?.getId === 'function') {
      return this.sipHandle.getId();
    }

    return this.sipHandle?.id || this.sipHandle?.handleId || null;
  }

  captureRegistrationIdentifiers(result = {}, message = {}) {
    this.janusUniqueId =
      result.unique_id ||
      result.uniqueId ||
      message.unique_id ||
      message.uniqueId ||
      this.janusUniqueId;
    this.janusMasterId =
      result.master_id ||
      result.masterId ||
      message.master_id ||
      message.masterId ||
      this.janusMasterId;
  }

  completeRegistration(result = {}, message = {}) {
    if (this.registrationAckPromise) return this.registrationAckPromise;

    const janusGeneration = this.janusGeneration;
    const sipHandleGeneration = this.sipHandleGeneration;
    this.captureRegistrationIdentifiers(result, message);
    const ackPromise = this.markRegistered()
      .then(() => {
        if (
          this.registrationTimedOut ||
          janusGeneration !== this.janusGeneration ||
          sipHandleGeneration !== this.sipHandleGeneration
        ) {
          return null;
        }

        this.clearRegistrationTimer();
        this.registrationResolve?.(this.sessionState());
        this.dispatchEvent(
          createCallRegisteredEvent(this.sessionEventDetail())
        );
        return this.sessionState();
      })
      .catch(error => {
        if (
          janusGeneration !== this.janusGeneration ||
          sipHandleGeneration !== this.sipHandleGeneration
        ) {
          return null;
        }

        this.transitionToUnregistered(
          error?.reason || error?.message || 'presence_confirmation_failed'
        );
        this.registrationReject?.(error);
        return null;
      })
      .finally(() => {
        if (this.registrationAckPromise === ackPromise) {
          this.registrationAckPromise = null;
        }
      });
    this.registrationAckPromise = ackPromise;
    return ackPromise;
  }

  transitionToUnregistered(reason = 'sip_unregistered', extra = {}) {
    const offlinePresenceContext = this.presenceContext();
    const detail = { ...this.sessionEventDetail(), reason, ...extra };
    this.registered = false;
    this.presenceHeartbeatFailureCount = 0;
    this.clearRegistrationTimer();
    this.stopPresenceHeartbeat();
    this.reportPresence(false, { context: offlinePresenceContext }).catch(
      () => null
    );
    this.clearRegistrationIdentifiers();
    this.dispatchEvent(createCallUnregisteredEvent(detail));
  }

  clearRegistrationIdentifiers() {
    this.janusUniqueId = null;
    this.janusMasterId = null;
    this.registrationInstanceId = null;
  }

  resetCurrentCall() {
    this.currentCallRef = null;
    this.currentCallDirection = null;
    this.callMediaAccepted = false;
    this.callConnectedDispatched = false;
    this.currentCallHandledByAi = false;
  }

  clearRegistrationRecoveryTimer() {
    if (!this.registrationRecoveryTimer) return;

    window.clearTimeout(this.registrationRecoveryTimer);
    this.registrationRecoveryTimer = null;
  }

  shouldRecoverRegistrationAfterCall() {
    return Boolean(
      this.initialized &&
        this.sipHandle &&
        this.sessionConfig &&
        JanusSipVoiceClient.hasCompleteContract(this.sessionConfig) &&
        !this.destroyingDevice
    );
  }

  schedulePostCallRegistrationRecovery() {
    if (!this.shouldRecoverRegistrationAfterCall()) return;

    this.clearRegistrationRecoveryTimer();
    this.registrationRecoveryTimer = window.setTimeout(() => {
      this.registrationRecoveryTimer = null;
      this.recoverRegistrationAfterCall();
    }, WEBPHONE_POST_CALL_REGISTRATION_REFRESH_DELAY_MS);
  }

  recoverRegistrationAfterCall() {
    if (this.registrationRecoveryPromise) {
      return this.registrationRecoveryPromise;
    }
    if (!this.shouldRecoverRegistrationAfterCall()) return Promise.resolve();

    const sessionConfig = this.sessionConfig;
    const janusGeneration = this.janusGeneration;
    const sipHandleGeneration = this.sipHandleGeneration;
    const recoveryPromise = this.ensureRegistered({
      refresh: this.registered,
    })
      .catch(error => {
        if (
          janusGeneration !== this.janusGeneration ||
          sipHandleGeneration !== this.sipHandleGeneration ||
          this.destroyingDevice ||
          this.pendingIncomingCall ||
          this.hasActiveCall ||
          this.currentCallRef ||
          !sessionConfig
        ) {
          return;
        }

        this.transitionToUnregistered(
          error?.message || 'post_call_registration_recovery_failed'
        );
      })
      .finally(() => {
        if (this.registrationRecoveryPromise === recoveryPromise) {
          this.registrationRecoveryPromise = null;
        }
      });
    this.registrationRecoveryPromise = recoveryPromise;

    return recoveryPromise;
  }

  beginIncomingAcceptWait() {
    this.clearIncomingAcceptWait();
    this.incomingAcceptPromise = new Promise((resolve, reject) => {
      this.incomingAcceptResolve = resolve;
      this.incomingAcceptReject = reject;
      this.incomingAcceptTimer = window.setTimeout(() => {
        this.rejectIncomingAccept(new Error('incoming_accept_timeout'));
      }, WEBPHONE_INCOMING_ACCEPT_TIMEOUT_MS);
    });
    return this.incomingAcceptPromise;
  }

  clearIncomingAcceptWait() {
    if (this.incomingAcceptTimer) {
      window.clearTimeout(this.incomingAcceptTimer);
    }
    this.incomingAcceptPromise = null;
    this.incomingAcceptResolve = null;
    this.incomingAcceptReject = null;
    this.incomingAcceptTimer = null;
  }

  resolveIncomingAccept(detail) {
    if (!this.incomingAcceptResolve) return;

    const resolve = this.incomingAcceptResolve;
    this.clearIncomingAcceptWait();
    resolve(detail);
  }

  rejectIncomingAccept(error) {
    if (!this.incomingAcceptReject) return;

    const reject = this.incomingAcceptReject;
    this.clearIncomingAcceptWait();
    reject(error);
  }

  startRecordingIfReady() {
    if (this.shouldUseJanusServerRecording()) {
      this.startJanusServerRecordingIfReady();
    }

    if (!this.shouldRecordCurrentCall()) return;
    if (this.mediaRecorder && this.mediaRecorder.state !== 'inactive') return;

    const localTracks = this.liveAudioTracks(this.localTracks);
    const remoteTracks = this.liveAudioTracks(this.remoteTracks);
    if (!localTracks.length || !remoteTracks.length) return;

    const MediaRecorderConstructor = this.mediaRecorderConstructor();
    const AudioContextConstructor = this.audioContextConstructor();
    if (!MediaRecorderConstructor || !AudioContextConstructor) return;

    try {
      this.recordingAudioContext = new AudioContextConstructor();
      this.recordingDestination =
        this.recordingAudioContext.createMediaStreamDestination();
      localTracks.forEach(track =>
        this.connectRecordingTrack(track, {
          gain: this.recordingGainValue('local'),
        })
      );
      remoteTracks.forEach(track =>
        this.connectRecordingTrack(track, {
          gain: this.recordingGainValue('remote'),
        })
      );
      this.recordingMimeType = this.preferredRecordingMimeType(
        MediaRecorderConstructor
      );
      const options = {
        audioBitsPerSecond: WEBPHONE_RECORDING_AUDIO_BITS_PER_SECOND,
        ...(this.recordingMimeType ? { mimeType: this.recordingMimeType } : {}),
      };
      this.recordedChunks = [];
      this.recordingCallRef = this.currentCallRef;
      this.recordingProvider = this.currentProvider();
      this.recordingDirection = this.currentCallDirection;
      this.recordingStartedAt = Date.now();
      this.mediaRecorder = new MediaRecorderConstructor(
        this.recordingDestination.stream,
        options
      );
      this.mediaRecorder.ondataavailable = event => {
        if (event.data?.size > 0) this.recordedChunks.push(event.data);
      };
      this.mediaRecorder.start(1000);
    } catch {
      this.resetRecordingState();
    }
  }

  shouldRecordCurrentCall() {
    const recordingStrategy =
      this.sessionConfig?.recordingStrategy ||
      this.sessionConfig?.recording_strategy;
    const fallbackStrategy =
      this.sessionConfig?.recordingFallbackStrategy ||
      this.sessionConfig?.recording_fallback_strategy ||
      this.sessionConfig?.janusRecording?.fallbackStrategy ||
      this.sessionConfig?.janusRecording?.fallback_strategy ||
      this.sessionConfig?.janus_recording?.fallbackStrategy ||
      this.sessionConfig?.janus_recording?.fallback_strategy;
    const browserFallbackRecording = recordingStrategy
      ? recordingStrategy === 'browser_fallback' ||
        (recordingStrategy === 'janus_server' &&
          fallbackStrategy === 'browser_fallback') ||
        (recordingStrategy === 'provider_api' &&
          fallbackStrategy === 'browser_fallback')
      : WEBPHONE_BROWSER_FALLBACK_RECORDING_PROVIDERS.has(
          this.currentProvider()
        );

    return (
      browserFallbackRecording &&
      this.callMediaAccepted &&
      Boolean(this.currentCallRef)
    );
  }

  shouldUseJanusServerRecording() {
    const recordingStrategy =
      this.sessionConfig?.recordingStrategy ||
      this.sessionConfig?.recording_strategy;
    const config = this.janusRecordingConfig();
    return (
      recordingStrategy === 'janus_server' &&
      config.enabled !== false &&
      !this.janusServerRecordingFailed &&
      this.callMediaAccepted &&
      Boolean(this.currentCallRef)
    );
  }

  janusRecordingConfig() {
    return (
      this.sessionConfig?.janusRecording ||
      this.sessionConfig?.janus_recording ||
      {}
    );
  }

  startJanusServerRecordingIfReady() {
    if (this.janusServerRecordingStarted || this.janusServerRecordingStarting) {
      return true;
    }

    if (this.janusServerRecordingFailed) return false;

    if (!this.sipHandle || typeof this.sipHandle.send !== 'function') {
      this.janusServerRecordingFailed = true;
      return false;
    }

    const config = this.janusRecordingConfig();
    const message = {
      request: 'recording',
      action: 'start',
      audio: config.audio !== false,
      peer_audio: config.peerAudio ?? config.peer_audio ?? true,
      filename: this.janusServerRecordingFilenameForCall(config),
    };

    try {
      this.janusServerRecordingStarting = true;
      this.janusServerRecordingStarted = false;
      this.janusServerRecordingFailed = false;
      this.janusServerRecordingFilename = message.filename;
      this.sipHandle.send({
        message,
        success: () => this.markJanusServerRecordingStarted(),
        error: () => this.markJanusServerRecordingStartFailed(),
      });
      return true;
    } catch {
      this.janusServerRecordingStarting = false;
      this.janusServerRecordingStarted = false;
      this.janusServerRecordingFailed = true;
      return false;
    }
  }

  markJanusServerRecordingStarted() {
    if (!this.janusServerRecordingStarting) return;

    this.janusServerRecordingStarting = false;
    this.janusServerRecordingStarted = true;
    this.janusServerRecordingFailed = false;
  }

  markJanusServerRecordingStartFailed() {
    this.janusServerRecordingStarting = false;
    this.janusServerRecordingStarted = false;
    this.janusServerRecordingFailed = true;
    this.startRecordingIfReady();
  }

  janusServerRecordingStartedEvent(result = {}) {
    const event = String(result.event || '').toLowerCase();
    const status = this.janusServerRecordingEventStatus(result);
    if (event === 'recording_started') return true;
    if (!['recording', 'recordingupdated'].includes(event)) return false;

    // Janus SIP emits recordingupdated without a status on successful start/stop.
    if (event === 'recordingupdated' && !status) return true;

    return [
      'active',
      'enabled',
      'ok',
      'on',
      'recording',
      'started',
      'true',
    ].includes(status);
  }

  janusServerRecordingStoppedEvent(result = {}) {
    const event = String(result.event || '').toLowerCase();
    const status = this.janusServerRecordingEventStatus(result);
    return (
      event === 'recording_stopped' ||
      (['recording', 'recordingupdated'].includes(event) &&
        ['disabled', 'false', 'off', 'stopped'].includes(status))
    );
  }

  // eslint-disable-next-line class-methods-use-this
  janusServerRecordingEventStatus(result = {}) {
    return String(
      result.recording ||
        result.recording_status ||
        result.recordingStatus ||
        result.status ||
        result.action ||
        ''
    ).toLowerCase();
  }

  janusServerRecordingFilenameForCall(config = {}) {
    const prefix =
      config.filenamePrefix || config.filename_prefix || 'onelink_janus_sip';
    const environment =
      config.environment ||
      config.recordingEnvironment ||
      config.recording_environment ||
      'default';
    const basename = [
      prefix,
      `env_${this.encodeFilenameComponent(environment)}`,
      this.currentProvider(),
      `account_${this.sessionConfig?.accountId || this.sessionConfig?.account_id || 'unknown'}`,
      `profile_${this.sipProfileId || this.sessionConfig?.sipProfileId || 'unknown'}`,
      `call_${this.encodeFilenameComponent(this.currentCallRef)}`,
      `ts_${Date.now()}`,
    ]
      .filter(value => value !== undefined && value !== null && value !== '')
      .join('_')
      .replace(/[^a-zA-Z0-9._-]/g, '_');
    const directory =
      config.recordingDirectory ||
      config.recording_directory ||
      config.directory ||
      null;

    return directory
      ? `${String(directory).replace(/\/+$/g, '')}/${basename}`
      : basename;
  }

  // eslint-disable-next-line class-methods-use-this
  encodeFilenameComponent(value) {
    const source = String(value || '');
    if (!source) return 'unknown';

    try {
      const encoded = Array.from(new TextEncoder().encode(source), byte =>
        String.fromCharCode(byte)
      ).join('');
      return btoa(encoded)
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/g, '');
    } catch {
      return source.replace(/[^a-zA-Z0-9._-]/g, '_');
    }
  }

  stopRecordings({ upload = true, reason = 'call_disconnected' } = {}) {
    this.stopJanusServerRecording();
    this.stopAndUploadRecording({ upload, reason });
  }

  stopJanusServerRecording() {
    if (!this.janusServerRecordingStarted && !this.janusServerRecordingStarting)
      return;

    try {
      this.sipHandle?.send?.({
        message: {
          request: 'recording',
          action: 'stop',
          audio: true,
          peer_audio: true,
        },
      });
    } catch {
      // Recording stop is best-effort; call cleanup must continue.
    } finally {
      this.resetJanusServerRecordingState();
    }
  }

  resetJanusServerRecordingState() {
    this.janusServerRecordingStarted = false;
    this.janusServerRecordingStarting = false;
    this.janusServerRecordingFailed = false;
    this.janusServerRecordingFilename = null;
  }

  // eslint-disable-next-line class-methods-use-this
  liveAudioTracks(tracksById) {
    return Object.values(tracksById).filter(
      track => track?.kind === 'audio' && track.readyState !== 'ended'
    );
  }

  recordingGainValue(kind) {
    const config =
      this.sessionConfig?.recordingGain ||
      this.sessionConfig?.recording_gain ||
      {};
    const key = kind === 'remote' ? 'remote' : 'local';
    const configured = Number(
      config[key] ?? config[`${key}Gain`] ?? config[`${key}_gain`]
    );
    const fallback =
      key === 'remote'
        ? WEBPHONE_RECORDING_REMOTE_GAIN
        : WEBPHONE_RECORDING_LOCAL_GAIN;
    const gain =
      Number.isFinite(configured) && configured > 0 ? configured : fallback;

    return Math.min(gain, WEBPHONE_RECORDING_MAX_GAIN);
  }

  connectRecordingTrack(track, { gain = 1 } = {}) {
    const MediaStreamConstructor = this.mediaStreamConstructor();
    if (!MediaStreamConstructor) {
      throw new Error('MediaStream is not available');
    }

    const stream = new MediaStreamConstructor([track]);
    const source = this.recordingAudioContext.createMediaStreamSource(stream);
    if (
      gain !== 1 &&
      typeof this.recordingAudioContext.createGain === 'function'
    ) {
      const gainNode = this.recordingAudioContext.createGain();
      gainNode.gain.value = gain;
      source.connect(gainNode);
      gainNode.connect(this.recordingDestination);
      this.recordingSources.push(source, gainNode);
      return;
    }

    source.connect(this.recordingDestination);
    this.recordingSources.push(source);
  }

  // eslint-disable-next-line class-methods-use-this
  mediaStreamConstructor() {
    if (typeof window === 'undefined') return null;

    return window.MediaStream || null;
  }

  // eslint-disable-next-line class-methods-use-this
  preferredRecordingMimeType(MediaRecorderConstructor) {
    if (typeof MediaRecorderConstructor.isTypeSupported !== 'function') {
      return '';
    }

    return (
      WEBPHONE_RECORDING_MIME_TYPES.find(type =>
        MediaRecorderConstructor.isTypeSupported(type)
      ) || ''
    );
  }

  // eslint-disable-next-line class-methods-use-this
  mediaRecorderConstructor() {
    if (typeof window !== 'undefined' && window.MediaRecorder) {
      return window.MediaRecorder;
    }

    if (typeof MediaRecorder !== 'undefined') return MediaRecorder;

    return null;
  }

  // eslint-disable-next-line class-methods-use-this
  audioContextConstructor() {
    if (typeof window === 'undefined') return null;

    return window.AudioContext || window.webkitAudioContext || null;
  }

  stopAndUploadRecording({ upload = true, reason = 'call_disconnected' } = {}) {
    const recorder = this.mediaRecorder;
    if (this.recordingStopping) return;

    if (!recorder || recorder.state === 'inactive') {
      this.resetRecordingState();
      return;
    }

    const callRef = this.recordingCallRef || this.currentCallRef;
    const provider = this.recordingProvider || this.currentProvider();
    const direction = this.recordingDirection || this.currentCallDirection;
    // Browser recording starts only after media acceptance, so a recorded call
    // has reached the connected state even if its terminal event is delayed.
    const terminalStatus = 'completed';
    const startedAt = this.recordingStartedAt;
    const mimeType =
      recorder.mimeType || this.recordingMimeType || 'audio/webm';

    recorder.onstop = () => {
      const chunks = [...this.recordedChunks];
      const durationMs = startedAt ? Date.now() - startedAt : null;
      this.resetRecordingState();

      if (!upload || !callRef || chunks.length === 0) return;

      const blob = new Blob(chunks, { type: mimeType });
      if (!blob.size) return;

      VoiceAPI.uploadWebphoneRecording(callRef, blob, {
        provider,
        direction,
        duration_ms: durationMs,
        reason,
        terminal_status: terminalStatus,
      }).catch(() => {
        if (direction !== 'outbound') return;

        VoiceAPI.rejectIncomingCall(callRef, {
          status: terminalStatus,
          reason,
        }).catch(() => {});
      });
    };

    try {
      this.recordingStopping = true;
      recorder.stop();
    } catch {
      this.resetRecordingState();
    }
  }

  resetRecordingState() {
    this.recordingAudioContext?.close?.().catch?.(() => {});
    this.mediaRecorder = null;
    this.recordedChunks = [];
    this.recordingAudioContext = null;
    this.recordingDestination = null;
    this.recordingSources = [];
    this.recordingCallRef = null;
    this.recordingProvider = null;
    this.recordingDirection = null;
    this.recordingStartedAt = null;
    this.recordingMimeType = null;
    this.recordingStopping = false;
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

  isAiBridgeCall() {
    return this.currentCallHandledByAi === true;
  }

  detachRemoteAudioElement() {
    if (!this.remoteAudioElement) return;

    try {
      this.remoteAudioElement.pause?.();
      if ('srcObject' in this.remoteAudioElement) {
        this.remoteAudioElement.srcObject = null;
      }
      this.remoteAudioElement.removeAttribute?.('src');
      this.remoteAudioElement.load?.();
    } catch {
      // Audio element cleanup must not interrupt SIP media handling.
    }
  }

  pendingIncomingCallRef(incomingCall = this.pendingIncomingCall) {
    if (!incomingCall) return null;

    return (
      incomingCall.callId ||
      incomingCall.result?.call_id ||
      incomingCall.result?.callId ||
      null
    );
  }

  pendingIncomingCallMatches({ callRef = null, strict = false } = {}) {
    const incomingCall = this.pendingIncomingCall;
    if (!incomingCall) return null;
    if (!callRef) return incomingCall;

    const expectedRef = String(callRef);
    const pendingRef = this.pendingIncomingCallRef(incomingCall);
    const refs = [
      pendingRef,
      incomingCall.result?.call_id,
      incomingCall.result?.callId,
      this.currentCallRef,
    ]
      .filter(Boolean)
      .map(String);

    if (refs.includes(expectedRef)) return incomingCall;
    if (strict) return null;

    // Provider webhook call ids and Janus SIP call ids differ. Once the
    // caller scoped us to this exact SIP profile, a single pending INVITE on
    // the handle is the authoritative browser-answer candidate.
    return incomingCall;
  }

  hasPendingIncomingCall(options = {}) {
    return Boolean(this.pendingIncomingCallMatches(options));
  }

  async waitForPendingIncomingCall(
    timeoutMs = WEBPHONE_INCOMING_CALL_WAIT_MS,
    options = {}
  ) {
    const existing = this.pendingIncomingCallMatches(options);
    if (existing) return existing;

    const deadline = Date.now() + timeoutMs;
    let incomingCall = null;
    while (!incomingCall && Date.now() < deadline) {
      // eslint-disable-next-line no-await-in-loop
      await new Promise(resolve => {
        window.setTimeout(resolve, WEBPHONE_INCOMING_CALL_POLL_MS);
      });
      incomingCall = this.pendingIncomingCallMatches(options);
    }

    return incomingCall;
  }

  async joinClientCall({
    callRef = null,
    callDirection,
    toNumber = null,
    janusCallRef = null,
  } = {}) {
    if (!this.sipHandle || !this.initialized) return null;

    const nextCallRef = callRef || this.currentCallRef;
    const nextCallDirection = callDirection || this.currentCallDirection;
    if (callDirection === 'outbound') {
      const pendingJoin = this.beginPendingOutboundJoin();
      this.currentCallRef = nextCallRef;
      this.currentCallDirection = nextCallDirection;
      try {
        await Promise.race([
          this.ensureRegistered({ refresh: true }),
          pendingJoin.cancellationPromise,
        ]);
        if (this.pendingOutboundJoin !== pendingJoin) {
          throw this.outboundAttemptError('operator_cancelled', {
            sipCallSent: false,
          });
        }
        this.pendingOutboundJoin = null;
        return await this.startOutboundCall(toNumber);
      } catch (error) {
        if (this.pendingOutboundJoin === pendingJoin) {
          this.pendingOutboundJoin = null;
        }
        if (
          !this.pendingOutboundJoin &&
          !this.outboundAttempt &&
          this.currentCallRef === nextCallRef
        ) {
          this.resetCurrentCall();
        }
        throw error;
      }
    }

    await this.ensureRegistered();
    this.currentCallRef = nextCallRef;
    this.currentCallDirection = nextCallDirection;

    const incomingCall = await this.waitForPendingIncomingCall(
      WEBPHONE_INCOMING_CALL_WAIT_MS,
      {
        callRef: janusCallRef,
        strict: Boolean(janusCallRef),
      }
    );
    if (!incomingCall) {
      this.stopMicrophonePrewarm();
      return null;
    }

    return this.acceptIncomingCall(incomingCall);
  }

  async answerAiIncomingCall({
    callRef = null,
    janusCallRef = null,
    streamUrl = null,
    stream_url = null,
  } = {}) {
    if (!this.sipHandle || !this.initialized) return null;

    await this.ensureRegistered();
    const incomingCall = await this.waitForPendingIncomingCall(
      WEBPHONE_INCOMING_CALL_WAIT_MS,
      {
        callRef: janusCallRef || callRef,
        strict: Boolean(janusCallRef || callRef),
      }
    );
    if (!incomingCall) return null;

    return this.acceptIncomingCallWithAiBridge(incomingCall, {
      callRef,
      streamUrl: streamUrl || stream_url,
    });
  }

  beginPendingOutboundJoin() {
    if (this.pendingOutboundJoin) {
      throw this.outboundAttemptError('sip_outbound_call_in_progress');
    }

    let rejectCancellation;
    const cancellationPromise = new Promise((_, reject) => {
      rejectCancellation = reject;
    });
    const pendingJoin = {
      cancellationPromise,
      rejectCancellation,
    };
    this.pendingOutboundJoin = pendingJoin;
    return pendingJoin;
  }

  cancelPendingOutboundJoin(reason = 'operator_cancelled') {
    const pendingJoin = this.pendingOutboundJoin;
    if (!pendingJoin) return false;

    this.pendingOutboundJoin = null;
    pendingJoin.rejectCancellation(
      this.outboundAttemptError(reason, { sipCallSent: false })
    );
    return true;
  }

  outboundAttemptError(reason, extra = {}) {
    return Object.assign(new Error(reason), {
      reason,
      sipCallSent: Boolean(this.outboundAttempt?.sipCallSent),
      ...extra,
    });
  }

  clearOutboundAttemptTimer(attempt = this.outboundAttempt) {
    if (!attempt?.timer) return;

    window.clearTimeout(attempt.timer);
    attempt.timer = null;
  }

  createOutboundAttempt({ handle, uri, audioTrack = null }) {
    let resolveStart;
    let rejectStart;
    const startPromise = new Promise((resolve, reject) => {
      resolveStart = resolve;
      rejectStart = reject;
    });
    const attempt = {
      token: (this.outboundAttemptSequence += 1),
      callRef: this.currentCallRef,
      handle,
      uri,
      audioTrack,
      trackAttached: false,
      janusCallId: null,
      sipCallSent: false,
      startSettled: false,
      state: 'creating_offer',
      timer: null,
      resolveStart,
      rejectStart,
      startPromise,
    };

    attempt.timer = window.setTimeout(() => {
      if (this.outboundAttempt !== attempt) return;

      const reason = attempt.sipCallSent
        ? 'sip_outbound_calling_timeout'
        : 'sip_outbound_offer_timeout';
      this.failOutboundAttempt(
        this.outboundAttemptError(reason, {
          sipCallSent: attempt.sipCallSent,
        }),
        { sendSipHangup: attempt.sipCallSent }
      );
    }, WEBPHONE_OUTBOUND_START_TIMEOUT_MS);
    this.outboundAttempt = attempt;
    return attempt;
  }

  isCurrentOutboundAttempt(attempt) {
    return Boolean(
      attempt &&
        this.outboundAttempt === attempt &&
        attempt.handle === this.sipHandle &&
        attempt.callRef === this.currentCallRef
    );
  }

  isCurrentOutboundJanusEvent(callId = null) {
    if (callId && this.retiredOutboundJanusCallIds.has(String(callId))) {
      return false;
    }
    const attempt = this.outboundAttempt;
    if (!attempt) return true;
    if (this.currentCallDirection !== 'outbound') return false;
    if (!callId || !attempt.janusCallId) return true;
    return String(callId) === String(attempt.janusCallId);
  }

  captureOutboundJanusCallId(callId = null) {
    if (!this.outboundAttempt || !callId) return;

    this.outboundAttempt.janusCallId =
      this.outboundAttempt.janusCallId || callId;
  }

  resolveOutboundAttemptStart(stage) {
    const attempt = this.outboundAttempt;
    if (!attempt || attempt.startSettled) return;

    this.clearOutboundAttemptTimer(attempt);
    attempt.startSettled = true;
    attempt.state = stage;
    attempt.audioTrack = null;
    attempt.resolveStart({
      ...this.sessionEventDetail(),
      calling: true,
      stage,
      uri: attempt.uri,
      callRef: attempt.callRef,
      janusCallId: attempt.janusCallId,
    });
  }

  finishOutboundAttempt(error = null) {
    const attempt = this.outboundAttempt;
    if (!attempt) return null;

    this.clearOutboundAttemptTimer(attempt);
    if (!attempt.startSettled) {
      attempt.startSettled = true;
      attempt.rejectStart(
        error || this.outboundAttemptError('call_disconnected')
      );
    }
    if (attempt.audioTrack && !attempt.trackAttached) {
      attempt.audioTrack.stop?.();
    }
    if (attempt.janusCallId) {
      this.retiredOutboundJanusCallIds.add(String(attempt.janusCallId));
      if (this.retiredOutboundJanusCallIds.size > 20) {
        const oldestCallId = this.retiredOutboundJanusCallIds
          .values()
          .next().value;
        this.retiredOutboundJanusCallIds.delete(oldestCallId);
      }
    }
    attempt.audioTrack = null;
    attempt.state = error ? 'failed' : 'ended';
    if (this.outboundAttempt === attempt) this.outboundAttempt = null;
    return attempt;
  }

  failOutboundAttempt(error, { sendSipHangup = false } = {}) {
    const attempt = this.outboundAttempt;
    if (!attempt) return false;

    const detail = {
      ...this.callEventDetail(),
      reason: error?.reason || error?.message || 'sip_outbound_start_failed',
      sipCallSent: attempt.sipCallSent,
    };
    this.finishOutboundAttempt(error);
    this.clearOutboundSetupTimer();

    try {
      if (sendSipHangup && attempt.sipCallSent) {
        attempt.handle?.send?.({ message: { request: 'hangup' } });
      }
      attempt.handle?.hangup?.();
    } catch {
      // The attempt is already terminal; local cleanup remains authoritative.
    }

    this.hasActiveCall = false;
    this.stopLocalTracks();
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.resetCurrentCall();
    if (detail.reason !== 'incoming_call_preempted') {
      this.recoverSipHandleAfterOutboundFailure();
    }
    this.dispatchEvent(createCallStageEvent({ ...detail, stage: 'failed' }));
    return true;
  }

  cancelOutboundAttempt(reason = 'operator_cancelled') {
    const attempt = this.outboundAttempt;
    if (!attempt) return false;

    return this.failOutboundAttempt(this.outboundAttemptError(reason), {
      sendSipHangup: attempt.sipCallSent,
    });
  }

  dispatchCallStage(stage, extra = {}) {
    this.dispatchEvent(
      createCallStageEvent({ ...this.callEventDetail(), ...extra, stage })
    );
  }

  takeMicrophonePrewarmTrack() {
    if (!hasLiveAudioTrack(this.microphonePrewarmStream)) return null;

    const stream = this.microphonePrewarmStream;
    const audioTrack = stream
      .getAudioTracks()
      .find(track => track.readyState !== 'ended');
    if (!audioTrack) return null;

    this.microphonePrewarmGeneration += 1;
    this.clearMicrophonePrewarmTimer();
    stream
      .getTracks()
      .filter(track => track !== audioTrack)
      .forEach(track => track.stop());
    this.microphonePrewarmStream = null;
    this.microphonePrewarmPromise = null;
    return audioTrack;
  }

  async startOutboundCall(toNumber) {
    const sip = this.sessionConfig.sip;
    const uri = JanusSipVoiceClient.dialUri(toNumber, sip.host, {
      provider: this.currentProvider(),
      outboundDialFormat: sip.outboundDialFormat,
    });
    if (!uri) return Promise.resolve(null);
    if (this.outboundAttempt) {
      throw this.outboundAttemptError('sip_outbound_call_in_progress');
    }

    const handle = this.sipHandle;
    if (!handle) throw new Error('sip_handle_unavailable');

    const audioTrack = this.takeMicrophonePrewarmTrack();
    this.currentCallDirection = 'outbound';
    this.callMediaAccepted = false;
    this.callConnectedDispatched = false;
    const attempt = this.createOutboundAttempt({ handle, uri, audioTrack });
    this.dispatchCallStage('preparing');

    try {
      if (!audioTrack) {
        await Promise.race([
          this.releaseMicrophonePrewarm({ settle: true }),
          attempt.startPromise,
        ]);
        if (!this.isCurrentOutboundAttempt(attempt)) {
          return attempt.startPromise;
        }
      }

      handle.createOffer({
        tracks: [
          {
            type: 'audio',
            capture: audioTrack || WEBPHONE_AUDIO_CAPTURE_CONSTRAINTS,
            recv: true,
          },
        ],
        success: jsep => {
          if (!this.isCurrentOutboundAttempt(attempt)) {
            if (!attempt.trackAttached) attempt.audioTrack?.stop?.();
            if (
              !this.outboundAttempt ||
              this.outboundAttempt.handle !== attempt.handle
            ) {
              attempt.handle?.hangup?.();
            }
            return;
          }

          attempt.trackAttached = true;
          attempt.audioTrack = null;
          attempt.state = 'call_sent';
          attempt.sipCallSent = true;
          try {
            handle.send({
              message: {
                request: 'call',
                uri,
                autoaccept_reinvites: false,
              },
              jsep,
              error: error => {
                if (!this.isCurrentOutboundAttempt(attempt)) return;
                this.failOutboundAttempt(
                  this.outboundAttemptError('sip_outbound_call_failed', {
                    cause: error,
                    sipCallSent: true,
                  }),
                  { sendSipHangup: true }
                );
              },
            });
            this.dispatchCallStage('call_sent');
          } catch (error) {
            this.failOutboundAttempt(
              this.outboundAttemptError('sip_outbound_call_failed', {
                cause: error,
                sipCallSent: true,
              }),
              { sendSipHangup: true }
            );
          }
        },
        error: error => {
          if (!this.isCurrentOutboundAttempt(attempt)) return;
          this.failOutboundAttempt(
            this.outboundAttemptError('sip_outbound_offer_failed', {
              cause: error,
            })
          );
        },
      });
    } catch (error) {
      if (!this.isCurrentOutboundAttempt(attempt)) {
        return attempt.startPromise;
      }
      this.failOutboundAttempt(
        this.outboundAttemptError('sip_outbound_offer_failed', {
          cause: error,
        })
      );
    }

    return attempt.startPromise;
  }

  async acceptIncomingCall(incomingCall) {
    await this.releaseMicrophonePrewarm({ settle: true });
    const method = incomingCall.offerless
      ? this.sipHandle.createOffer.bind(this.sipHandle)
      : this.sipHandle.createAnswer.bind(this.sipHandle);
    const accepted = this.beginIncomingAcceptWait();

    return new Promise((resolve, reject) => {
      method({
        jsep: incomingCall.jsep,
        tracks: [
          {
            type: 'audio',
            capture: WEBPHONE_AUDIO_CAPTURE_CONSTRAINTS,
            recv: true,
          },
        ],
        success: jsep => {
          this.sipHandle.send({
            message: { request: 'accept', autoaccept_reinvites: false },
            jsep,
          });
          this.pendingIncomingCall = null;
          this.hasActiveCall = true;
          resolve(accepted);
        },
        error: error => {
          this.rejectIncomingAccept(error);
          reject(error);
        },
      });
    }).then(result => result);
  }

  async acceptIncomingCallWithAiBridge(
    incomingCall,
    { callRef = null, streamUrl = null } = {}
  ) {
    this.stopAiMediaBridge();
    this.stopMicrophonePrewarm();
    const bridge = new JanusAiMediaBridge({ streamUrl });
    await bridge.start();
    const outputTrack = bridge.outputTrack();
    if (!outputTrack) throw new Error('ai_output_track_unavailable');
    this.aiMediaBridge = bridge;
    this.currentCallRef = callRef || this.currentCallRef;
    this.currentCallDirection = 'inbound';
    this.currentCallHandledByAi = true;
    this.detachRemoteAudioElement();
    this.aiMediaBridge.attachRemoteStream(this.remoteStream);
    const method = incomingCall.offerless
      ? this.sipHandle.createOffer.bind(this.sipHandle)
      : this.sipHandle.createAnswer.bind(this.sipHandle);
    const accepted = this.beginIncomingAcceptWait();

    return new Promise((resolve, reject) => {
      method({
        jsep: incomingCall.jsep,
        tracks: [{ type: 'audio', capture: outputTrack, recv: true }],
        success: jsep => {
          this.sipHandle.send({
            message: { request: 'accept', autoaccept_reinvites: false },
            jsep,
          });
          this.pendingIncomingCall = null;
          this.hasActiveCall = true;
          resolve(accepted);
        },
        error: error => {
          this.stopAiMediaBridge();
          this.rejectIncomingAccept(error);
          reject(error);
        },
      });
    }).then(result => result);
  }

  stopAiMediaBridge() {
    this.aiMediaBridge?.close?.();
    this.aiMediaBridge = null;
  }

  answerUpdate(jsep) {
    this.sipHandle?.createAnswer({
      jsep,
      // Keep the established transceiver/track. Passing capture constraints
      // here asks Janus.js to acquire a replacement microphone on every
      // re-INVITE (hold/resume included).
      tracks: [],
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
    this.stopRecordings({
      upload: false,
      reason: 'incoming_declined',
    });
    this.stopAiMediaBridge();
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopMicrophonePrewarm();
    this.stopLocalTracks();
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.resetCurrentCall();
    return { ...this.sessionEventDetail(), declined: true };
  }

  async endClientCall() {
    this.stopMicrophonePrewarm();
    this.clearOutboundSetupTimer();
    const hadCall =
      this.pendingIncomingCall ||
      this.hasActiveCall ||
      this.currentCallRef ||
      this.pendingOutboundJoin ||
      this.outboundAttempt;
    const cancelledPendingJoin = this.cancelPendingOutboundJoin();
    const cancelledOutboundAttempt = this.cancelOutboundAttempt();
    const cancelledOutboundStart =
      cancelledPendingJoin || cancelledOutboundAttempt;

    if (!this.sipHandle) {
      this.stopRecordings({ reason: 'client_hangup' });
      this.stopLocalTracks();
      this.resetCurrentCall();
      return null;
    }

    if (!cancelledOutboundStart) {
      try {
        const request = this.pendingIncomingCall ? 'decline' : 'hangup';
        this.sipHandle.send({ message: { request } });
        this.sipHandle.hangup();
      } catch {
        // Hangup is best-effort; browser tracks must still be released.
      }
    }
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopRecordings({ reason: 'client_hangup' });
    this.stopAiMediaBridge();
    this.stopLocalTracks();
    this.remoteTracks = {};
    this.rebuildRemoteStream();
    this.resetCurrentCall();
    return hadCall ? { ...this.sessionEventDetail(), ended: true } : null;
  }

  scheduleOutboundSetupTimeout() {
    this.clearOutboundSetupTimer();
    const attempt = this.outboundAttempt;
    if (!attempt?.sipCallSent) return;

    this.outboundSetupTimer = window.setTimeout(() => {
      this.outboundSetupTimer = null;
      if (
        this.outboundAttempt !== attempt ||
        this.currentCallDirection !== 'outbound'
      ) {
        return;
      }

      try {
        attempt.handle?.send?.({ message: { request: 'hangup' } });
        attempt.handle?.hangup?.();
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
      return {
        ...this.sessionEventDetail(),
        prewarmed: true,
        reused: true,
      };
    }

    if (this.microphonePrewarmPromise) return this.microphonePrewarmPromise;

    const mediaDevices = getMediaDevices();
    if (typeof mediaDevices?.getUserMedia !== 'function') {
      return {
        ...this.sessionEventDetail(),
        prewarmed: false,
        reason: 'media_devices_unavailable',
      };
    }

    const generation = this.microphonePrewarmGeneration;
    let timeoutId = null;
    const mediaRequest = mediaDevices
      .getUserMedia({
        audio: WEBPHONE_AUDIO_CAPTURE_CONSTRAINTS,
        video: false,
      })
      .then(stream => {
        if (generation !== this.microphonePrewarmGeneration) {
          stopMediaStream(stream);
          return {
            ...this.sessionEventDetail(),
            prewarmed: false,
            reason: 'cancelled',
          };
        }

        this.microphonePrewarmStream = stream;
        this.scheduleMicrophonePrewarmCleanup(ttlMs);
        return { ...this.sessionEventDetail(), prewarmed: true };
      })
      .catch(error => ({
        ...this.sessionEventDetail(),
        prewarmed: false,
        reason: error?.name || 'microphone_unavailable',
      }))
      .finally(() => {
        if (timeoutId) window.clearTimeout(timeoutId);
      });
    const timeout = new Promise(resolve => {
      timeoutId = window.setTimeout(() => {
        timeoutId = null;
        if (generation === this.microphonePrewarmGeneration) {
          this.microphonePrewarmGeneration += 1;
        }
        resolve({
          ...this.sessionEventDetail(),
          prewarmed: false,
          reason: 'microphone_timeout',
        });
      }, WEBPHONE_MICROPHONE_PREWARM_TIMEOUT_MS);
    });
    const prewarmPromise = Promise.race([mediaRequest, timeout]).finally(() => {
      if (this.microphonePrewarmPromise === prewarmPromise) {
        this.microphonePrewarmPromise = null;
      }
    });
    this.microphonePrewarmPromise = prewarmPromise;

    return prewarmPromise;
  }

  stopMicrophonePrewarm() {
    this.microphonePrewarmGeneration += 1;
    this.clearMicrophonePrewarmTimer();
    stopMediaStream(this.microphonePrewarmStream);
    this.microphonePrewarmStream = null;
    this.microphonePrewarmPromise = null;
    return { ...this.sessionEventDetail(), stopped: true };
  }

  async releaseMicrophonePrewarm({ settle = false } = {}) {
    const pendingPrewarm = this.microphonePrewarmPromise;
    const hadPrewarmedTrack = hasLiveAudioTrack(this.microphonePrewarmStream);

    this.stopMicrophonePrewarm();

    if (pendingPrewarm) {
      await Promise.race([
        pendingPrewarm.catch(() => null),
        wait(WEBPHONE_MICROPHONE_PREWARM_CANCEL_WAIT_MS),
      ]);
    }

    if (settle && (hadPrewarmedTrack || pendingPrewarm)) {
      await wait(WEBPHONE_MICROPHONE_RELEASE_SETTLE_MS);
    }

    return { ...this.sessionEventDetail(), stopped: true };
  }

  reportPresence(
    registered,
    { context = this.presenceContext(), inboxId = this.inboxId } = {}
  ) {
    const report = () =>
      VoiceAPI.updateWebphonePresence(registered, {
        inboxId,
        context,
      });

    const reportPromise = this.presenceReportPromise
      ? this.presenceReportPromise.then(report)
      : report();
    const reportTail = reportPromise.catch(() => null);
    this.presenceReportPromise = reportTail;
    reportTail.finally(() => {
      if (this.presenceReportPromise === reportTail) {
        this.presenceReportPromise = null;
      }
    });

    return reportPromise;
  }

  presenceContext() {
    const sip = this.sessionConfig?.sip || {};
    return {
      sip_profile_id: this.sipProfileId,
      registration_config_version:
        this.sessionConfig?.registrationConfigVersion,
      registration_instance_id: this.registrationInstanceId,
      account_id: this.sessionConfig?.accountId,
      inbox_id: this.inboxId || this.sessionConfig?.inboxId,
      internal_extension: sip.internalExtension,
      sip_username: sip.username,
      sip_host: sip.host,
      agent_aor: sip.uri || JanusSipVoiceClient.sipUri(sip.username, sip.host),
      session_key: this.sessionKey,
      janus_session_id: this.janusSessionId(),
      janus_handle_id: this.janusHandleId(),
      janus_unique_id: this.janusUniqueId,
      janus_master_id: this.janusMasterId,
    };
  }

  static isPresenceAcknowledged(payload = {}) {
    const accepted =
      payload?.presence_update_accepted ?? payload?.presenceUpdateAccepted;
    const registeredForRouting =
      payload?.registered_for_routing ?? payload?.registeredForRouting;
    return accepted !== false && registeredForRouting === true;
  }

  isCurrentPresenceContext(context = {}) {
    return JSON.stringify(this.presenceContext()) === JSON.stringify(context);
  }

  async markRegistered() {
    this.registrationInstanceId ||=
      window.crypto?.randomUUID?.() ||
      `webphone-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const context = this.presenceContext();
    const payload = await this.reportPresence(true, { context });
    if (!this.isCurrentPresenceContext(context)) {
      throw new Error('stale_presence_confirmation');
    }
    if (!JanusSipVoiceClient.isPresenceAcknowledged(payload)) {
      throw Object.assign(
        new Error(payload?.reason || 'presence_confirmation_failed'),
        {
          reason: payload?.reason || 'presence_confirmation_failed',
          payload,
        }
      );
    }

    this.registered = true;
    this.presenceHeartbeatFailureCount = 0;
    this.startPresenceHeartbeat();
    return payload;
  }

  startPresenceHeartbeat() {
    this.stopPresenceHeartbeat();
    this.presenceHeartbeatTimer = window.setInterval(() => {
      this.refreshPresenceRegistration();
    }, WEBPHONE_PRESENCE_REFRESH_INTERVAL_MS);
    this.sipRegistrationRefreshTimer = window.setInterval(() => {
      this.refreshSipRegistration();
    }, WEBPHONE_SIP_REGISTRATION_REFRESH_INTERVAL_MS);
  }

  refreshPresenceRegistration() {
    if (!this.registered) return Promise.resolve();
    if (this.presenceRefreshPromise) return this.presenceRefreshPromise;

    const context = this.presenceContext();
    const refreshPromise = this.reportPresence(true, { context })
      .then(payload => {
        if (!this.isCurrentPresenceContext(context)) return payload;

        if (!JanusSipVoiceClient.isPresenceAcknowledged(payload)) {
          this.transitionToUnregistered(
            payload?.reason || 'presence_lease_invalidated'
          );
        } else {
          this.presenceHeartbeatFailureCount = 0;
        }
        return payload;
      })
      .catch(() => {
        if (!this.isCurrentPresenceContext(context)) return null;

        this.presenceHeartbeatFailureCount += 1;
        if (this.presenceHeartbeatFailureCount >= 2) {
          this.transitionToUnregistered('presence_heartbeat_failed');
        }
        return null;
      })
      .finally(() => {
        if (this.presenceRefreshPromise === refreshPromise) {
          this.presenceRefreshPromise = null;
        }
      });
    this.presenceRefreshPromise = refreshPromise;

    return refreshPromise;
  }

  refreshSipRegistration() {
    if (!this.registered) return Promise.resolve();
    if (this.sipRegistrationRefreshPromise) {
      return this.sipRegistrationRefreshPromise;
    }

    const janusGeneration = this.janusGeneration;
    const sipHandleGeneration = this.sipHandleGeneration;
    const context = this.presenceContext();
    const refreshPromise = this.ensureRegistered({
      refresh: true,
    })
      .catch(error => {
        if (
          janusGeneration !== this.janusGeneration ||
          sipHandleGeneration !== this.sipHandleGeneration ||
          !this.isCurrentPresenceContext(context)
        ) {
          return null;
        }
        this.transitionToUnregistered(
          error?.message || 'sip_registration_refresh_failed'
        );
        return null;
      })
      .finally(() => {
        if (this.sipRegistrationRefreshPromise === refreshPromise) {
          this.sipRegistrationRefreshPromise = null;
        }
      });
    this.sipRegistrationRefreshPromise = refreshPromise;
    return refreshPromise;
  }

  stopPresenceHeartbeat() {
    if (this.presenceHeartbeatTimer) {
      window.clearInterval(this.presenceHeartbeatTimer);
      this.presenceHeartbeatTimer = null;
    }
    if (this.sipRegistrationRefreshTimer) {
      window.clearInterval(this.sipRegistrationRefreshTimer);
      this.sipRegistrationRefreshTimer = null;
    }
  }

  async destroyDevice({
    preserveMicrophonePrewarm = false,
    preserveSessionConfig = false,
  } = {}) {
    const destroyError = new Error('device_destroyed');
    const hadCall =
      this.pendingIncomingCall || this.hasActiveCall || this.currentCallRef;
    if (hadCall) {
      this.handleCallDisconnected({ reason: 'device_destroyed' });
    }
    this.registrationReject?.(destroyError);
    this.finishOutboundAttempt(this.outboundAttemptError('device_destroyed'));

    const currentHandle = this.sipHandle;
    const currentJanus = this.janus;
    const offlinePresenceContext = this.presenceContext();
    const shouldReportOffline =
      this.initialized || this.registered || Boolean(currentHandle);

    this.janusGeneration += 1;
    this.sipHandleGeneration += 1;
    this.sipHandleRecoveryPromise = null;
    this.retiredOutboundJanusCallIds.clear();
    this.sipHandle = null;
    this.janus = null;
    this.initialized = false;
    this.registered = false;
    this.presenceHeartbeatFailureCount = 0;
    if (shouldReportOffline) {
      this.reportPresence(false, { context: offlinePresenceContext }).catch(
        () => null
      );
    }
    this.clearRegistrationIdentifiers();
    this.registrationPromise = null;
    this.registrationAckPromise = null;
    this.registrationResolve = null;
    this.registrationReject = null;
    this.clearRegistrationTimer();
    this.clearRegistrationRecoveryTimer();
    this.stopPresenceHeartbeat();
    this.clearOutboundSetupTimer();
    this.pendingIncomingCall = null;
    this.hasActiveCall = false;
    this.stopRecordings({ reason: 'device_destroyed' });
    if (!preserveMicrophonePrewarm) this.stopMicrophonePrewarm();
    this.stopLocalTracks();
    this.resetCurrentCall();
    this.remoteTracks = {};
    this.rebuildRemoteStream();

    if (!preserveSessionConfig) {
      this.sessionConfig = null;
      this.sessionSignature = null;
      this.sessionKey = null;
      this.sipProfileId = null;
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

JanusSipVoiceClient.initPromise = null;

export const createJanusSipVoiceClient = () => new JanusSipVoiceClient();

export default new JanusSipVoiceClient();
