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
    this.janusSipClientFactory = createJanusSipVoiceClient;
    this.clients = {
      twilio: TwilioVoiceClient,
      asterisk_analog: JanusSipVoiceClient,
      sipuni: JanusSipVoiceClient,
      binotel: JanusSipVoiceClient,
    };

    this.subscribeClient('twilio', TwilioVoiceClient);
    this.handleBrowserOnline = () => this.resumeNativeSessions();
    this.handleBrowserOffline = () =>
      this.suspendNativeSessions('browser_offline');
    this.handlePageShow = () => this.resumeNativeSessions();
    this.handlePageHide = () => this.suspendNativeSessions('page_hidden');
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
    if (
      state.blocked ||
      state.attempt >= WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS.length
    ) {
      return;
    }

    this.nativeSessionRetryState[sessionKey] = state;
    const delay = immediate
      ? 0
      : WebphoneClient.nativeSipRetryDelay(state.attempt);
    this.nativeSessionRetryTimers[sessionKey] = window.setTimeout(() => {
      this.retryNativeSession(sessionKey);
    }, delay);
  }

  static async refreshNativeSessionState(sessionKey, state) {
    const response = await VoiceAPI.getWebphoneToken(state.inboxId);
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
          attempt: (Number(state.attempt) || 0) + 1,
          blocked: permanent,
          reason: permanent
            ? 'webphone_authorization_failed'
            : error?.message || 'webphone_session_retry_failed',
        };
        this.unsupportedSessionFromResponse(state.response, {
          inboxId: state.inboxId,
          reason:
            state.attempt >= WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS.length
              ? 'webphone_recovery_exhausted'
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
        currentState.attempt < WEBPHONE_NATIVE_SIP_RETRY_DELAYS_MS.length &&
        !this.nativeSessionRetryTimers[sessionKey]
      ) {
        this.scheduleNativeSessionRetry(sessionKey);
      }
    });
    this.nativeSessionRetryPromises[sessionKey] = retryPromise;
    return retryPromise;
  }

  suspendNativeSessions(reason = 'browser_offline') {
    Object.entries(this.nativeSessionConfigs).forEach(([sessionKey, state]) => {
      this.invalidateNativeSession(sessionKey);
      this.clearNativeSessionRetry(sessionKey);
      this.nativeSessionRetryState[sessionKey] = {
        ...(this.nativeSessionRetryState[sessionKey] || state),
        reason,
      };
      this.destroyNativeClientForResponse(state.response, {
        inboxId: state.inboxId,
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
      const match = Object.values(this.sessions).find(
        session => String(session.sipProfileId) === String(sipProfileId)
      );
      if (match?.sessionKey) return match.sessionKey;
    }

    const inboxId = firstPresent([payload.inboxId, payload.inbox_id]);
    if (inboxId) {
      const match = Object.values(this.sessions).find(session => {
        return (
          String(session.inboxId) === String(inboxId) &&
          (!provider || session.provider === provider)
        );
      });
      if (match?.sessionKey) return match.sessionKey;
    }

    const providerSession = provider ? this.providerSessions[provider] : null;
    return (
      providerSession?.sessionKey ||
      this.activeSessionKey ||
      (provider ? `provider:${provider}` : null)
    );
  }

  getClient(provider, payload = {}, { createNative = false } = {}) {
    if (!provider) return null;
    if (!WebphoneClient.isNativeSipProvider(provider)) {
      return this.clients[provider] || null;
    }

    const sessionKey = this.resolveSessionKey({ ...payload, provider });
    if (this.nativeSipClients[sessionKey])
      return this.nativeSipClients[sessionKey];
    if (!createNative) return null;

    return this.nativeSipClientFor(provider, sessionKey);
  }

  getSession(
    providerOrKey = this.activeSessionKey || this.activeProvider,
    payload = {}
  ) {
    if (!providerOrKey) return null;
    if (this.sessions[providerOrKey]) return this.sessions[providerOrKey];

    const sessionKey = this.resolveSessionKey({
      ...payload,
      provider: providerOrKey,
    });
    return (
      this.sessions[sessionKey] || this.providerSessions[providerOrKey] || null
    );
  }

  updateProviderRegistration(provider, eventName, detail = {}) {
    const sessionKey = this.resolveSessionKey({ ...detail, provider });
    const session =
      this.sessions[sessionKey] || this.providerSessions[provider];
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

    if (session.sessionKey) this.sessions[session.sessionKey] = session;
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

  async bootstrapIncomingSupport() {
    const response = await VoiceAPI.getWebphoneToken();
    return this.initializeResponse(response);
  }

  async initializeDevice(inboxId = null, { native = false } = {}) {
    const response = native
      ? await VoiceAPI.getNativeWebphoneToken(inboxId)
      : await VoiceAPI.getWebphoneToken(inboxId);
    return this.initializeResponse(response, { inboxId, native });
  }

  async initializeResponse(response, { inboxId = null, native = false } = {}) {
    const sessions = WebphoneClient.responseSessions(response);
    if (sessions.length) {
      const results = await Promise.all(
        sessions.map(session => {
          const provider = WebphoneClient.resolveProvider(session);
          return this.initializeSessionSafely(session, {
            inboxId: WebphoneClient.responseInboxId(session),
            native: WebphoneClient.isNativeSipProvider(provider),
          });
        })
      );
      return {
        provider: results[0]?.provider || response?.provider || null,
        callingSupported: results.some(session => session?.callingSupported),
        registered: results.some(session => session?.registered),
        multiSession: true,
        sessions: results,
      };
    }

    return this.initializeFromSession(response, { inboxId, native });
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
      ? this.invalidateNativeSession(sessionKey)
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
    { inboxId = null, nativeGeneration = null, expectedClient = null } = {}
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
    if (this.nativeSipClients[sessionKey] === client) {
      delete this.nativeSipClients[sessionKey];
      delete this.nativeSipClientGenerations[sessionKey];
    }
    await client?.destroyDevice?.();
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
      ? (nativeGeneration ?? this.invalidateNativeSession(sessionKey))
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
      if (isNative) this.forgetNativeSessionConfig(sessionKey);
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

    if (typeof client.rejectIncomingCall === 'function') {
      return client.rejectIncomingCall();
    }

    return client.endClientCall();
  }

  endClientCall(providerOrPayload = this.activeProvider) {
    const payload =
      typeof providerOrPayload === 'object'
        ? providerOrPayload
        : { provider: providerOrPayload };
    const provider = payload.provider || this.activeProvider;
    const sessionKey = this.resolveSessionKey(payload);
    const client = this.getClient(provider, { ...payload, sessionKey });
    if (!client) return null;

    return client.endClientCall();
  }

  destroyNativeSession(sessionKey) {
    const client = this.nativeSipClients[sessionKey];
    const provider = this.sessions[sessionKey]?.provider;
    delete this.nativeSipClients[sessionKey];
    delete this.nativeSipClientGenerations[sessionKey];
    delete this.sessions[sessionKey];
    this.forgetNativeSessionConfig(sessionKey);
    if (provider && this.providerSessions[provider]?.sessionKey === sessionKey)
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
    return client?.destroyDevice?.();
  }

  destroyDevice(providerOrPayload = this.activeProvider) {
    const payload =
      typeof providerOrPayload === 'object'
        ? providerOrPayload
        : { provider: providerOrPayload };
    const provider = payload.provider || this.activeProvider;

    if (WebphoneClient.isNativeSipProvider(provider)) {
      const sessionKey = this.resolveSessionKey(payload);
      const session = this.sessions[sessionKey];
      const hasExplicitScope = Boolean(
        payload.sessionKey ||
          payload.session_key ||
          payload.inboxId ||
          payload.inbox_id ||
          payload.sipProfileId ||
          payload.sip_profile_id
      );
      if (hasExplicitScope && session?.provider === provider) {
        return this.destroyNativeSession(sessionKey);
      }

      const keys = Object.entries(this.sessions)
        .filter(([, value]) => value.provider === provider)
        .map(([key]) => key);
      return Promise.all(keys.map(key => this.destroyNativeSession(key)));
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
