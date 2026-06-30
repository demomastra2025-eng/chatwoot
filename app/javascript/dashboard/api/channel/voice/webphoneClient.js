import VoiceAPI from './voiceAPIClient';
import TwilioVoiceClient from './twilioVoiceClient';
import FonosterVoiceClient from './fonosterVoiceClient';
import JanusSipuniVoiceClient from './janusSipuniVoiceClient';

const WEBPHONE_TOKEN_REFRESH_SAFETY_MS = 60_000;
const WEBPHONE_TOKEN_REFRESH_RETRY_MS = 30_000;

const FORWARDED_EVENTS = [
  'call:disconnected',
  'call:incoming',
  'call:registered',
  'call:unregistered',
];

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

const looksLikeSipuniSession = response => {
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

class WebphoneClient extends EventTarget {
  constructor() {
    super();
    this.activeProvider = null;
    this.providerSessions = {};
    this.tokenRefreshTimers = {};
    this.tokenRefreshState = {};
    this.clients = {
      twilio: TwilioVoiceClient,
      fonoster: FonosterVoiceClient,
      sipuni: JanusSipuniVoiceClient,
    };

    FORWARDED_EVENTS.forEach(eventName => {
      Object.entries(this.clients).forEach(([provider, client]) => {
        client.addEventListener(eventName, event => {
          this.updateProviderRegistration(provider, eventName);
          this.dispatchEvent(
            new CustomEvent(eventName, {
              detail: {
                provider,
                ...(event.detail || {}),
              },
            })
          );
        });
      });
    });
  }

  static resolveProvider(response = {}) {
    if (response?.provider) return response.provider;
    if (looksLikeTwilioSession(response)) return 'twilio';
    if (looksLikeSipuniSession(response)) return 'sipuni';
    if (looksLikeFonosterSession(response)) return 'fonoster';

    return null;
  }

  static responseValue(response = {}, ...keys) {
    return keys
      .map(key => response[key])
      .find(value => value !== undefined && value !== null && value !== '');
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

  clearTokenRefresh(provider) {
    if (this.tokenRefreshTimers[provider]) {
      window.clearTimeout(this.tokenRefreshTimers[provider]);
    }
    delete this.tokenRefreshTimers[provider];
  }

  scheduleTokenRefresh(
    provider,
    response = {},
    { inboxId = null, native = false } = {}
  ) {
    this.clearTokenRefresh(provider);
    delete this.tokenRefreshState[provider];

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
    this.tokenRefreshState[provider] = { inboxId, native };
    this.tokenRefreshTimers[provider] = window.setTimeout(() => {
      this.refreshProviderSession(provider).catch(() => {
        this.scheduleTokenRefreshRetry(provider);
      });
    }, delayMs);
  }

  scheduleTokenRefreshRetry(provider) {
    this.clearTokenRefresh(provider);
    if (!this.tokenRefreshState[provider]) return;

    this.tokenRefreshTimers[provider] = window.setTimeout(() => {
      this.refreshProviderSession(provider).catch(() => {
        this.scheduleTokenRefreshRetry(provider);
      });
    }, WEBPHONE_TOKEN_REFRESH_RETRY_MS);
  }

  async refreshProviderSession(provider) {
    this.clearTokenRefresh(provider);
    const state = this.tokenRefreshState[provider] || {};
    const response = state.native
      ? await VoiceAPI.getNativeWebphoneToken(state.inboxId || null)
      : await VoiceAPI.getWebphoneToken(state.inboxId || null);
    return this.initializeFromSession(response, {
      inboxId: state.inboxId || null,
      native: state.native || false,
    });
  }

  getClient(provider) {
    return this.clients[provider] || null;
  }

  getSession(provider = this.activeProvider) {
    return this.providerSessions[provider] || null;
  }

  updateProviderRegistration(provider, eventName) {
    if (!provider || !this.providerSessions[provider]) return;
    if (eventName === 'call:registered') {
      this.providerSessions[provider].registered = true;
    } else if (eventName === 'call:unregistered') {
      this.providerSessions[provider].registered = false;
    }
  }

  supportsBrowserCalling(provider) {
    if (!provider) return false;

    const session = this.getSession(provider);
    if (session?.callingSupported === false) return false;
    if (
      ['fonoster', 'sipuni'].includes(provider) &&
      session?.registered === false
    )
      return false;

    return (
      provider === 'twilio' || provider === 'fonoster' || provider === 'sipuni'
    );
  }

  async bootstrapIncomingSupport() {
    const response = await VoiceAPI.getWebphoneToken();
    return this.initializeFromSession(response);
  }

  async initializeDevice(inboxId = null, { native = false } = {}) {
    const response = native
      ? await VoiceAPI.getNativeWebphoneToken(inboxId)
      : await VoiceAPI.getWebphoneToken(inboxId);
    return this.initializeFromSession(response, { inboxId, native });
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

    const client = this.getClient(provider);
    if (!client) {
      return {
        provider,
        callingSupported: false,
      };
    }

    const callingSupported =
      response?.callingSupported ?? response?.calling_supported;
    if (callingSupported === false) {
      await client.destroyDevice?.();
      const resolvedSession = {
        provider,
        callingSupported: false,
        browserJoinSupported:
          response?.browserJoinSupported ?? response?.browser_join_supported,
        registered: false,
        reason: response?.reason,
      };
      this.providerSessions[provider] = resolvedSession;
      if (this.activeProvider === provider) {
        this.activeProvider = null;
      }
      this.clearTokenRefresh(provider);
      delete this.tokenRefreshState[provider];
      return resolvedSession;
    }

    const session = await client.initializeDevice(
      {
        ...(response || {}),
        provider,
      },
      { inboxId }
    );
    const resolvedSession = {
      provider,
      ...(session || {}),
    };

    this.providerSessions[provider] = resolvedSession;
    this.scheduleTokenRefresh(provider, response, { inboxId, native });

    if (resolvedSession.callingSupported) {
      this.activeProvider = provider;
    }

    return resolvedSession;
  }

  async joinClientCall(payload = {}) {
    const provider = payload.provider || this.activeProvider;
    const client = this.getClient(provider);
    if (!client) return null;

    this.activeProvider = provider;
    return client.joinClientCall(payload);
  }

  prewarmMicrophone(provider = this.activeProvider, options = {}) {
    const client = this.getClient(provider);
    if (!client || typeof client.prewarmMicrophone !== 'function') {
      return Promise.resolve(null);
    }

    return client.prewarmMicrophone(options);
  }

  stopMicrophonePrewarm(provider = this.activeProvider) {
    const client = this.getClient(provider);
    if (!client || typeof client.stopMicrophonePrewarm !== 'function') {
      return null;
    }

    return client.stopMicrophonePrewarm();
  }

  async rejectIncomingCall(provider = this.activeProvider) {
    const client = this.getClient(provider);
    if (!client) return null;

    if (typeof client.rejectIncomingCall === 'function') {
      return client.rejectIncomingCall();
    }

    return client.endClientCall();
  }

  endClientCall(provider = this.activeProvider) {
    const client = this.getClient(provider);
    if (!client) return null;

    return client.endClientCall();
  }

  destroyDevice(provider = this.activeProvider) {
    const client = this.getClient(provider);
    if (!client || typeof client.destroyDevice !== 'function') return null;

    delete this.providerSessions[provider];
    this.clearTokenRefresh(provider);
    delete this.tokenRefreshState[provider];
    return client.destroyDevice();
  }
}

export default new WebphoneClient();
