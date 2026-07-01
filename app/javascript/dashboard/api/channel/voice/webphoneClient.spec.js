import { beforeEach, describe, expect, it, vi } from 'vitest';

const {
  getWebphoneTokenMock,
  getNativeWebphoneTokenMock,
  twilioInitializeMock,
  fonosterInitializeMock,
  fonosterPrewarmMock,
  fonosterStopPrewarmMock,
  fonosterDestroyMock,
  janusInitializeMock,
  janusJoinMock,
  janusPrewarmMock,
  janusStopPrewarmMock,
  janusDestroyMock,
  janusClientFactoryMock,
  janusClientInstances,
} = vi.hoisted(() => {
  const initializeMock = vi.fn();
  const joinMock = vi.fn();
  const prewarmMock = vi.fn();
  const stopPrewarmMock = vi.fn();
  const destroyMock = vi.fn();
  const clientInstances = [];
  const clientFactoryMock = vi.fn(() => {
    const client = {
      addEventListener: vi.fn(),
      initializeDevice: initializeMock,
      joinClientCall: joinMock,
      prewarmMicrophone: prewarmMock,
      stopMicrophonePrewarm: stopPrewarmMock,
      rejectIncomingCall: vi.fn(),
      endClientCall: vi.fn(),
      destroyDevice: destroyMock,
    };
    clientInstances.push(client);
    return client;
  });

  return {
    getWebphoneTokenMock: vi.fn(),
    getNativeWebphoneTokenMock: vi.fn(),
    twilioInitializeMock: vi.fn(),
    fonosterInitializeMock: vi.fn(),
    fonosterPrewarmMock: vi.fn(),
    fonosterStopPrewarmMock: vi.fn(),
    fonosterDestroyMock: vi.fn(),
    janusInitializeMock: initializeMock,
    janusJoinMock: joinMock,
    janusPrewarmMock: prewarmMock,
    janusStopPrewarmMock: stopPrewarmMock,
    janusDestroyMock: destroyMock,
    janusClientInstances: clientInstances,
    janusClientFactoryMock: clientFactoryMock,
  };
});

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getWebphoneToken: getWebphoneTokenMock,
    getNativeWebphoneToken: getNativeWebphoneTokenMock,
  },
}));

vi.mock('dashboard/api/channel/voice/twilioVoiceClient', () => ({
  default: {
    addEventListener: vi.fn(),
    initializeDevice: twilioInitializeMock,
    joinClientCall: vi.fn(),
    endClientCall: vi.fn(),
    destroyDevice: vi.fn(),
  },
}));

vi.mock('dashboard/api/channel/voice/fonosterVoiceClient', () => ({
  default: {
    addEventListener: vi.fn(),
    initializeDevice: fonosterInitializeMock,
    joinClientCall: vi.fn(),
    prewarmMicrophone: fonosterPrewarmMock,
    stopMicrophonePrewarm: fonosterStopPrewarmMock,
    rejectIncomingCall: vi.fn(),
    endClientCall: vi.fn(),
    destroyDevice: fonosterDestroyMock,
  },
}));

vi.mock('dashboard/api/channel/voice/janusSipuniVoiceClient', () => ({
  default: {
    addEventListener: vi.fn(),
    initializeDevice: janusInitializeMock,
    joinClientCall: janusJoinMock,
    prewarmMicrophone: janusPrewarmMock,
    stopMicrophonePrewarm: janusStopPrewarmMock,
    rejectIncomingCall: vi.fn(),
    endClientCall: vi.fn(),
    destroyDevice: janusDestroyMock,
  },
  createJanusSipuniVoiceClient: janusClientFactoryMock,
}));

import WebphoneClient from './webphoneClient';

describe('webphoneClient', () => {
  beforeEach(() => {
    getWebphoneTokenMock.mockReset();
    getNativeWebphoneTokenMock.mockReset();
    twilioInitializeMock.mockReset();
    fonosterInitializeMock.mockReset();
    fonosterPrewarmMock.mockReset();
    fonosterStopPrewarmMock.mockReset();
    fonosterDestroyMock.mockReset();
    janusInitializeMock.mockReset();
    janusJoinMock.mockReset();
    janusPrewarmMock.mockReset();
    janusStopPrewarmMock.mockReset();
    janusDestroyMock.mockReset();
    janusClientFactoryMock.mockClear();
    janusClientInstances.length = 0;
    WebphoneClient.activeProvider = null;
    WebphoneClient.activeSessionKey = null;
    WebphoneClient.providerSessions = {};
    WebphoneClient.sessions = {};
    WebphoneClient.nativeSipClients = {};
    Object.values(WebphoneClient.nativeSessionRetryTimers || {}).forEach(
      timer => {
        window.clearTimeout(timer);
      }
    );
    WebphoneClient.nativeSessionConfigs = {};
    WebphoneClient.nativeSessionRetryTimers = {};
    WebphoneClient.nativeSessionRetryState = {};
    Object.values(WebphoneClient.tokenRefreshTimers || {}).forEach(timer => {
      window.clearTimeout(timer);
    });
    WebphoneClient.tokenRefreshTimers = {};
    WebphoneClient.tokenRefreshState = {};
  });

  it('bootstraps fonoster browser calling without an inbox', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      provider: 'fonoster',
      calling_supported: true,
      token: 'test-token',
      username: 'agent-42',
      domain: 'agents.example.test',
      signalingServer: 'wss://bridge.example/ws',
      targetAor: 'sip:agent-42@agents.example.test',
    });
    fonosterInitializeMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
    });

    const response = await WebphoneClient.bootstrapIncomingSupport();

    expect(getWebphoneTokenMock).toHaveBeenCalledWith();
    expect(fonosterInitializeMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'fonoster' }),
      { inboxId: null }
    );
    expect(response).toEqual(
      expect.objectContaining({
        provider: 'fonoster',
        callingSupported: true,
      })
    );
    expect(WebphoneClient.supportsBrowserCalling('fonoster')).toBe(true);
  });

  it('bootstraps every native Janus SIP session from a multi-session token', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          provider: 'sipuni',
          sip_profile_id: 39,
          inbox_id: 4769,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: {
            username: '015856100021',
            password: 'sipuni-secret',
            host: 'ats01.kz.sipuni.com',
          },
        },
        {
          provider: 'binotel',
          sip_profile_id: 40,
          inbox_id: 4770,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: {
            username: 'pq4dyw5f',
            password: 'binotel-secret',
            host: 'sip53.binotel.com',
          },
        },
        {
          provider: 'asterisk_analog',
          sip_profile_id: 41,
          inbox_id: 4771,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: {
            username: '9098',
            password: 'asterisk-secret',
            host: '10.77.0.2',
          },
        },
      ],
    });
    janusInitializeMock.mockImplementation(async session => ({
      provider: session.provider,
      sessionKey: session.sessionKey,
      inboxId: session.inbox_id,
      sipProfileId: session.sip_profile_id,
      callingSupported: true,
      registered: true,
    }));

    const response = await WebphoneClient.bootstrapIncomingSupport();

    expect(janusClientFactoryMock).toHaveBeenCalledTimes(3);
    expect(janusInitializeMock).toHaveBeenCalledTimes(3);
    expect(Object.keys(WebphoneClient.sessions)).toEqual(
      expect.arrayContaining([
        'sip_profile:39',
        'sip_profile:40',
        'sip_profile:41',
      ])
    );
    expect(response).toEqual(
      expect.objectContaining({
        multiSession: true,
        callingSupported: true,
        registered: true,
      })
    );
    expect(
      WebphoneClient.supportsBrowserCalling('asterisk_analog', {
        inboxId: 4771,
      })
    ).toBe(true);
  });

  it('bootstraps legacy Fonoster and native Janus SIP sessions from one multi-session token', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          provider: 'fonoster',
          calling_supported: true,
          token: 'fonoster-token',
          token_expires_in: 120,
          username: '1001',
          domain: 'operator.cloud.vconsult.kz',
          signalingServer: 'wss://bridge.example/ws',
          targetAor: 'sip:1001@operator.cloud.vconsult.kz',
        },
        {
          provider: 'asterisk_analog',
          sip_profile_id: 41,
          inbox_id: 4771,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: {
            username: '9098',
            password: 'asterisk-secret',
            host: '10.77.0.2',
          },
        },
      ],
    });
    fonosterInitializeMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
      registered: true,
    });
    janusInitializeMock.mockImplementation(async session => ({
      provider: session.provider,
      sessionKey: session.sessionKey,
      inboxId: session.inbox_id,
      sipProfileId: session.sip_profile_id,
      callingSupported: true,
      registered: true,
    }));

    try {
      const response = await WebphoneClient.bootstrapIncomingSupport();

      expect(fonosterInitializeMock).toHaveBeenCalledWith(
        expect.objectContaining({
          provider: 'fonoster',
          sessionKey: 'provider:fonoster',
        }),
        { inboxId: null }
      );
      expect(janusClientFactoryMock).toHaveBeenCalledTimes(1);
      expect(janusInitializeMock).toHaveBeenCalledWith(
        expect.objectContaining({
          provider: 'asterisk_analog',
          sessionKey: 'sip_profile:41',
        }),
        { inboxId: 4771 }
      );
      expect(response).toEqual(
        expect.objectContaining({
          multiSession: true,
          callingSupported: true,
          registered: true,
        })
      );
      expect(WebphoneClient.sessions['provider:fonoster']).toEqual(
        expect.objectContaining({ provider: 'fonoster', registered: true })
      );
      expect(WebphoneClient.sessions['sip_profile:41']).toEqual(
        expect.objectContaining({
          provider: 'asterisk_analog',
          registered: true,
        })
      );
      expect(WebphoneClient.tokenRefreshState['provider:fonoster']).toEqual({
        inboxId: null,
        native: false,
      });
    } finally {
      Object.values(WebphoneClient.tokenRefreshTimers || {}).forEach(timer => {
        window.clearTimeout(timer);
      });
      WebphoneClient.tokenRefreshTimers = {};
      WebphoneClient.tokenRefreshState = {};
    }
  });

  it('keeps other native Janus SIP sessions when one session fails to initialize', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          provider: 'sipuni',
          sip_profile_id: 39,
          inbox_id: 4769,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: { username: 'line-1', password: 'secret', host: 'sipuni.test' },
        },
        {
          provider: 'sipuni',
          sip_profile_id: 40,
          inbox_id: 4770,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: { username: 'line-2', password: 'secret', host: 'sipuni.test' },
        },
      ],
    });
    janusInitializeMock.mockImplementation(async session => {
      if (session.sip_profile_id === 40) {
        throw new Error('registration failed');
      }

      return {
        provider: session.provider,
        sessionKey: session.sessionKey,
        inboxId: session.inbox_id,
        sipProfileId: session.sip_profile_id,
        callingSupported: true,
        registered: true,
      };
    });

    const response = await WebphoneClient.bootstrapIncomingSupport();

    expect(response).toEqual(
      expect.objectContaining({
        multiSession: true,
        callingSupported: true,
        registered: true,
      })
    );
    expect(WebphoneClient.sessions['sip_profile:39']).toEqual(
      expect.objectContaining({ registered: true })
    );
    expect(WebphoneClient.sessions['sip_profile:40']).toEqual(
      expect.objectContaining({
        callingSupported: false,
        registered: false,
        reason: 'registration failed',
      })
    );
    expect(WebphoneClient.nativeSipClients['sip_profile:40']).toBeUndefined();
    expect(WebphoneClient.providerSessions.sipuni).toEqual(
      expect.objectContaining({ sessionKey: 'sip_profile:39' })
    );
    expect(WebphoneClient.supportsBrowserCalling('sipuni')).toBe(true);
  });

  it('retries a failed native Janus SIP session until it registers', async () => {
    vi.useFakeTimers();
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          provider: 'asterisk_analog',
          sip_profile_id: 41,
          inbox_id: 4771,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: {
            username: '9098',
            password: 'asterisk-secret',
            host: '10.77.0.2',
          },
        },
      ],
    });
    janusInitializeMock
      .mockRejectedValueOnce(new Error('temporary registration failed'))
      .mockImplementationOnce(async session => ({
        provider: session.provider,
        sessionKey: session.sessionKey,
        inboxId: session.inbox_id,
        sipProfileId: session.sip_profile_id,
        callingSupported: true,
        registered: true,
      }));

    try {
      const response = await WebphoneClient.bootstrapIncomingSupport();

      expect(response.sessions[0]).toEqual(
        expect.objectContaining({
          callingSupported: false,
          registered: false,
          reason: 'temporary registration failed',
        })
      );
      expect(janusInitializeMock).toHaveBeenCalledTimes(1);
      expect(WebphoneClient.nativeSipClients['sip_profile:41']).toBeUndefined();
      expect(
        WebphoneClient.nativeSessionRetryTimers['sip_profile:41']
      ).toBeDefined();

      await vi.advanceTimersByTimeAsync(30_000);

      expect(janusInitializeMock).toHaveBeenCalledTimes(2);
      expect(WebphoneClient.sessions['sip_profile:41']).toEqual(
        expect.objectContaining({
          provider: 'asterisk_analog',
          callingSupported: true,
          registered: true,
        })
      );
      expect(WebphoneClient.nativeSessionRetryState['sip_profile:41']).toBe(
        undefined
      );
      expect(
        WebphoneClient.supportsBrowserCalling('asterisk_analog', {
          inboxId: 4771,
        })
      ).toBe(true);
    } finally {
      Object.values(WebphoneClient.nativeSessionRetryTimers || {}).forEach(
        timer => {
          window.clearTimeout(timer);
        }
      );
      WebphoneClient.nativeSessionRetryTimers = {};
      WebphoneClient.nativeSessionRetryState = {};
      vi.useRealTimers();
    }
  });

  it('does not route an unknown explicit native session key to the active session', async () => {
    WebphoneClient.sessions['sip_profile:39'] = {
      provider: 'sipuni',
      sessionKey: 'sip_profile:39',
      callingSupported: true,
      registered: true,
    };
    WebphoneClient.nativeSipClients['sip_profile:39'] = {
      prewarmMicrophone: janusPrewarmMock,
    };
    WebphoneClient.activeProvider = 'sipuni';
    WebphoneClient.activeSessionKey = 'sip_profile:39';

    const response = await WebphoneClient.prewarmMicrophone({
      provider: 'sipuni',
      sessionKey: 'sip_profile:404',
    });

    expect(response).toBeNull();
    expect(janusPrewarmMock).not.toHaveBeenCalled();
  });

  it('destroys native Janus SIP sessions by explicit scope or whole provider', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          provider: 'sipuni',
          sip_profile_id: 39,
          inbox_id: 4769,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: { username: 'line-1', password: 'secret', host: 'sipuni.test' },
        },
        {
          provider: 'sipuni',
          sip_profile_id: 42,
          inbox_id: 4772,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: { username: 'line-2', password: 'secret', host: 'sipuni.test' },
        },
      ],
    });
    janusInitializeMock.mockImplementation(async session => ({
      provider: session.provider,
      sessionKey: session.sessionKey,
      inboxId: session.inbox_id,
      sipProfileId: session.sip_profile_id,
      callingSupported: true,
      registered: true,
    }));

    await WebphoneClient.bootstrapIncomingSupport();
    await WebphoneClient.destroyDevice({
      provider: 'sipuni',
      sipProfileId: 39,
    });

    expect(WebphoneClient.sessions['sip_profile:39']).toBeUndefined();
    expect(WebphoneClient.sessions['sip_profile:42']).toBeTruthy();
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);

    await WebphoneClient.destroyDevice('sipuni');

    expect(WebphoneClient.sessions['sip_profile:42']).toBeUndefined();
    expect(janusDestroyMock).toHaveBeenCalledTimes(2);
  });

  it('marks fonoster browser calling unsupported when the bridge contract says so', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      provider: 'fonoster',
      calling_supported: false,
      browser_join_supported: false,
      reason: 'agent_binding_missing',
    });
    WebphoneClient.activeProvider = 'fonoster';

    const response = await WebphoneClient.bootstrapIncomingSupport();

    expect(response).toEqual(
      expect.objectContaining({
        provider: 'fonoster',
        callingSupported: false,
        browserJoinSupported: false,
        registered: false,
        reason: 'agent_binding_missing',
      })
    );
    expect(fonosterInitializeMock).not.toHaveBeenCalled();
    expect(WebphoneClient.activeProvider).toBeNull();
    expect(WebphoneClient.supportsBrowserCalling('fonoster')).toBe(false);
  });

  it('routes inbox initialization to the twilio client when the line uses twilio', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      calling_supported: true,
      token: 'twilio-token',
      identity: 'agent-15-account-1',
      twiml_endpoint: 'https://example.test/twiml',
    });
    twilioInitializeMock.mockResolvedValue({
      provider: 'twilio',
      callingSupported: true,
    });

    const response = await WebphoneClient.initializeDevice(15);

    expect(getWebphoneTokenMock).toHaveBeenCalledWith(15);
    expect(twilioInitializeMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'twilio' }),
      { inboxId: 15 }
    );
    expect(response).toEqual(
      expect.objectContaining({
        provider: 'twilio',
        callingSupported: true,
      })
    );
    expect(WebphoneClient.activeProvider).toBe('twilio');
  });

  it('uses the native webphone token endpoint for native SIP inbox initialization', async () => {
    getNativeWebphoneTokenMock.mockResolvedValue({
      provider: 'sipuni',
      calling_supported: true,
      sip_profile_id: 501,
      inbox_id: 4083,
      janusServer: 'wss://dev.one-link.kz/janus-sipuni',
      sip: {
        username: 'sip-agent',
        password: 'sip-secret',
        host: 'ats01.kz.sipuni.com',
      },
    });
    janusInitializeMock.mockResolvedValue({
      provider: 'sipuni',
      sessionKey: 'sip_profile:501',
      inboxId: 4083,
      sipProfileId: 501,
      callingSupported: true,
      registered: true,
    });

    const response = await WebphoneClient.initializeDevice(4083, {
      native: true,
    });

    expect(getWebphoneTokenMock).not.toHaveBeenCalled();
    expect(getNativeWebphoneTokenMock).toHaveBeenCalledWith(4083);
    expect(janusClientFactoryMock).toHaveBeenCalledTimes(1);
    expect(janusInitializeMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider: 'sipuni',
        sessionKey: 'sip_profile:501',
      }),
      { inboxId: 4083 }
    );
    expect(response).toEqual(
      expect.objectContaining({
        provider: 'sipuni',
        sessionKey: 'sip_profile:501',
        callingSupported: true,
        registered: true,
      })
    );
  });

  it('routes native Binotel sessions to the Janus SIP client', async () => {
    getNativeWebphoneTokenMock.mockResolvedValue({
      provider: 'binotel',
      calling_supported: true,
      sip_profile_id: 901,
      inbox_id: 4769,
      janusServer: 'wss://dev.one-link.kz/janus-sipuni',
      sip: {
        username: 'pq4dyw5f',
        password: 'sip-secret',
        host: 'sip53.binotel.com',
      },
    });
    janusInitializeMock.mockResolvedValue({
      provider: 'binotel',
      sessionKey: 'sip_profile:901',
      inboxId: 4769,
      sipProfileId: 901,
      callingSupported: true,
      registered: true,
    });

    const response = await WebphoneClient.initializeDevice(4769, {
      native: true,
    });

    expect(getNativeWebphoneTokenMock).toHaveBeenCalledWith(4769);
    expect(janusInitializeMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider: 'binotel',
        sessionKey: 'sip_profile:901',
      }),
      { inboxId: 4769 }
    );
    expect(response).toEqual(
      expect.objectContaining({
        provider: 'binotel',
        sessionKey: 'sip_profile:901',
        callingSupported: true,
        registered: true,
      })
    );
    expect(
      WebphoneClient.supportsBrowserCalling('binotel', { inboxId: 4769 })
    ).toBe(true);
  });

  it('refreshes fonoster webphone token before expiry and keeps the inbox scope', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-05-16T09:00:00.000Z'));

    getWebphoneTokenMock
      .mockResolvedValueOnce({
        provider: 'fonoster',
        calling_supported: true,
        token: 'initial-token',
        token_expires_in: 120,
        username: 'agent-42',
        domain: 'agents.example.test',
        signalingServer: 'wss://bridge.example/ws',
        targetAor: 'sip:agent-42@agents.example.test',
      })
      .mockResolvedValueOnce({
        provider: 'fonoster',
        calling_supported: true,
        token: 'rotated-token',
        token_expires_in: 120,
        username: 'agent-42',
        domain: 'agents.example.test',
        signalingServer: 'wss://bridge.example/ws',
        targetAor: 'sip:agent-42@agents.example.test',
      });
    fonosterInitializeMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
      registered: true,
    });

    try {
      await WebphoneClient.initializeDevice(4083);

      expect(getWebphoneTokenMock).toHaveBeenCalledTimes(1);
      expect(getWebphoneTokenMock).toHaveBeenCalledWith(4083);

      await vi.advanceTimersByTimeAsync(60_000);

      expect(getWebphoneTokenMock).toHaveBeenCalledTimes(2);
      expect(getWebphoneTokenMock).toHaveBeenLastCalledWith(4083);
      expect(fonosterInitializeMock).toHaveBeenCalledTimes(2);
      expect(fonosterInitializeMock.mock.calls[1][0]).toEqual(
        expect.objectContaining({ token: 'rotated-token' })
      );
      expect(fonosterInitializeMock.mock.calls[1][1]).toEqual({
        inboxId: 4083,
      });
    } finally {
      Object.values(WebphoneClient.tokenRefreshTimers || {}).forEach(timer => {
        window.clearTimeout(timer);
      });
      WebphoneClient.tokenRefreshTimers = {};
      WebphoneClient.tokenRefreshState = {};
      vi.useRealTimers();
    }
  });

  it('retries fonoster token refresh until a new token is fetched', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-05-16T09:00:00.000Z'));

    getWebphoneTokenMock
      .mockResolvedValueOnce({
        provider: 'fonoster',
        calling_supported: true,
        token: 'initial-token',
        token_expires_in: 120,
        username: 'agent-42',
        domain: 'agents.example.test',
        signalingServer: 'wss://bridge.example/ws',
        targetAor: 'sip:agent-42@agents.example.test',
      })
      .mockRejectedValueOnce(new Error('temporary bridge outage'))
      .mockResolvedValueOnce({
        provider: 'fonoster',
        calling_supported: true,
        token: 'rotated-token-after-retry',
        token_expires_in: 120,
        username: 'agent-42',
        domain: 'agents.example.test',
        signalingServer: 'wss://bridge.example/ws',
        targetAor: 'sip:agent-42@agents.example.test',
      });
    fonosterInitializeMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
      registered: true,
    });

    try {
      await WebphoneClient.initializeDevice(4083);
      await vi.advanceTimersByTimeAsync(60_000);

      expect(getWebphoneTokenMock).toHaveBeenCalledTimes(2);
      expect(fonosterInitializeMock).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(30_000);

      expect(getWebphoneTokenMock).toHaveBeenCalledTimes(3);
      expect(fonosterInitializeMock).toHaveBeenCalledTimes(2);
      expect(fonosterInitializeMock.mock.calls[1][0]).toEqual(
        expect.objectContaining({ token: 'rotated-token-after-retry' })
      );
    } finally {
      Object.values(WebphoneClient.tokenRefreshTimers || {}).forEach(timer => {
        window.clearTimeout(timer);
      });
      WebphoneClient.tokenRefreshTimers = {};
      WebphoneClient.tokenRefreshState = {};
      vi.useRealTimers();
    }
  });

  it('allows outbound fonoster calls through the browser-join path', () => {
    WebphoneClient.providerSessions.fonoster = {
      provider: 'fonoster',
      callingSupported: true,
      registered: true,
    };

    expect(
      WebphoneClient.supportsBrowserCalling('fonoster', {
        callDirection: 'outbound',
      })
    ).toBe(true);
    expect(
      WebphoneClient.supportsBrowserCalling('fonoster', {
        callDirection: 'inbound',
      })
    ).toBe(true);
  });

  it('prewarms the active Fonoster microphone through the provider client', async () => {
    fonosterPrewarmMock.mockResolvedValue({
      provider: 'fonoster',
      prewarmed: true,
    });

    const response = await WebphoneClient.prewarmMicrophone('fonoster', {
      ttlMs: 10_000,
    });

    expect(response).toEqual({
      provider: 'fonoster',
      prewarmed: true,
    });
    expect(fonosterPrewarmMock).toHaveBeenCalledWith({ ttlMs: 10_000 });
  });

  it('stops the active Fonoster microphone prewarm through the provider client', () => {
    WebphoneClient.stopMicrophonePrewarm('fonoster');

    expect(fonosterStopPrewarmMock).toHaveBeenCalledTimes(1);
  });

  it('does not advertise fonoster browser calling while SIP registration is not ready', () => {
    WebphoneClient.providerSessions.fonoster = {
      provider: 'fonoster',
      callingSupported: true,
      registered: false,
    };

    expect(
      WebphoneClient.supportsBrowserCalling('fonoster', {
        callDirection: 'inbound',
      })
    ).toBe(false);

    WebphoneClient.updateProviderRegistration('fonoster', 'call:registered');

    expect(
      WebphoneClient.supportsBrowserCalling('fonoster', {
        callDirection: 'inbound',
      })
    ).toBe(true);
  });
});
