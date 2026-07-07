import { beforeEach, describe, expect, it, vi } from 'vitest';

const {
  getWebphoneTokenMock,
  getNativeWebphoneTokenMock,
  twilioInitializeMock,
  janusInitializeMock,
  janusJoinMock,
  janusPrewarmMock,
  janusStopPrewarmMock,
  janusHasPendingIncomingCallMock,
  janusWaitForPendingIncomingCallMock,
  janusDestroyMock,
  janusClientFactoryMock,
  janusClientInstances,
} = vi.hoisted(() => {
  const initializeMock = vi.fn();
  const joinMock = vi.fn();
  const prewarmMock = vi.fn();
  const stopPrewarmMock = vi.fn();
  const hasPendingIncomingCallMock = vi.fn();
  const waitForPendingIncomingCallMock = vi.fn();
  const destroyMock = vi.fn();
  const clientInstances = [];
  const clientFactoryMock = vi.fn(() => {
    const client = {
      addEventListener: vi.fn(),
      initializeDevice: initializeMock,
      joinClientCall: joinMock,
      hasPendingIncomingCall: hasPendingIncomingCallMock,
      waitForPendingIncomingCall: waitForPendingIncomingCallMock,
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
    janusInitializeMock: initializeMock,
    janusJoinMock: joinMock,
    janusPrewarmMock: prewarmMock,
    janusStopPrewarmMock: stopPrewarmMock,
    janusHasPendingIncomingCallMock: hasPendingIncomingCallMock,
    janusWaitForPendingIncomingCallMock: waitForPendingIncomingCallMock,
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

vi.mock('dashboard/api/channel/voice/janusSipVoiceClient', () => ({
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
  createJanusSipVoiceClient: janusClientFactoryMock,
}));

import WebphoneClient from './webphoneClient';

describe('webphoneClient', () => {
  beforeEach(() => {
    getWebphoneTokenMock.mockReset();
    getNativeWebphoneTokenMock.mockReset();
    twilioInitializeMock.mockReset();
    janusInitializeMock.mockReset();
    janusJoinMock.mockReset();
    janusPrewarmMock.mockReset();
    janusStopPrewarmMock.mockReset();
    janusHasPendingIncomingCallMock.mockReset();
    janusWaitForPendingIncomingCallMock.mockReset();
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

  it('forwards native Janus SIP connected events with session context', async () => {
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
    janusInitializeMock.mockImplementation(async session => ({
      provider: session.provider,
      sessionKey: session.sessionKey,
      inboxId: session.inbox_id,
      sipProfileId: session.sip_profile_id,
      callingSupported: true,
      registered: true,
    }));
    const connectedHandler = vi.fn();
    WebphoneClient.addEventListener('call:connected', connectedHandler);

    await WebphoneClient.bootstrapIncomingSupport();
    const [, forwardConnected] =
      janusClientInstances[0].addEventListener.mock.calls.find(
        ([eventName]) => eventName === 'call:connected'
      );
    forwardConnected({
      detail: {
        provider: 'asterisk_analog',
        callRef: 'asterisk_analog:local:connected-outbound',
      },
    });

    expect(connectedHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          provider: 'asterisk_analog',
          sessionKey: 'sip_profile:41',
          callRef: 'asterisk_analog:local:connected-outbound',
        }),
      })
    );
    WebphoneClient.removeEventListener('call:connected', connectedHandler);
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

  it('waits for pending Janus incoming calls on the scoped native SIP session', async () => {
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
    janusHasPendingIncomingCallMock.mockReturnValue(true);
    janusWaitForPendingIncomingCallMock.mockResolvedValue({
      callRef: 'janus-call-501',
    });

    await WebphoneClient.initializeDevice(4083, { native: true });

    expect(
      WebphoneClient.hasPendingIncomingCall({
        provider: 'sipuni',
        inboxId: 4083,
        sipProfileId: 501,
        janusCallRef: 'janus-call-501',
      })
    ).toBe(true);
    expect(janusHasPendingIncomingCallMock).toHaveBeenCalledWith({
      callRef: 'janus-call-501',
      strict: true,
    });

    const pendingCall = await WebphoneClient.waitForPendingIncomingCall(
      {
        provider: 'sipuni',
        inboxId: 4083,
        sipProfileId: 501,
        janusCallRef: 'janus-call-501',
      },
      { timeoutMs: 1234 }
    );

    expect(pendingCall).toEqual({ callRef: 'janus-call-501' });
    expect(janusWaitForPendingIncomingCallMock).toHaveBeenCalledWith(1234, {
      callRef: 'janus-call-501',
      strict: true,
    });
  });
});
