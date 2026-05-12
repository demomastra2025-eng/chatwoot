import VoiceAPI from './voiceAPIClient';
import TwilioVoiceClient from './twilioVoiceClient';
import FonosterVoiceClient from './fonosterVoiceClient';

const FORWARDED_EVENTS = [
  'call:disconnected',
  'call:incoming',
  'call:registered',
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

class WebphoneClient extends EventTarget {
  constructor() {
    super();
    this.activeProvider = null;
    this.providerSessions = {};
    this.clients = {
      twilio: TwilioVoiceClient,
      fonoster: FonosterVoiceClient,
    };

    FORWARDED_EVENTS.forEach(eventName => {
      Object.entries(this.clients).forEach(([provider, client]) => {
        client.addEventListener(eventName, event => {
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
    if (looksLikeFonosterSession(response)) return 'fonoster';

    return null;
  }

  getClient(provider) {
    return this.clients[provider] || null;
  }

  getSession(provider = this.activeProvider) {
    return this.providerSessions[provider] || null;
  }

  supportsBrowserCalling(provider, { callDirection = null } = {}) {
    if (!provider) return false;
    if (provider === 'fonoster' && callDirection === 'outbound') return false;

    const session = this.getSession(provider);
    if (session?.callingSupported === false) return false;
    if (provider === 'fonoster' && session?.registered === false) return false;

    return provider === 'twilio' || provider === 'fonoster';
  }

  async bootstrapIncomingSupport() {
    const response = await VoiceAPI.getWebphoneToken();
    return this.initializeFromSession(response);
  }

  async initializeDevice(inboxId = null) {
    const response = await VoiceAPI.getWebphoneToken(inboxId);
    return this.initializeFromSession(response, { inboxId });
  }

  async initializeFromSession(response, { inboxId = null } = {}) {
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
    return client.destroyDevice();
  }
}

export default new WebphoneClient();
