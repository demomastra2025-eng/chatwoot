import VoiceAPI from './voiceAPIClient';
import TwilioVoiceClient from './twilioVoiceClient';
import FonosterVoiceClient from './fonosterVoiceClient';
import JanusSipuniVoiceClient, {
  createJanusSipuniVoiceClient,
} from './janusSipuniVoiceClient';

const WEBPHONE_TOKEN_REFRESH_SAFETY_MS = 60_000;
const WEBPHONE_TOKEN_REFRESH_RETRY_MS = 30_000;
const WEBPHONE_NATIVE_SIP_RETRY_MS = 30_000;

const FORWARDED_EVENTS = [
  'call:disconnected',
  'call:incoming',
  'call:registered',
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

const looksLikeFonosterSession = response => {
  const session = response || {};
  return Boolean(
    session.username ||
      session.domain ||
      session.signalingServer ||
      session.signaling_server ||
      session.targetAor ||
      session.target_aor ||
      session.aor
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
    this.nativeSessionConfigs = {};
    this.nativeSessionRetryTimers = {};
    this.nativeSessionRetryState = {};
    this.tokenRefreshTimers = {};
    this.tokenRefreshState = {};
    this.janusSipClientFactory = createJanusSipuniVoiceClient;
    this.clients = {
      twilio: TwilioVoiceClient,
      fonoster: FonosterVoiceClient,
      asterisk_analog: JanusSipuniVoiceClient,
      sipuni: JanusSipuniVoiceClient,
      binotel: JanusSipuniVoiceClient,
    };

    this.subscribeClient('twilio', TwilioVoiceClient);
    this.subscribeClient('fonoster', FonosterVoiceClient);
  }

  static isNativeSipProvider(provider) {
    return NATIVE_BROWSER_SIP_PROVIDERS.has(provider);
  }

  static resolveProvider(response = {}) {
    if (response?.provider) return response.provider;
    if (looksLikeTwilioSession(response)) return 'twilio';
    if (looksLikeJanusSipSession(response)) return 'sipuni';
    if (looksLikeFonosterSession(response)) return 'fonoster';

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

  static parseAbsoluteExpiryMs(value) {
    if (value === undefined || value === null || value === '') return null;

    const numeric = Number(value);
    if (Number.isFinite(numeric)) {
      return numeric > 1_000_000_000_000 ? numeric : numeric * 1000;
    }

    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
  }

  static parseDurationMs(value) {
    if (value === undefined || value === null || value === '') return null;

    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric * 1000 : null;
  }

  static decodeJwtPayload(token) {
    const payload = token?.split?.('.')[1];
    if (!payload || typeof window.atob !== 'function') return {};

    try {
      const normalized = payload.replace(/-/g, '+').replace(/_/g, '/');
      const padded = normalized.padEnd(
        Math.ceil(normalized.length / 4) * 4,
        '='
      );
      return JSON.parse(window.atob(padded));
    } catch {
      return {};
    }
  }

  static tokenExpiryMs(response = {}) {
    const explicitExpiry = WebphoneClient.responseValue(
      response,
      'token_expires_at',
      'tokenExpiresAt',
      'expires_at',
      'expiresAt',
      'expires'
    );
    const explicitExpiryMs =
      WebphoneClient.parseAbsoluteExpiryMs(explicitExpiry);
    if (explicitExpiryMs !== null) return explicitExpiryMs;

    const expiresIn = WebphoneClient.responseValue(
      response,
      'token_expires_in',
      'tokenExpiresIn',
      'expires_in',
      'expiresIn'
    );
    const expiresInMs = WebphoneClient.parseDurationMs(expiresIn);
    if (expiresInMs !== null) return Date.now() + expiresInMs;

    const jwtExpiry = WebphoneClient.decodeJwtPayload(response.token)?.exp;
    return WebphoneClient.parseAbsoluteExpiryMs(jwtExpiry);
  }

  subscribeClient(provider, client, { sessionKey = null } = {}) {
    FORWARDED_EVENTS.forEach(eventName => {
      client.addEventListener(eventName, event => {
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

  clearTokenRefresh(sessionKey) {
    if (this.tokenRefreshTimers[sessionKey]) {
      window.clearTimeout(this.tokenRefreshTimers[sessionKey]);
    }
    delete this.tokenRefreshTimers[sessionKey];
  }

  scheduleTokenRefresh(
    sessionKey,
    response = {},
    { inboxId = null, native = false, provider = null } = {}
  ) {
    this.clearTokenRefresh(sessionKey);
    delete this.tokenRefreshState[sessionKey];

    if (provider !== 'fonoster') return;

    const callingSupported =
      response.callingSupported ?? response.calling_supported ?? true;
    if (callingSupported === false) return;

    const expiryMs = WebphoneClient.tokenExpiryMs(response);
    if (!expiryMs) return;

    const delayMs = Math.max(
      0,
      expiryMs - Date.now() - WEBPHONE_TOKEN_REFRESH_SAFETY_MS
    );
    this.tokenRefreshState[sessionKey] = { inboxId, native };
    this.tokenRefreshTimers[sessionKey] = window.setTimeout(() => {
      this.refreshProviderSession(sessionKey).catch(() => {
        this.scheduleTokenRefreshRetry(sessionKey);
      });
    }, delayMs);
  }

  scheduleTokenRefreshRetry(sessionKey) {
    this.clearTokenRefresh(sessionKey);
    if (!this.tokenRefreshState[sessionKey]) return;

    this.tokenRefreshTimers[sessionKey] = window.setTimeout(() => {
      this.refreshProviderSession(sessionKey).catch(() => {
        this.scheduleTokenRefreshRetry(sessionKey);
      });
    }, WEBPHONE_TOKEN_REFRESH_RETRY_MS);
  }

  clearNativeSessionRetry(sessionKey) {
    if (!sessionKey) return;

    if (this.nativeSessionRetryTimers[sessionKey]) {
      window.clearTimeout(this.nativeSessionRetryTimers[sessionKey]);
    }
    delete this.nativeSessionRetryTimers[sessionKey];
  }

  forgetNativeSessionConfig(sessionKey) {
    if (!sessionKey) return;

    this.clearNativeSessionRetry(sessionKey);
    delete this.nativeSessionConfigs[sessionKey];
    delete this.nativeSessionRetryState[sessionKey];
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

  scheduleNativeSessionRetry(sessionKey) {
    if (!sessionKey || this.nativeSessionRetryTimers[sessionKey]) return;

    const state =
      this.nativeSessionRetryState[sessionKey] ||
      this.nativeSessionConfigs[sessionKey];
    if (!state) return;

    this.nativeSessionRetryState[sessionKey] = state;
    this.nativeSessionRetryTimers[sessionKey] = window.setTimeout(() => {
      this.retryNativeSession(sessionKey);
    }, WEBPHONE_NATIVE_SIP_RETRY_MS);
  }

  async retryNativeSession(sessionKey) {
    this.clearNativeSessionRetry(sessionKey);
    const state =
      this.nativeSessionRetryState[sessionKey] ||
      this.nativeSessionConfigs[sessionKey];
    if (!state) return null;

    try {
      const session = await this.initializeFromSession(state.response, {
        inboxId: state.inboxId,
        native: true,
      });
      delete this.nativeSessionRetryState[sessionKey];
      return session;
    } catch (error) {
      await this.destroyNativeClientForResponse(state.response, {
        inboxId: state.inboxId,
      });
      this.unsupportedSessionFromResponse(state.response, {
        inboxId: state.inboxId,
        reason: error?.message || 'webphone_session_retry_failed',
      });
      this.nativeSessionRetryState[sessionKey] = state;
      this.scheduleNativeSessionRetry(sessionKey);
      return null;
    }
  }

  async refreshProviderSession(sessionKey) {
    this.clearTokenRefresh(sessionKey);
    const state = this.tokenRefreshState[sessionKey] || {};
    const response = state.native
      ? await VoiceAPI.getNativeWebphoneToken(state.inboxId || null)
      : await VoiceAPI.getWebphoneToken(state.inboxId || null);
    return this.initializeFromSession(response, {
      inboxId: state.inboxId || null,
      native: state.native || false,
    });
  }

  nativeSipClientFor(provider, sessionKey) {
    if (!sessionKey) return null;
    if (this.nativeSipClients[sessionKey])
      return this.nativeSipClients[sessionKey];

    const client = this.janusSipClientFactory();
    this.nativeSipClients[sessionKey] = client;
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
      if (WebphoneClient.isNativeSipProvider(provider)) {
        this.clearNativeSessionRetry(sessionKey);
        delete this.nativeSessionRetryState[sessionKey];
      }
    } else if (eventName === 'call:unregistered') {
      session.registered = false;
      if (WebphoneClient.isNativeSipProvider(provider)) {
        this.scheduleNativeSessionRetry(sessionKey);
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
      provider === 'twilio' ||
      provider === 'fonoster' ||
      WebphoneClient.isNativeSipProvider(provider);
    if (!supportedProvider) return false;

    const session = this.getSession(provider, options);
    if (session?.callingSupported === false) return false;

    if (
      (provider === 'fonoster' ||
        WebphoneClient.isNativeSipProvider(provider)) &&
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
    try {
      return await this.initializeFromSession(response, { inboxId, native });
    } catch (error) {
      const provider = WebphoneClient.resolveProvider(response);
      const resolvedInboxId = WebphoneClient.responseInboxId(response, inboxId);
      const sessionKey = WebphoneClient.responseSessionKey(response, {
        inboxId: resolvedInboxId,
        provider,
      });
      await this.destroyNativeClientForResponse(response, { inboxId });
      this.scheduleNativeSessionRetry(sessionKey);
      return this.unsupportedSessionFromResponse(response, {
        inboxId,
        reason: error?.message || 'webphone_session_initialization_failed',
      });
    }
  }

  async destroyNativeClientForResponse(response = {}, { inboxId = null } = {}) {
    const provider = WebphoneClient.resolveProvider(response);
    if (!WebphoneClient.isNativeSipProvider(provider)) return;

    const sessionKey = WebphoneClient.responseSessionKey(response, {
      inboxId: WebphoneClient.responseInboxId(response, inboxId),
      provider,
    });
    const client = this.nativeSipClients[sessionKey];
    delete this.nativeSipClients[sessionKey];
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
    { inboxId = null, native = false } = {}
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
    const callingSupported =
      response?.callingSupported ?? response?.calling_supported;
    if (callingSupported === false) {
      const existingClient = WebphoneClient.isNativeSipProvider(provider)
        ? this.nativeSipClients[sessionKey]
        : this.getClient(provider);
      if (typeof existingClient?.destroyDevice === 'function') {
        await existingClient.destroyDevice();
      }
      if (WebphoneClient.isNativeSipProvider(provider)) {
        delete this.nativeSipClients[sessionKey];
        this.forgetNativeSessionConfig(sessionKey);
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
      this.clearTokenRefresh(sessionKey);
      delete this.tokenRefreshState[sessionKey];
      this.forgetNativeSessionConfig(sessionKey);
      return resolvedSession;
    }

    const client = WebphoneClient.isNativeSipProvider(provider)
      ? this.nativeSipClientFor(provider, sessionKey)
      : this.getClient(provider);
    if (!client) {
      return {
        provider,
        callingSupported: false,
      };
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
    const resolvedSession = {
      provider,
      sessionKey,
      inboxId: resolvedInboxId,
      sipProfileId: WebphoneClient.responseSipProfileId(response),
      ...(session || {}),
    };

    this.rememberSession(resolvedSession);
    if (WebphoneClient.isNativeSipProvider(provider)) {
      this.clearNativeSessionRetry(sessionKey);
      delete this.nativeSessionRetryState[sessionKey];
    }
    this.scheduleTokenRefresh(sessionKey, response, {
      inboxId: resolvedInboxId,
      native,
      provider,
    });

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
    delete this.sessions[sessionKey];
    this.forgetNativeSessionConfig(sessionKey);
    if (provider && this.providerSessions[provider]?.sessionKey === sessionKey)
      this.refreshProviderFallback(provider);
    this.clearTokenRefresh(sessionKey);
    delete this.tokenRefreshState[sessionKey];
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
    this.clearTokenRefresh(sessionKey);
    delete this.tokenRefreshState[sessionKey];
    if (this.activeProvider === provider) this.activeProvider = null;
    return client.destroyDevice();
  }
}

export default new WebphoneClient();
