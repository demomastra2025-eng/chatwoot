import VoiceAPI from './voiceAPIClient';
import TwilioVoiceClient from './twilioVoiceClient';
import JanusSipVoiceClient, {
  createJanusSipVoiceClient,
} from './janusSipVoiceClient';

const WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS = [
  1_000, 2_000, 4_000, 8_000, 15_000, 30_000, 60_000, 60_000,
];
const WEBPHONE_NATIVE_SIP_RETRY_JITTER_RATIO = 0.2;
const WEBPHONE_NATIVE_SIP_CREDENTIAL_FAILURE_CODES = new Set([401, 403, 407]);
const WEBPHONE_NATIVE_SIP_STANDBY_REASON =
  'sip_profile_registration_lease_owned_by_another_tab';
const WEBPHONE_NATIVE_SIP_STANDBY_RETRY_DELAY_MS = 5_000;

const FORWARDED_EVENTS = [
  'call:connected',
  'call:disconnected',
  'call:incoming',
  'call:registered',
  'call:stage',
  'call:unregistered',
];

const NATIVE_BROWSER_SIP_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
]);

const looksLikeTwilioSession = response => {
  const session = response || {};
  return Boolean(
    session.identity ||
      session.twiml_endpoint ||
      session.account_sid ||
      Object.prototype.hasOwnProperty.call(session, 'has_twiml_app')
  );
};

const looksLikeJanusSipSession = response => {
  const session = response || {};
  return Boolean(
    session.janusServer ||
      session.janus_server ||
      session.sip ||
      session.sipUsername ||
      session.sip_username ||
      session.sipUri ||
      session.sip_uri
  );
};

const firstPresent = values =>
  values.find(value => value !== undefined && value !== null && value !== '');

class WebphoneClient extends EventTarget {
  constructor() {
    super();
    this.activeProvider = null;
    this.activeSessionKey = null;
    this.providerSessions = {};
    this.sessions = {};
    this.nativeSipClients = {};
    this.nativeSipClientGenerations = {};
    this.nativeSessionConfigs = {};
    this.nativeSessionRetryTimers = {};
    this.nativeSessionRetryState = {};
    this.nativeSessionRetryPromises = {};
    this.nativeSessionGenerations = {};
    this.bootstrapIncomingPromise = null;
    this.deviceInitializationPromises = {};
    this.janusSipClientFactory = createJanusSipVoiceClient;
    this.clients = {
      twilio: TwilioVoiceClient,
      asterisk_analog: JanusSipVoiceClient,
      sipuni: JanusSipVoiceClient,
      binotel: JanusSipVoiceClient,
      beeline: JanusSipVoiceClient,
    };

    this.subscribeClient('twilio', TwilioVoiceClient);
    this.handleBrowserOnline = () => this.resumeNativeSessions();
    // A short network transition should be recovered by Janus `claim`. Do not
    // destroy an otherwise healthy SIP handle before the transport reconnects.
    this.handleBrowserOffline = () => this.pauseNativeSessionRetries();
    this.handlePageShow = () => this.resumeNativeSessions();
    this.handleBeforeUnload = event => {
      if (!this.hasNativeCallInProgress()) return undefined;

      event.preventDefault();
      event.returnValue = '';
      return '';
    };
    this.nativeCallUnloadGuardRegistered = false;
    this.handlePageHide = event => {
      // BFCache keeps the page alive and later emits `pageshow`.
      if (event?.persisted) return;

      this.suspendNativeSessions('page_hidden', { keepalivePresence: true });
    };
    this.handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') this.resumeNativeSessions();
    };
    if (typeof window !== 'undefined') {
      window.addEventListener('online', this.handleBrowserOnline);
      window.addEventListener('offline', this.handleBrowserOffline);
      window.addEventListener('pageshow', this.handlePageShow);
      window.addEventListener('pagehide', this.handlePageHide);
    }
    if (typeof document !== 'undefined') {
      document.addEventListener(
        'visibilitychange',
        this.handleVisibilityChange
      );
    }
  }

  static isNativeSipProvider(provider) {
    return NATIVE_BROWSER_SIP_PROVIDERS.has(provider);
  }

  hasNativeCallInProgress() {
    return Object.values(this.nativeSipClients).some(
      client =>
        client?.hasActiveCall === true ||
        Boolean(client?.pendingIncomingCall) ||
        client?.outboundAttempt?.sipCallSent === true
    );
  }

  syncNativeCallUnloadGuard() {
    if (typeof window === 'undefined') return;

    const shouldRegister = this.hasNativeCallInProgress();
    if (shouldRegister === this.nativeCallUnloadGuardRegistered) return;

    const action = shouldRegister ? 'addEventListener' : 'removeEventListener';
    window[action]('beforeunload', this.handleBeforeUnload);
    this.nativeCallUnloadGuardRegistered = shouldRegister;
  }

  prepareNativeSipRuntime() {
    return this.clients.sipuni?.prepareRuntime?.() || Promise.resolve();
  }

  static nativeSipRetryDelay(attempt, random = Math.random) {
    const index = Math.min(
      Math.max(Number(attempt) || 0, 0),
      WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS.length - 1
    );
    const baseDelay = WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS[index];
    const jitter = baseDelay * WEBPHONE_NATIVE_SIP_RETRY_JITTER_RATIO;
    return Math.round(baseDelay - jitter + random() * jitter * 2);
  }

  static isPermanentNativeSipFailure(error = {}, detail = {}) {
    const status = Number(error?.response?.status || error?.status);
    const sipCode = Number(
      detail?.sipCode || detail?.sip_code || error?.sipCode || error?.sip_code
    );
    return (
      WEBPHONE_NATIVE_SIP_CREDENTIAL_FAILURE_CODES.has(status) ||
      WEBPHONE_NATIVE_SIP_CREDENTIAL_FAILURE_CODES.has(sipCode)
    );
  }

  static isNativeSipStandby(session = {}) {
    return session?.reason === WEBPHONE_NATIVE_SIP_STANDBY_REASON;
  }

  static nativeSipStandbyRetryDelay(random = Math.random) {
    const jitter =
      WEBPHONE_NATIVE_SIP_STANDBY_RETRY_DELAY_MS *
      WEBPHONE_NATIVE_SIP_RETRY_JITTER_RATIO;
    return Math.round(
      WEBPHONE_NATIVE_SIP_STANDBY_RETRY_DELAY_MS -
        jitter +
        random() * jitter * 2
    );
  }

  static resolveProvider(response = {}) {
    const explicitProvider = firstPresent([
      response?.provider,
      response?.provider_kind,
      response?.providerKind,
      response?.sip?.provider,
      response?.sip?.provider_kind,
      response?.sip?.providerKind,
    ]);
    if (explicitProvider) return explicitProvider;
    if (looksLikeTwilioSession(response)) return 'twilio';
    if (looksLikeJanusSipSession(response)) return null;

    return null;
  }

  static responseValue(response = {}, ...keys) {
    return keys
      .map(key => response[key])
      .find(value => value !== undefined && value !== null && value !== '');
  }

  static isUsableSession(session) {
    return (
      session &&
      session.callingSupported !== false &&
      session.registered !== false
    );
  }

  static responseSessions(response = {}) {
    const sessions =
      response.sessions ||
      response.webphoneSessions ||
      response.webphone_sessions ||
      response.payload?.sessions ||
      response.payload?.webphoneSessions ||
      response.payload?.webphone_sessions;

    return Array.isArray(sessions) ? sessions : [];
  }

  static responseInboxId(response = {}, fallback = null) {
    return (
      firstPresent([
        response.inboxId,
        response.inbox_id,
        response.sip?.inboxId,
        response.sip?.inbox_id,
        fallback,
      ]) || null
    );
  }

  static responseSipProfileId(response = {}) {
    return firstPresent([
      response.sipProfileId,
      response.sip_profile_id,
      response.sip?.sipProfileId,
      response.sip?.sip_profile_id,
    ]);
  }

  static responseSessionKey(
    response = {},
    { inboxId = null, provider = null } = {}
  ) {
    const explicit = firstPresent([
      response.sessionKey,
      response.session_key,
      response.webphoneSessionKey,
      response.webphone_session_key,
    ]);
    if (explicit) return String(explicit);

    const sipProfileId = WebphoneClient.responseSipProfileId(response);
    if (sipProfileId) return `sip_profile:${sipProfileId}`;

    const resolvedProvider =
      provider || WebphoneClient.resolveProvider(response);
    const resolvedInboxId = WebphoneClient.responseInboxId(response, inboxId);
    if (resolvedProvider && resolvedInboxId) {
      return `inbox:${resolvedInboxId}:${resolvedProvider}`;
    }

    return resolvedProvider ? `provider:${resolvedProvider}` : null;
  }

  subscribeClient(provider, client, { sessionKey = null } = {}) {
    FORWARDED_EVENTS.forEach(eventName => {
      client.addEventListener(eventName, event => {
        if (sessionKey && this.nativeSipClients[sessionKey] !== client) return;

        const detail = {
          provider: event.detail?.provider || provider,
          sessionKey: event.detail?.sessionKey || sessionKey,
          ...(event.detail || {}),
        };
        this.updateProviderRegistration(detail.provider, eventName, detail);
        this.syncNativeCallUnloadGuard();
        this.dispatchEvent(new CustomEvent(eventName, { detail }));
      });
    });
  }

  clearNativeSessionRetry(sessionKey) {
    if (!sessionKey) return;

    if (this.nativeSessionRetryTimers[sessionKey]) {
      window.clearTimeout(this.nativeSessionRetryTimers[sessionKey]);
    }
    delete this.nativeSessionRetryTimers[sessionKey];
  }

  nativeSessionGeneration(sessionKey) {
    return Number(this.nativeSessionGenerations[sessionKey]) || 0;
  }

  invalidateNativeSession(sessionKey) {
    if (!sessionKey) return 0;

    const generation = this.nativeSessionGeneration(sessionKey) + 1;
    this.nativeSessionGenerations[sessionKey] = generation;
    return generation;
  }

  isNativeSessionOwner(sessionKey, generation, client = null) {
    if (this.nativeSessionGeneration(sessionKey) !== generation) return false;
    return !client || this.nativeSipClients[sessionKey] === client;
  }

  nativeSessionInitializationGeneration(sessionKey) {
    const existingClient = this.nativeSipClients[sessionKey];
    const existingGeneration = this.nativeSipClientGenerations[sessionKey];
    if (existingClient && existingGeneration !== undefined) {
      return existingGeneration;
    }

    return this.invalidateNativeSession(sessionKey);
  }

  forgetNativeSessionConfig(sessionKey) {
    if (!sessionKey) return;

    this.invalidateNativeSession(sessionKey);
    this.clearNativeSessionRetry(sessionKey);
    delete this.nativeSessionConfigs[sessionKey];
    delete this.nativeSessionRetryState[sessionKey];
    delete this.nativeSessionRetryPromises[sessionKey];
  }

  rememberNativeSessionConfig(
    sessionKey,
    response = {},
    { inboxId = null, provider = null } = {}
  ) {
    const resolvedProvider =
      provider || WebphoneClient.resolveProvider(response);
    if (!WebphoneClient.isNativeSipProvider(resolvedProvider) || !sessionKey) {
      return;
    }

    this.nativeSessionConfigs[sessionKey] = {
      response,
      inboxId: WebphoneClient.responseInboxId(response, inboxId),
      provider: resolvedProvider,
    };
  }

  scheduleNativeSessionRetry(sessionKey, { immediate = false } = {}) {
    if (
      !sessionKey ||
      this.nativeSessionRetryTimers[sessionKey] ||
      this.nativeSessionRetryPromises[sessionKey]
    ) {
      return;
    }
    if (typeof navigator !== 'undefined' && navigator.onLine === false) return;

    const baseState =
      this.nativeSessionRetryState[sessionKey] ||
      this.nativeSessionConfigs[sessionKey];
    if (!baseState) return;

    const state = {
      ...baseState,
      attempt: Number(baseState.attempt) || 0,
      blocked: Boolean(baseState.blocked),
    };
    if (state.blocked) return;

    this.nativeSessionRetryState[sessionKey] = state;
    let delay = 0;
    if (!immediate) {
      delay = WebphoneClient.isNativeSipStandby(state)
        ? WebphoneClient.nativeSipStandbyRetryDelay()
        : WebphoneClient.nativeSipRetryDelay(state.attempt);
    }
    this.nativeSessionRetryTimers[sessionKey] = window.setTimeout(() => {
      this.retryNativeSession(sessionKey);
    }, delay);
  }

  static async refreshNativeSessionState(sessionKey, state) {
    const response = await VoiceAPI.getNativeWebphoneToken(state.inboxId);
    const candidates = WebphoneClient.responseSessions(response);
    const fallback = response?.payload || response;
    const freshResponse =
      candidates.find(
        candidate =>
          WebphoneClient.responseSessionKey(candidate, {
            inboxId: WebphoneClient.responseInboxId(candidate, state.inboxId),
            provider: WebphoneClient.resolveProvider(candidate),
          }) === sessionKey
      ) || fallback;
    const freshSessionKey = WebphoneClient.responseSessionKey(freshResponse, {
      inboxId: WebphoneClient.responseInboxId(freshResponse, state.inboxId),
      provider: WebphoneClient.resolveProvider(freshResponse),
    });
    if (freshSessionKey !== sessionKey) {
      throw new Error('webphone_session_refresh_mismatch');
    }

    return {
      ...state,
      response: freshResponse,
      inboxId: WebphoneClient.responseInboxId(freshResponse, state.inboxId),
      provider: WebphoneClient.resolveProvider(freshResponse),
    };
  }

  async retryNativeSession(sessionKey) {
    if (this.nativeSessionRetryPromises[sessionKey]) {
      return this.nativeSessionRetryPromises[sessionKey];
    }

    this.clearNativeSessionRetry(sessionKey);
    let state =
      this.nativeSessionRetryState[sessionKey] ||
      this.nativeSessionConfigs[sessionKey];
    if (!state || state.blocked) return null;
    const generation = this.invalidateNativeSession(sessionKey);

    const retryPromise = (async () => {
      try {
        state = await WebphoneClient.refreshNativeSessionState(
          sessionKey,
          state
        );
        if (!this.isNativeSessionOwner(sessionKey, generation)) return null;

        this.nativeSessionRetryState[sessionKey] = state;
        const session = await this.initializeFromSession(state.response, {
          inboxId: state.inboxId,
          nativeGeneration: generation,
        });
        if (!this.isNativeSessionOwner(sessionKey, generation)) return null;

        if (WebphoneClient.isNativeSipStandby(session)) {
          this.nativeSessionRetryState[sessionKey] = {
            ...state,
            reason: session.reason,
            blocked: false,
          };
          return session;
        }

        delete this.nativeSessionRetryState[sessionKey];
        return session;
      } catch (error) {
        if (!this.isNativeSessionOwner(sessionKey, generation)) return null;

        await this.destroyNativeClientForResponse(state.response, {
          inboxId: state.inboxId,
          nativeGeneration: generation,
        });
        if (!this.isNativeSessionOwner(sessionKey, generation)) return null;

        const permanent = WebphoneClient.isPermanentNativeSipFailure(error);
        state = {
          ...state,
          attempt: Math.min(
            (Number(state.attempt) || 0) + 1,
            WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS.length
          ),
          blocked: permanent,
          reason: permanent
            ? 'webphone_authorization_failed'
            : error?.message || 'webphone_session_retry_failed',
        };
        this.unsupportedSessionFromResponse(state.response, {
          inboxId: state.inboxId,
          reason:
            state.attempt >= WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS.length
              ? 'webphone_recovery_delayed'
              : state.reason,
        });
        this.nativeSessionRetryState[sessionKey] = state;
        if (!permanent) this.scheduleNativeSessionRetry(sessionKey);
        return null;
      }
    })().finally(() => {
      if (this.nativeSessionRetryPromises[sessionKey] !== retryPromise) return;

      delete this.nativeSessionRetryPromises[sessionKey];
      if (!this.isNativeSessionOwner(sessionKey, generation)) return;

      const currentState = this.nativeSessionRetryState[sessionKey];
      if (
        currentState &&
        !currentState.blocked &&
        !this.nativeSessionRetryTimers[sessionKey]
      ) {
        this.scheduleNativeSessionRetry(sessionKey);
      }
    });
    this.nativeSessionRetryPromises[sessionKey] = retryPromise;
    return retryPromise;
  }

  pauseNativeSessionRetries() {
    Object.keys(this.nativeSessionRetryTimers).forEach(sessionKey => {
      this.clearNativeSessionRetry(sessionKey);
    });
  }

  suspendNativeSessions(
    reason = 'browser_offline',
    { keepalivePresence = false } = {}
  ) {
    Object.entries(this.nativeSessionConfigs).forEach(([sessionKey, state]) => {
      this.invalidateNativeSession(sessionKey);
      this.clearNativeSessionRetry(sessionKey);
      this.nativeSessionRetryState[sessionKey] = {
        ...(this.nativeSessionRetryState[sessionKey] || state),
        reason,
      };
      this.destroyNativeClientForResponse(state.response, {
        inboxId: state.inboxId,
        destroyOptions: { keepalivePresence },
      }).catch(() => null);
      const session = this.sessions[sessionKey];
      if (session) {
        session.registered = false;
        session.reason = reason;
        this.rememberSession(session);
      }
    });
  }

  resumeNativeSessions() {
    Object.keys(this.nativeSessionConfigs).forEach(sessionKey => {
      const session = this.sessions[sessionKey];
      if (!session?.registered) {
        this.clearNativeSessionRetry(sessionKey);
        this.scheduleNativeSessionRetry(sessionKey, { immediate: true });
      }
    });
  }

  nativeSipClientFor(
    provider,
    sessionKey,
    generation = this.nativeSessionGeneration(sessionKey)
  ) {
    if (!sessionKey) return null;
    const existingClient = this.nativeSipClients[sessionKey];
    if (
      existingClient &&
      this.nativeSipClientGenerations[sessionKey] === generation
    ) {
      return existingClient;
    }
    if (existingClient) {
      delete this.nativeSipClients[sessionKey];
      delete this.nativeSipClientGenerations[sessionKey];
      Promise.resolve(existingClient.destroyDevice?.()).catch(() => null);
    }

    const client = this.janusSipClientFactory();
    this.nativeSipClients[sessionKey] = client;
    this.nativeSipClientGenerations[sessionKey] = generation;
    this.subscribeClient(provider, client, { sessionKey });
    this.syncNativeCallUnloadGuard();
    return client;
  }

  resolveSessionKey(payload = {}) {
    const explicit = firstPresent([payload.sessionKey, payload.session_key]);
    if (explicit) return String(explicit);

    const provider = payload.provider || this.activeProvider;
    const sipProfileId = firstPresent([
      payload.sipProfileId,
      payload.sip_profile_id,
    ]);
    if (sipProfileId) {
      const match = Object.values(this.sessions).find(session => {
        return (
          String(session.sipProfileId) === String(sipProfileId) &&
          (!provider || session.provider === provider)
        );
      });
      return match?.sessionKey || `sip_profile:${sipProfileId}`;
    }

    const inboxId = firstPresent([payload.inboxId, payload.inbox_id]);
    if (inboxId) {
      const match = Object.values(this.sessions).find(session => {
        return (
          String(session.inboxId) === String(inboxId) &&
          (!provider || session.provider === provider)
        );
      });
      return (
        match?.sessionKey ||
        (provider ? `inbox:${inboxId}:${provider}` : `inbox:${inboxId}`)
      );
    }

    const providerSession = provider ? this.providerSessions[provider] : null;
    return (
      providerSession?.sessionKey ||
      (!provider ? this.activeSessionKey : null) ||
      (provider ? `provider:${provider}` : null)
    );
  }

  getClient(provider, payload = {}, { createNative = false } = {}) {
    if (!provider) return null;
    if (!WebphoneClient.isNativeSipProvider(provider)) {
      return this.clients[provider] || null;
    }

    const sessionKey = this.resolveSessionKey({ ...payload, provider });
    const session = this.sessions[sessionKey];
    if (session && session.provider !== provider) return null;
    if (this.nativeSipClients[sessionKey]) {
      return this.nativeSipClients[sessionKey];
    }
    if (!createNative) return null;

    return this.nativeSipClientFor(provider, sessionKey);
  }

  getSession(
    providerOrKey = this.activeSessionKey || this.activeProvider,
    payload = {}
  ) {
    if (!providerOrKey) return null;
    const directSession = this.sessions[providerOrKey];
    if (directSession) {
      const requestedProvider = payload.provider;
      const scopeMatches =
        (!requestedProvider || directSession.provider === requestedProvider) &&
        (!payload.inboxId ||
          String(directSession.inboxId) === String(payload.inboxId)) &&
        (!payload.inbox_id ||
          String(directSession.inboxId) === String(payload.inbox_id)) &&
        (!payload.sipProfileId ||
          String(directSession.sipProfileId) ===
            String(payload.sipProfileId)) &&
        (!payload.sip_profile_id ||
          String(directSession.sipProfileId) ===
            String(payload.sip_profile_id)) &&
        (!payload.sessionKey ||
          String(directSession.sessionKey) === String(payload.sessionKey)) &&
        (!payload.session_key ||
          String(directSession.sessionKey) === String(payload.session_key));
      return scopeMatches ? directSession : null;
    }
    if (
      payload.provider &&
      String(payload.provider) !== String(providerOrKey)
    ) {
      return null;
    }

    const scopedPayload = {
      ...payload,
      provider: providerOrKey,
    };
    const sessionKey = this.resolveSessionKey(scopedPayload);
    const hasExplicitScope = Boolean(
      firstPresent([
        payload.sessionKey,
        payload.session_key,
        payload.inboxId,
        payload.inbox_id,
        payload.sipProfileId,
        payload.sip_profile_id,
      ])
    );
    const session =
      this.sessions[sessionKey] ||
      (!hasExplicitScope ? this.providerSessions[providerOrKey] : null) ||
      null;
    const scopeMatches =
      session?.provider === providerOrKey &&
      (!payload.inboxId ||
        String(session.inboxId) === String(payload.inboxId)) &&
      (!payload.inbox_id ||
        String(session.inboxId) === String(payload.inbox_id)) &&
      (!payload.sipProfileId ||
        String(session.sipProfileId) === String(payload.sipProfileId)) &&
      (!payload.sip_profile_id ||
        String(session.sipProfileId) === String(payload.sip_profile_id)) &&
      (!payload.sessionKey ||
        String(session.sessionKey) === String(payload.sessionKey)) &&
      (!payload.session_key ||
        String(session.sessionKey) === String(payload.session_key));
    return scopeMatches ? session : null;
  }

  updateProviderRegistration(provider, eventName, detail = {}) {
    const sessionKey = this.resolveSessionKey({ ...detail, provider });
    const session = this.getSession(provider, detail);
    if (!session) return;

    if (eventName === 'call:registered') {
      session.registered = true;
      session.reason = null;
      if (WebphoneClient.isNativeSipProvider(provider)) {
        this.clearNativeSessionRetry(sessionKey);
        delete this.nativeSessionRetryState[sessionKey];
      }
    } else if (eventName === 'call:unregistered') {
      session.registered = false;
      session.reason = detail.reason || 'sip_unregistered';
      if (WebphoneClient.isNativeSipProvider(provider)) {
        if (WebphoneClient.isPermanentNativeSipFailure({}, detail)) {
          this.clearNativeSessionRetry(sessionKey);
          this.nativeSessionRetryState[sessionKey] = {
            ...(this.nativeSessionConfigs[sessionKey] || {}),
            blocked: true,
            reason: 'sip_provider_credentials_failed',
          };
          session.reason = 'sip_provider_credentials_failed';
          session.callingSupported = false;
        } else {
          this.scheduleNativeSessionRetry(sessionKey);
        }
      }
    }

    this.rememberSession(session);
  }

  rememberSession(session) {
    if (!session) return;

    if (session.sessionKey) {
      this.sessions[session.sessionKey] = session;
      this.dispatchEvent(
        new CustomEvent('call:sessions-changed', {
          detail: { sessionKey: session.sessionKey, action: 'updated' },
        })
      );
    }
    if (!session.provider) return;

    const existing = this.providerSessions[session.provider];
    if (
      !existing ||
      existing.sessionKey === session.sessionKey ||
      WebphoneClient.isUsableSession(session) ||
      !WebphoneClient.isUsableSession(existing)
    ) {
      this.providerSessions[session.provider] = session;
    }
  }

  refreshProviderFallback(provider) {
    if (!provider) return;

    const candidates = Object.values(this.sessions).filter(
      session => session.provider === provider
    );
    const fallback =
      candidates.find(session => WebphoneClient.isUsableSession(session)) ||
      candidates[0];
    if (fallback) {
      this.providerSessions[provider] = fallback;
    } else {
      delete this.providerSessions[provider];
    }
  }

  supportsBrowserCalling(provider, options = {}) {
    if (!provider) return false;
    const supportedProvider =
      provider === 'twilio' || WebphoneClient.isNativeSipProvider(provider);
    if (!supportedProvider) return false;

    const session = this.getSession(provider, options);
    if (session?.callingSupported === false) return false;

    if (
      WebphoneClient.isNativeSipProvider(provider) &&
      session?.registered === false
    ) {
      return false;
    }

    if (
      WebphoneClient.isNativeSipProvider(provider) &&
      options.inboxId &&
      !session
    ) {
      return false;
    }

    return true;
  }

  bootstrapIncomingSupport() {
    if (this.bootstrapIncomingPromise) return this.bootstrapIncomingPromise;

    const bootstrapPromise = (async () => {
      const runtimePromise = this.prepareNativeSipRuntime();
      const response = await VoiceAPI.getWebphoneToken();
      await runtimePromise;
      return this.initializeResponse(response);
    })().finally(() => {
      if (this.bootstrapIncomingPromise === bootstrapPromise) {
        this.bootstrapIncomingPromise = null;
      }
    });
    this.bootstrapIncomingPromise = bootstrapPromise;

    return bootstrapPromise;
  }

  initializeDevice(
    inboxId = null,
    {
      native = false,
      provider = null,
      sipProfileId = null,
      sessionKey = null,
    } = {}
  ) {
    const initializationKey = [
      native ? 'native' : 'default',
      inboxId || 'global',
      provider || 'any',
      sipProfileId || 'any',
      sessionKey || 'any',
    ].join(':');
    const existing = this.deviceInitializationPromises[initializationKey];
    if (existing) return existing;

    const initializationPromise = (async () => {
      const runtimePromise = native
        ? this.prepareNativeSipRuntime()
        : Promise.resolve();
      const response = native
        ? await VoiceAPI.getNativeWebphoneToken(inboxId)
        : await VoiceAPI.getWebphoneToken(inboxId);
      await runtimePromise;
      return this.initializeResponse(response, {
        inboxId,
        native,
        provider,
        sipProfileId,
        sessionKey,
      });
    })().finally(() => {
      if (
        this.deviceInitializationPromises[initializationKey] ===
        initializationPromise
      ) {
        delete this.deviceInitializationPromises[initializationKey];
      }
    });
    this.deviceInitializationPromises[initializationKey] =
      initializationPromise;

    return initializationPromise;
  }

  async initializeResponse(
    response,
    {
      inboxId = null,
      native = false,
      provider = null,
      sipProfileId = null,
      sessionKey = null,
    } = {}
  ) {
    const sessions = WebphoneClient.responseSessions(response);
    if (sessions.length) {
      const results = await Promise.all(
        sessions.map(session => {
          const sessionProvider = WebphoneClient.resolveProvider(session);
          return this.initializeSessionSafely(session, {
            inboxId: WebphoneClient.responseInboxId(session, inboxId),
            native: WebphoneClient.isNativeSipProvider(sessionProvider),
          });
        })
      );
      const scopeMatches = session =>
        session &&
        (!provider || session.provider === provider) &&
        (!inboxId || String(session.inboxId) === String(inboxId)) &&
        (!sipProfileId ||
          String(session.sipProfileId) === String(sipProfileId)) &&
        (!sessionKey || String(session.sessionKey) === String(sessionKey));
      const hasRequestedScope = Boolean(
        provider || inboxId || sipProfileId || sessionKey
      );
      const selectedSession = hasRequestedScope
        ? results.find(scopeMatches) || null
        : null;
      if (hasRequestedScope && !selectedSession) return null;

      return {
        ...(selectedSession || {}),
        provider:
          selectedSession?.provider ||
          results[0]?.provider ||
          response?.provider ||
          null,
        callingSupported: selectedSession
          ? selectedSession.callingSupported
          : results.some(session => session?.callingSupported),
        registered: selectedSession
          ? selectedSession.registered
          : results.some(session => session?.registered),
        multiSession: true,
        sessions: results,
      };
    }

    const initializedSession = await this.initializeFromSession(response, {
      inboxId,
      native,
    });
    const scopeMatches =
      initializedSession &&
      (!provider || initializedSession.provider === provider) &&
      (!inboxId || String(initializedSession.inboxId) === String(inboxId)) &&
      (!sipProfileId ||
        String(initializedSession.sipProfileId) === String(sipProfileId)) &&
      (!sessionKey ||
        String(initializedSession.sessionKey) === String(sessionKey));
    return scopeMatches ? initializedSession : null;
  }

  async initializeSessionSafely(
    response,
    { inboxId = null, native = false } = {}
  ) {
    const provider = WebphoneClient.resolveProvider(response);
    const resolvedInboxId = WebphoneClient.responseInboxId(response, inboxId);
    const sessionKey = WebphoneClient.responseSessionKey(response, {
      inboxId: resolvedInboxId,
      provider,
    });
    const isNative = native || WebphoneClient.isNativeSipProvider(provider);
    const nativeGeneration = isNative
      ? this.nativeSessionInitializationGeneration(sessionKey)
      : null;

    try {
      return await this.initializeFromSession(response, {
        inboxId,
        nativeGeneration,
      });
    } catch (error) {
      if (
        isNative &&
        !this.isNativeSessionOwner(sessionKey, nativeGeneration)
      ) {
        return this.sessions[sessionKey] || null;
      }

      await this.destroyNativeClientForResponse(response, {
        inboxId,
        nativeGeneration,
      });
      if (
        isNative &&
        !this.isNativeSessionOwner(sessionKey, nativeGeneration)
      ) {
        return this.sessions[sessionKey] || null;
      }

      if (WebphoneClient.isPermanentNativeSipFailure(error)) {
        this.nativeSessionRetryState[sessionKey] = {
          ...(this.nativeSessionConfigs[sessionKey] || {}),
          blocked: true,
          reason: 'sip_provider_credentials_failed',
        };
      } else {
        this.scheduleNativeSessionRetry(sessionKey);
      }
      return this.unsupportedSessionFromResponse(response, {
        inboxId,
        reason: WebphoneClient.isPermanentNativeSipFailure(error)
          ? 'sip_provider_credentials_failed'
          : error?.message || 'webphone_session_initialization_failed',
      });
    }
  }

  async destroyNativeClientForResponse(
    response = {},
    {
      inboxId = null,
      nativeGeneration = null,
      expectedClient = null,
      destroyOptions = {},
    } = {}
  ) {
    const provider = WebphoneClient.resolveProvider(response);
    if (!WebphoneClient.isNativeSipProvider(provider)) return;

    const sessionKey = WebphoneClient.responseSessionKey(response, {
      inboxId: WebphoneClient.responseInboxId(response, inboxId),
      provider,
    });
    if (
      nativeGeneration !== null &&
      !this.isNativeSessionOwner(sessionKey, nativeGeneration)
    ) {
      return;
    }

    const client = this.nativeSipClients[sessionKey];
    if (expectedClient && client !== expectedClient) return;
    try {
      await client?.destroyDevice?.(destroyOptions);
    } finally {
      if (this.nativeSipClients[sessionKey] === client) {
        delete this.nativeSipClients[sessionKey];
        delete this.nativeSipClientGenerations[sessionKey];
      }
      this.syncNativeCallUnloadGuard();
    }
  }

  unsupportedSessionFromResponse(
    response = {},
    { inboxId = null, reason = 'webphone_session_initialization_failed' } = {}
  ) {
    const provider = WebphoneClient.resolveProvider(response);
    const resolvedInboxId = WebphoneClient.responseInboxId(response, inboxId);
    const sessionKey = WebphoneClient.responseSessionKey(response, {
      inboxId: resolvedInboxId,
      provider,
    });
    const session = {
      provider,
      sessionKey,
      inboxId: resolvedInboxId,
      sipProfileId: WebphoneClient.responseSipProfileId(response),
      callingSupported: false,
      registered: false,
      reason,
    };

    this.rememberSession(session);
    return session;
  }

  async initializeFromSession(
    response,
    { inboxId = null, nativeGeneration = null } = {}
  ) {
    const provider = WebphoneClient.resolveProvider(response);
    if (!provider) {
      return {
        provider: null,
        callingSupported: false,
      };
    }

    const resolvedInboxId = WebphoneClient.responseInboxId(response, inboxId);
    const sessionKey = WebphoneClient.responseSessionKey(response, {
      inboxId: resolvedInboxId,
      provider,
    });
    const isNative = WebphoneClient.isNativeSipProvider(provider);
    const operationGeneration = isNative
      ? (nativeGeneration ??
        this.nativeSessionInitializationGeneration(sessionKey))
      : null;
    const callingSupported =
      response?.callingSupported ?? response?.calling_supported;
    if (callingSupported === false) {
      if (isNative) {
        if (!this.isNativeSessionOwner(sessionKey, operationGeneration)) {
          return this.sessions[sessionKey] || null;
        }
        await this.destroyNativeClientForResponse(response, {
          inboxId: resolvedInboxId,
          nativeGeneration: operationGeneration,
        });
        if (!this.isNativeSessionOwner(sessionKey, operationGeneration)) {
          return this.sessions[sessionKey] || null;
        }
      } else {
        await this.getClient(provider)?.destroyDevice?.();
      }
      const resolvedSession = {
        provider,
        sessionKey,
        inboxId: resolvedInboxId,
        sipProfileId: WebphoneClient.responseSipProfileId(response),
        callingSupported: false,
        browserJoinSupported:
          response?.browserJoinSupported ?? response?.browser_join_supported,
        registered: false,
        reason: response?.reason,
      };
      this.rememberSession(resolvedSession);
      if (this.activeSessionKey === sessionKey) this.activeSessionKey = null;
      if (this.activeProvider === provider) this.activeProvider = null;
      if (isNative && WebphoneClient.isNativeSipStandby(resolvedSession)) {
        this.rememberNativeSessionConfig(sessionKey, response, {
          inboxId: resolvedInboxId,
          provider,
        });
        this.nativeSessionRetryState[sessionKey] = {
          ...this.nativeSessionConfigs[sessionKey],
          attempt: 0,
          blocked: false,
          reason: resolvedSession.reason,
        };
        this.scheduleNativeSessionRetry(sessionKey);
      } else if (isNative) {
        this.forgetNativeSessionConfig(sessionKey);
      }
      return resolvedSession;
    }

    const client = isNative
      ? this.nativeSipClientFor(provider, sessionKey, operationGeneration)
      : this.getClient(provider);
    if (!client) {
      return {
        provider,
        callingSupported: false,
      };
    }

    if (
      isNative &&
      !this.isNativeSessionOwner(sessionKey, operationGeneration, client)
    ) {
      return this.sessions[sessionKey] || null;
    }
    this.rememberNativeSessionConfig(sessionKey, response, {
      inboxId: resolvedInboxId,
      provider,
    });

    const session = await client.initializeDevice(
      {
        ...(response || {}),
        provider,
        sessionKey,
        session_key: sessionKey,
      },
      { inboxId: resolvedInboxId }
    );
    if (
      isNative &&
      !this.isNativeSessionOwner(sessionKey, operationGeneration, client)
    ) {
      return this.sessions[sessionKey] || null;
    }
    const resolvedSession = {
      provider,
      sessionKey,
      inboxId: resolvedInboxId,
      sipProfileId: WebphoneClient.responseSipProfileId(response),
      ...(session || {}),
    };

    this.rememberSession(resolvedSession);
    if (isNative) {
      this.clearNativeSessionRetry(sessionKey);
      delete this.nativeSessionRetryState[sessionKey];
    }
    if (resolvedSession.callingSupported) {
      this.activeProvider = provider;
      this.activeSessionKey = sessionKey;
    }

    return resolvedSession;
  }

  async joinClientCall(payload = {}) {
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client) return null;

    this.activeProvider = provider;
    this.activeSessionKey = sessionKey;
    return client.joinClientCall({ ...payload, sessionKey });
  }

  async answerAiIncomingCall(payload = {}) {
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client || typeof client.answerAiIncomingCall !== 'function') {
      return null;
    }

    this.activeProvider = provider;
    this.activeSessionKey = sessionKey;
    return client.answerAiIncomingCall({ ...payload, sessionKey });
  }

  hasPendingIncomingCall(payload = {}) {
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client || typeof client.hasPendingIncomingCall !== 'function') {
      return false;
    }

    return client.hasPendingIncomingCall({
      callRef: payload.janusCallRef || payload.janus_call_ref,
      strict: Boolean(payload.janusCallRef || payload.janus_call_ref),
    });
  }

  bindCurrentCallReference(payload = {}) {
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client || typeof client.bindCurrentCallReference !== 'function') {
      return false;
    }

    return client.bindCurrentCallReference({
      callRef: payload.callRef || payload.call_ref || payload.callSid,
      janusCallRef: payload.janusCallRef || payload.janus_call_ref,
    });
  }

  async waitForPendingIncomingCall(payload = {}, { timeoutMs = 2500 } = {}) {
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client || typeof client.waitForPendingIncomingCall !== 'function') {
      return null;
    }

    return client.waitForPendingIncomingCall(timeoutMs, {
      callRef: payload.janusCallRef || payload.janus_call_ref,
      strict: Boolean(payload.janusCallRef || payload.janus_call_ref),
    });
  }

  prewarmMicrophone(providerOrPayload = this.activeProvider, options = {}) {
    const payload =
      typeof providerOrPayload === 'object'
        ? providerOrPayload
        : { provider: providerOrPayload, ...options };
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client || typeof client.prewarmMicrophone !== 'function') {
      return Promise.resolve(null);
    }

    return client.prewarmMicrophone(options);
  }

  stopMicrophonePrewarm(providerOrPayload = this.activeProvider) {
    const payload =
      typeof providerOrPayload === 'object'
        ? providerOrPayload
        : { provider: providerOrPayload };
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client || typeof client.stopMicrophonePrewarm !== 'function') {
      return null;
    }

    return client.stopMicrophonePrewarm();
  }

  async rejectIncomingCall(providerOrPayload = this.activeProvider) {
    const payload =
      typeof providerOrPayload === 'object'
        ? providerOrPayload
        : { provider: providerOrPayload };
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client) return null;

    const callScope = {
      ...payload,
      callRef: payload.callRef || payload.callSid || payload.call_sid,
      janusCallRef: payload.janusCallRef || payload.janus_call_ref,
    };
    try {
      if (typeof client.rejectIncomingCall === 'function') {
        return await client.rejectIncomingCall(callScope);
      }

      return await client.endClientCall(callScope);
    } finally {
      this.syncNativeCallUnloadGuard();
    }
  }

  async endClientCall(providerOrPayload = this.activeProvider) {
    const payload =
      typeof providerOrPayload === 'object'
        ? providerOrPayload
        : { provider: providerOrPayload };
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client) return null;

    try {
      return await client.endClientCall({
        ...payload,
        callRef: payload.callRef || payload.callSid || payload.call_sid,
        janusCallRef: payload.janusCallRef || payload.janus_call_ref,
      });
    } finally {
      this.syncNativeCallUnloadGuard();
    }
  }

  nativeSessionDescriptor(sessionKey) {
    const session = this.sessions[sessionKey];
    const config = this.nativeSessionConfigs[sessionKey];
    return {
      provider: session?.provider || config?.provider,
      sessionKey,
      inboxId:
        session?.inboxId ||
        WebphoneClient.responseInboxId(config?.response, config?.inboxId),
      sipProfileId:
        session?.sipProfileId ||
        WebphoneClient.responseSipProfileId(config?.response),
    };
  }

  nativeSessionKeys() {
    return [
      ...new Set([
        ...Object.keys(this.sessions),
        ...Object.keys(this.nativeSipClients),
        ...Object.keys(this.nativeSessionConfigs),
      ]),
    ];
  }

  async destroyNativeSession(sessionKey) {
    const client = this.nativeSipClients[sessionKey];
    const provider = this.nativeSessionDescriptor(sessionKey).provider;
    const hadSession = Boolean(this.sessions[sessionKey]);
    try {
      await client?.destroyDevice?.();
    } finally {
      if (this.nativeSipClients[sessionKey] === client) {
        delete this.nativeSipClients[sessionKey];
        delete this.nativeSipClientGenerations[sessionKey];
        delete this.sessions[sessionKey];
        this.forgetNativeSessionConfig(sessionKey);
        if (
          provider &&
          this.providerSessions[provider]?.sessionKey === sessionKey
        )
          this.refreshProviderFallback(provider);
        if (this.activeSessionKey === sessionKey) this.activeSessionKey = null;
        if (
          provider &&
          this.activeProvider === provider &&
          !Object.values(this.sessions).some(
            session => session.provider === provider
          )
        ) {
          this.activeProvider = null;
        }
        if (hadSession) {
          this.dispatchEvent(
            new CustomEvent('call:sessions-changed', {
              detail: { sessionKey, action: 'removed' },
            })
          );
        }
        this.syncNativeCallUnloadGuard();
      }
    }
  }

  destroyDevice(providerOrPayload = this.activeProvider) {
    const payload =
      typeof providerOrPayload === 'object'
        ? providerOrPayload
        : { provider: providerOrPayload };
    const provider = payload.provider || this.activeProvider;

    if (WebphoneClient.isNativeSipProvider(provider)) {
      const explicitSessionKey = firstPresent([
        payload.sessionKey,
        payload.session_key,
      ]);
      const explicitInboxId = firstPresent([payload.inboxId, payload.inbox_id]);
      const explicitSipProfileId = firstPresent([
        payload.sipProfileId,
        payload.sip_profile_id,
      ]);
      const hasExplicitScope = Boolean(
        explicitSessionKey || explicitInboxId || explicitSipProfileId
      );
      const candidateKeys = this.nativeSessionKeys().filter(key => {
        const descriptor = this.nativeSessionDescriptor(key);
        return (
          descriptor.provider === provider &&
          (!explicitSessionKey || String(key) === String(explicitSessionKey)) &&
          (!explicitInboxId ||
            String(descriptor.inboxId) === String(explicitInboxId)) &&
          (!explicitSipProfileId ||
            String(descriptor.sipProfileId) === String(explicitSipProfileId))
        );
      });
      if (hasExplicitScope) {
        return candidateKeys.length === 1
          ? this.destroyNativeSession(candidateKeys[0])
          : null;
      }

      return Promise.all(
        candidateKeys.map(key => this.destroyNativeSession(key))
      );
    }

    const client = this.getClient(provider);
    if (!client || typeof client.destroyDevice !== 'function') return null;

    const sessionKey = this.resolveSessionKey({ provider });
    delete this.sessions[sessionKey];
    delete this.providerSessions[provider];
    this.forgetNativeSessionConfig(sessionKey);
    if (this.activeProvider === provider) this.activeProvider = null;
    return client.destroyDevice();
  }
}

export default new WebphoneClient();
