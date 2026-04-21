import { Device } from '@twilio/voice-sdk';
import VoiceAPI from './voiceAPIClient';

const createCallDisconnectedEvent = () => new CustomEvent('call:disconnected');

class WebphoneClient extends EventTarget {
  constructor() {
    super();
    this.device = null;
    this.activeConnection = null;
    this.initialized = false;
    this.inboxId = null;
    this.sessionConfig = null;
  }

  async initializeDevice(sessionConfigOrInboxId, { inboxId = null } = {}) {
    this.destroyDevice();

    const response =
      typeof sessionConfigOrInboxId === 'object' &&
      sessionConfigOrInboxId !== null
        ? sessionConfigOrInboxId
        : await VoiceAPI.getWebphoneToken(sessionConfigOrInboxId);
    const {
      token,
      account_id: accountId,
      provider = 'fonoster',
      calling_supported: callingSupported = provider === 'twilio',
    } = response || {};

    this.sessionConfig = response || {};
    this.inboxId =
      inboxId ||
      (typeof sessionConfigOrInboxId === 'number'
        ? sessionConfigOrInboxId
        : null);

    if (!callingSupported) {
      this.initialized = true;
      return {
        provider,
        callingSupported: false,
      };
    }

    if (provider !== 'twilio' || !token) {
      throw new Error(
        'Browser calling is not configured for this voice provider'
      );
    }

    this.device = new Device(token, {
      allowIncomingWhileBusy: true,
      disableAudioContextSounds: true,
      appParams: { account_id: accountId },
    });

    this.device.removeAllListeners();
    this.device.on('connect', conn => {
      this.activeConnection = conn;
      conn.on('disconnect', this.onDisconnect);
    });

    this.device.on('disconnect', this.onDisconnect);

    this.device.on('tokenWillExpire', async () => {
      const r = await VoiceAPI.getWebphoneToken(this.inboxId);
      if (r?.token) this.device.updateToken(r.token);
    });

    this.initialized = true;
    return {
      provider,
      callingSupported: true,
      device: this.device,
    };
  }

  get hasActiveConnection() {
    return !!this.activeConnection;
  }

  endClientCall() {
    if (this.activeConnection) {
      this.activeConnection.disconnect();
    }
    this.activeConnection = null;
    if (this.device) {
      this.device.disconnectAll();
    }
  }

  destroyDevice() {
    if (this.device) {
      this.device.destroy();
    }
    this.activeConnection = null;
    this.device = null;
    this.initialized = false;
    this.inboxId = null;
    this.sessionConfig = null;
  }

  async joinClientCall({ to, conversationId, callRef }) {
    if (!this.device || !this.initialized || !to) return null;
    if (this.activeConnection) return this.activeConnection;

    const params = {
      To: to,
      is_agent: 'true',
      conversation_id: conversationId,
      call_ref: callRef,
    };

    const connection = await this.device.connect({ params });
    this.activeConnection = connection;

    connection.on('disconnect', this.onDisconnect);

    return connection;
  }

  onDisconnect = () => {
    this.activeConnection = null;
    this.dispatchEvent(createCallDisconnectedEvent());
  };
}

export default new WebphoneClient();
