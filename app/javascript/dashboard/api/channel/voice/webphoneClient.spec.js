import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import Cookies from 'js-cookie';

const {
  getWebphoneTokenMock,
  getNativeWebphoneTokenMock,
  twilioInitializeMock,
  janusInitializeMock,
  janusJoinMock,
  janusPrewarmMock,
  janusStopPrewarmMock,
  janusHasPendingIncomingCallMock,
  janusBindCurrentCallReferenceMock,
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
  const bindCurrentCallReferenceMock = vi.fn();
  const waitForPendingIncomingCallMock = vi.fn();
  const destroyMock = vi.fn();
  const clientInstances = [];
  const clientFactoryMock = vi.fn(() => {
    const client = {
      addEventListener: vi.fn(),
      initializeDevice: initializeMock,
      joinClientCall: joinMock,
      hasPendingIncomingCall: hasPendingIncomingCallMock,
      bindCurrentCallReference: bindCurrentCallReferenceMock,
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
    janusBindCurrentCallReferenceMock: bindCurrentCallReferenceMock,
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
    WebphoneClient.nativeSipClientGenerations = {};
    Object.values(WebphoneClient.nativeSessionRetryTimers || {}).forEach(
      timer => {
        window.clearTimeout(timer);
      }
    );
    WebphoneClient.nativeSessionConfigs = {};
    WebphoneClient.nativeSessionRetryTimers = {};
    WebphoneClient.nativeSessionRetryState = {};
    WebphoneClient.nativeSessionRetryPromises = {};
    WebphoneClient.nativeSessionGenerations = {};
    WebphoneClient.bootstrapIncomingPromise = null;
    WebphoneClient.deviceInitializationPromises = {};
    window.removeEventListener(
      'beforeunload',
      WebphoneClient.handleBeforeUnload
    );
    WebphoneClient.nativeCallUnloadGuardRegistered = false;
  });

  it('routes microphone control only to the scoped native SIP client', () => {
    const first = {
      microphoneState: vi.fn(() => ({ available: true, muted: false })),
      toggleMicrophone: vi.fn(() => true),
    };
    const second = {
      microphoneState: vi.fn(() => ({ available: true, muted: true })),
      toggleMicrophone: vi.fn(() => true),
    };
    WebphoneClient.sessions['sip_profile:40'] = {
      provider: 'sipuni',
      sipProfileId: 40,
      sessionKey: 'sip_profile:40',
    };
    WebphoneClient.sessions['sip_profile:41'] = {
      provider: 'sipuni',
      sipProfileId: 41,
      sessionKey: 'sip_profile:41',
    };
    WebphoneClient.nativeSipClients['sip_profile:40'] = first;
    WebphoneClient.nativeSipClients['sip_profile:41'] = second;
    const scope = {
      provider: 'sipuni',
      sipProfileId: 41,
      callRef: 'sipuni:call-41',
    };

    expect(WebphoneClient.microphoneState(scope)).toEqual({
      available: true,
      muted: true,
    });
    expect(WebphoneClient.toggleMicrophone(scope)).toBe(true);
    expect(second.toggleMicrophone).toHaveBeenCalledWith({
      callRef: 'sipuni:call-41',
      janusCallRef: undefined,
    });
    expect(first.toggleMicrophone).not.toHaveBeenCalled();
    expect(WebphoneClient.toggleMicrophone({ ...scope, callRef: null })).toBe(
      false
    );
    expect(
      WebphoneClient.toggleMicrophone({ ...scope, provider: 'twilio' })
    ).toBe(false);
    expect(
      WebphoneClient.toggleMicrophone({ ...scope, sipProfileId: null })
    ).toBe(false);
  });

  it('routes Wazo sessions through the native Janus SIP client', () => {
    expect(WebphoneClient.clients.wazo).toBe(WebphoneClient.clients.sipuni);
    expect(WebphoneClient.constructor.isNativeSipProvider('wazo')).toBe(true);
  });

  it('coalesces concurrent dashboard bootstrap requests', async () => {
    let resolveToken;
    getWebphoneTokenMock.mockReturnValue(
      new Promise(resolve => {
        resolveToken = resolve;
      })
    );

    const first = WebphoneClient.bootstrapIncomingSupport();
    const second = WebphoneClient.bootstrapIncomingSupport();

    expect(getWebphoneTokenMock).toHaveBeenCalledTimes(1);
    resolveToken({ calling_supported: false });
    await Promise.all([first, second]);
  });

  it('returns the requested provider session from a multi-session token', async () => {
    getNativeWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          provider: 'sipuni',
          sip_profile_id: 39,
          inbox_id: 4769,
          calling_supported: true,
        },
        {
          provider: 'binotel',
          sip_profile_id: 40,
          inbox_id: 4770,
          calling_supported: true,
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

    const selected = await WebphoneClient.initializeDevice(4770, {
      native: true,
      provider: 'binotel',
      sipProfileId: 40,
    });

    expect(selected).toMatchObject({
      provider: 'binotel',
      sessionKey: 'sip_profile:40',
      inboxId: 4770,
      sipProfileId: 40,
      multiSession: true,
    });
    expect(
      WebphoneClient.getSession('sipuni', { sipProfileId: 40 })
    ).toBeNull();
    expect(
      WebphoneClient.getSession('sip_profile:40', { provider: 'binotel' })
    ).toMatchObject({ provider: 'binotel', sipProfileId: 40 });
    expect(
      WebphoneClient.getSession('sip_profile:40', { provider: 'sipuni' })
    ).toBeNull();
    expect(
      WebphoneClient.getSession('sip_profile:40', { inboxId: 9999 })
    ).toBeNull();
    expect(WebphoneClient.getClient('sipuni', { sipProfileId: 40 })).toBeNull();
  });

  it('coalesces concurrent inbox device initialization requests', async () => {
    let resolveToken;
    getNativeWebphoneTokenMock.mockReturnValue(
      new Promise(resolve => {
        resolveToken = resolve;
      })
    );

    const first = WebphoneClient.initializeDevice(4769, { native: true });
    const second = WebphoneClient.initializeDevice(4769, { native: true });

    expect(getNativeWebphoneTokenMock).toHaveBeenCalledTimes(1);
    resolveToken({ calling_supported: false });
    await Promise.all([first, second]);
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

  it('preserves the active native Janus client across rotated ticket refreshes', async () => {
    const session = {
      provider: 'sipuni',
      sip_profile_id: 39,
      inbox_id: 4769,
      calling_supported: true,
      janusServer:
        'wss://dev.one-link.kz/janus-sipuni?janus_ticket=initial-ticket',
      registration_config_version: 'config-39',
      sip: {
        username: 'line-39',
        password: 'secret',
        host: 'sipuni.test',
      },
    };
    getNativeWebphoneTokenMock
      .mockResolvedValueOnce(session)
      .mockResolvedValueOnce({
        ...session,
        janusServer:
          'wss://dev.one-link.kz/janus-sipuni?janus_ticket=scoped-refresh-ticket',
      });
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          ...session,
          janusServer:
            'wss://dev.one-link.kz/janus-sipuni?janus_ticket=global-refresh-ticket',
        },
      ],
    });
    janusInitializeMock.mockImplementation(async payload => ({
      provider: payload.provider,
      sessionKey: payload.sessionKey,
      inboxId: payload.inbox_id,
      sipProfileId: payload.sip_profile_id,
      callingSupported: true,
      registered: true,
    }));
    janusHasPendingIncomingCallMock.mockReturnValue(true);

    await WebphoneClient.initializeDevice(4769, { native: true });
    const activeClient = WebphoneClient.nativeSipClients['sip_profile:39'];

    await WebphoneClient.bootstrapIncomingSupport();
    await WebphoneClient.initializeDevice(4769, { native: true });

    expect(janusClientFactoryMock).toHaveBeenCalledTimes(1);
    expect(janusDestroyMock).not.toHaveBeenCalled();
    expect(WebphoneClient.nativeSipClients['sip_profile:39']).toBe(
      activeClient
    );
    expect(
      WebphoneClient.hasPendingIncomingCall({
        provider: 'sipuni',
        inboxId: 4769,
        sipProfileId: 39,
        janusCallRef: 'incoming-39',
      })
    ).toBe(true);
    WebphoneClient.bindCurrentCallReference({
      provider: 'sipuni',
      inboxId: 4769,
      sipProfileId: 39,
      callRef: 'sipuni:janus:39:incoming-39',
      janusCallRef: 'incoming-39',
    });
    expect(janusBindCurrentCallReferenceMock).toHaveBeenCalledWith({
      callRef: 'sipuni:janus:39:incoming-39',
      janusCallRef: 'incoming-39',
    });
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

  it('ignores late events from a replaced native Janus client', async () => {
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
            username: 'line-39',
            password: 'secret',
            host: 'sipuni.test',
          },
        },
      ],
    });
    janusInitializeMock.mockResolvedValue({
      provider: 'sipuni',
      sessionKey: 'sip_profile:39',
      inboxId: 4769,
      sipProfileId: 39,
      callingSupported: true,
      registered: true,
    });
    const registeredHandler = vi.fn();
    WebphoneClient.addEventListener('call:registered', registeredHandler);

    try {
      await WebphoneClient.bootstrapIncomingSupport();
      const oldClient = janusClientInstances[0];
      const [, forwardRegistered] = oldClient.addEventListener.mock.calls.find(
        ([eventName]) => eventName === 'call:registered'
      );
      WebphoneClient.sessions['sip_profile:39'].registered = false;
      const generation =
        WebphoneClient.invalidateNativeSession('sip_profile:39');
      WebphoneClient.nativeSipClientFor('sipuni', 'sip_profile:39', generation);

      forwardRegistered({
        detail: {
          provider: 'sipuni',
          sessionKey: 'sip_profile:39',
        },
      });

      expect(WebphoneClient.sessions['sip_profile:39'].registered).toBe(false);
      expect(registeredHandler).not.toHaveBeenCalled();
    } finally {
      WebphoneClient.removeEventListener('call:registered', registeredHandler);
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
      getNativeWebphoneTokenMock.mockResolvedValueOnce({
        provider: 'asterisk_analog',
        sip_profile_id: 41,
        inbox_id: 4771,
        calling_supported: true,
        janusServer:
          'wss://app.one-link.kz/janus-asterisk?janus_ticket=fresh-ticket',
        sip: {
          username: '9098',
          password: 'asterisk-secret',
          host: '10.77.0.2',
        },
      });

      await vi.advanceTimersByTimeAsync(1_500);

      expect(getWebphoneTokenMock).toHaveBeenCalledTimes(1);
      expect(getNativeWebphoneTokenMock).toHaveBeenCalledWith(4771);
      expect(janusInitializeMock).toHaveBeenCalledTimes(2);
      expect(janusInitializeMock.mock.calls[1][0].janusServer).toContain(
        'janus_ticket=fresh-ticket'
      );
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

  it('keeps a competing tab on standby and takes over after the lease is released', async () => {
    vi.useFakeTimers();
    const randomSpy = vi.spyOn(Math, 'random').mockReturnValue(0.5);
    const standbySession = {
      provider: 'sipuni',
      sip_profile_id: 39,
      inbox_id: 4769,
      calling_supported: false,
      reason: 'sip_profile_registration_lease_owned_by_another_tab',
    };
    const activeSession = {
      ...standbySession,
      calling_supported: true,
      reason: null,
      janusServer:
        'wss://dev.one-link.kz/janus-sipuni?janus_ticket=takeover-ticket',
      sip: {
        username: 'line-39',
        password: 'secret',
        host: 'sipuni.test',
      },
    };
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [standbySession],
    });
    getNativeWebphoneTokenMock
      .mockResolvedValueOnce(standbySession)
      .mockResolvedValueOnce(activeSession);
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

      expect(response.sessions[0]).toMatchObject({
        callingSupported: false,
        registered: false,
        reason: 'sip_profile_registration_lease_owned_by_another_tab',
      });
      expect(janusInitializeMock).not.toHaveBeenCalled();
      expect(
        WebphoneClient.nativeSessionConfigs['sip_profile:39']
      ).toBeDefined();
      expect(
        WebphoneClient.nativeSessionRetryTimers['sip_profile:39']
      ).toBeDefined();

      await vi.advanceTimersByTimeAsync(4_999);

      expect(getNativeWebphoneTokenMock).not.toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(1);

      expect(getNativeWebphoneTokenMock).toHaveBeenCalledTimes(1);
      expect(janusInitializeMock).not.toHaveBeenCalled();
      expect(WebphoneClient.sessions['sip_profile:39']).toMatchObject({
        registered: false,
        reason: 'sip_profile_registration_lease_owned_by_another_tab',
      });
      expect(
        WebphoneClient.nativeSessionRetryTimers['sip_profile:39']
      ).toBeDefined();

      await vi.advanceTimersByTimeAsync(4_999);

      expect(getNativeWebphoneTokenMock).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(1);

      expect(getNativeWebphoneTokenMock).toHaveBeenCalledTimes(2);
      expect(janusInitializeMock).toHaveBeenCalledTimes(1);
      expect(WebphoneClient.sessions['sip_profile:39']).toMatchObject({
        callingSupported: true,
        registered: true,
      });
      expect(
        WebphoneClient.nativeSessionRetryState['sip_profile:39']
      ).toBeUndefined();
      expect(
        WebphoneClient.nativeSessionRetryTimers['sip_profile:39']
      ).toBeUndefined();
    } finally {
      Object.values(WebphoneClient.nativeSessionRetryTimers || {}).forEach(
        timer => window.clearTimeout(timer)
      );
      WebphoneClient.nativeSessionRetryTimers = {};
      WebphoneClient.nativeSessionRetryState = {};
      randomSpy.mockRestore();
      vi.useRealTimers();
    }
  });

  it('bounds standby polling jitter between four and six seconds', () => {
    const clientClass = WebphoneClient.constructor;

    expect(clientClass.nativeSipStandbyRetryDelay(() => 0)).toBe(4_000);
    expect(clientClass.nativeSipStandbyRetryDelay(() => 1)).toBe(6_000);
  });

  it('fences normal refreshes while a native session retry owns a newer generation', async () => {
    const initialSession = {
      provider: 'sipuni',
      sip_profile_id: 39,
      inbox_id: 4769,
      calling_supported: true,
      janusServer:
        'wss://dev.one-link.kz/janus-sipuni?janus_ticket=initial-ticket',
      sip: {
        username: 'line-39',
        password: 'secret',
        host: 'sipuni.test',
      },
    };
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [initialSession],
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
    const activeClient = WebphoneClient.nativeSipClients['sip_profile:39'];
    let resolveRefresh;
    getNativeWebphoneTokenMock.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveRefresh = resolve;
        })
    );
    janusInitializeMock.mockClear();
    janusDestroyMock.mockClear();

    const retryPromise = WebphoneClient.retryNativeSession('sip_profile:39');
    expect(getNativeWebphoneTokenMock).toHaveBeenCalledWith(4769);

    await WebphoneClient.initializeResponse({
      multi_session: true,
      sessions: [
        {
          ...initialSession,
          janusServer:
            'wss://dev.one-link.kz/janus-sipuni?janus_ticket=normal-refresh-ticket',
        },
      ],
    });

    expect(janusInitializeMock).not.toHaveBeenCalled();
    expect(janusDestroyMock).not.toHaveBeenCalled();
    expect(WebphoneClient.nativeSipClients['sip_profile:39']).toBe(
      activeClient
    );

    resolveRefresh({
      ...initialSession,
      janusServer:
        'wss://dev.one-link.kz/janus-sipuni?janus_ticket=retry-ticket',
    });
    await retryPromise;

    expect(janusInitializeMock).toHaveBeenCalledTimes(1);
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
    expect(WebphoneClient.nativeSipClients['sip_profile:39']).not.toBe(
      activeClient
    );
  });

  it('forwards terminal events emitted while a native session is being destroyed', async () => {
    const sessionKey = 'sip_profile:terminal-release';
    const client = {
      addEventListener: vi.fn(),
      destroyDevice: vi.fn(),
    };
    WebphoneClient.sessions[sessionKey] = {
      provider: 'binotel',
      sessionKey,
      inboxId: 4773,
      sipProfileId: 'terminal-release',
    };
    WebphoneClient.nativeSipClients[sessionKey] = client;
    WebphoneClient.subscribeClient('binotel', client, { sessionKey });
    const disconnectedListener = client.addEventListener.mock.calls.find(
      ([eventName]) => eventName === 'call:disconnected'
    )[1];
    client.destroyDevice.mockImplementationOnce(async () => {
      disconnectedListener(
        new CustomEvent('call:disconnected', {
          detail: { callRef: 'binotel:local:terminal-release' },
        })
      );
    });
    const forwarded = vi.fn();
    WebphoneClient.addEventListener('call:disconnected', forwarded, {
      once: true,
    });

    await WebphoneClient.destroyDevice({
      provider: 'binotel',
      sessionKey,
    });

    expect(forwarded).toHaveBeenCalledTimes(1);
    expect(forwarded.mock.calls[0][0].detail).toMatchObject({
      provider: 'binotel',
      sessionKey,
      callRef: 'binotel:local:terminal-release',
    });
    expect(WebphoneClient.nativeSipClients[sessionKey]).toBeUndefined();
  });

  it('cleans a native session registry even when device teardown fails', async () => {
    const sessionKey = 'sip_profile:failed-destroy';
    const client = {
      addEventListener: vi.fn(),
      destroyDevice: vi
        .fn()
        .mockRejectedValue(new Error('janus_destroy_failed')),
    };
    WebphoneClient.nativeSipClients[sessionKey] = client;
    WebphoneClient.nativeSipClientGenerations[sessionKey] = 8;
    WebphoneClient.sessions[sessionKey] = {
      sessionKey,
      provider: 'binotel',
    };
    WebphoneClient.nativeSessionConfigs[sessionKey] = {
      sessionKey,
      provider: 'binotel',
    };

    await expect(
      WebphoneClient.destroyNativeSession(sessionKey)
    ).rejects.toThrow('janus_destroy_failed');

    expect(WebphoneClient.nativeSipClients[sessionKey]).toBeUndefined();
    expect(
      WebphoneClient.nativeSipClientGenerations[sessionKey]
    ).toBeUndefined();
    expect(WebphoneClient.sessions[sessionKey]).toBeUndefined();
    expect(WebphoneClient.nativeSessionConfigs[sessionKey]).toBeUndefined();
  });

  it('emits registry changes when a native SIP session is added and removed', async () => {
    const sessionKey = 'sip_profile:registry-events';
    const sessionsChanged = vi.fn();
    WebphoneClient.addEventListener('call:sessions-changed', sessionsChanged);

    WebphoneClient.rememberSession({
      sessionKey,
      provider: 'sipuni',
      inboxId: 4771,
      registered: true,
    });
    await WebphoneClient.destroyNativeSession(sessionKey);

    expect(sessionsChanged).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        detail: { sessionKey, action: 'updated' },
      })
    );
    expect(sessionsChanged).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        detail: { sessionKey, action: 'removed' },
      })
    );
    WebphoneClient.removeEventListener(
      'call:sessions-changed',
      sessionsChanged
    );
  });

  it('does not destroy provider sessions when an explicit session key is stale', async () => {
    const activeDestroyMock = vi.fn();
    WebphoneClient.sessions['sip_profile:active'] = {
      provider: 'sipuni',
      sessionKey: 'sip_profile:active',
      inboxId: 4772,
      sipProfileId: 'active',
    };
    WebphoneClient.nativeSipClients['sip_profile:active'] = {
      destroyDevice: activeDestroyMock,
    };
    WebphoneClient.providerSessions.sipuni =
      WebphoneClient.sessions['sip_profile:active'];

    const staleSessionResult = await WebphoneClient.destroyDevice({
      provider: 'sipuni',
      sessionKey: 'sip_profile:stale',
    });
    const staleInboxResult = await WebphoneClient.destroyDevice({
      provider: 'sipuni',
      inboxId: 9999,
    });
    const staleProfileResult = await WebphoneClient.destroyDevice({
      provider: 'sipuni',
      sipProfileId: 'stale',
    });

    expect(staleSessionResult).toBeNull();
    expect(staleInboxResult).toBeNull();
    expect(staleProfileResult).toBeNull();
    expect(activeDestroyMock).not.toHaveBeenCalled();
    expect(WebphoneClient.sessions['sip_profile:active']).toBeDefined();
  });

  it('destroys an explicitly scoped native session while initialization is in flight', async () => {
    let resolveInitialization;
    janusInitializeMock.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveInitialization = resolve;
        })
    );
    const response = {
      multi_session: true,
      sessions: [
        {
          provider: 'sipuni',
          sip_profile_id: 51,
          inbox_id: 4769,
          calling_supported: true,
        },
      ],
    };

    const initialization = WebphoneClient.initializeResponse(response);
    await vi.waitFor(() => {
      expect(WebphoneClient.nativeSipClients['sip_profile:51']).toBeDefined();
      expect(
        WebphoneClient.nativeSessionConfigs['sip_profile:51']
      ).toBeDefined();
    });
    const pendingClient = WebphoneClient.nativeSipClients['sip_profile:51'];

    await WebphoneClient.destroyDevice({
      provider: 'sipuni',
      sessionKey: 'sip_profile:51',
      inboxId: 4769,
      sipProfileId: 51,
    });
    resolveInitialization({
      provider: 'sipuni',
      sessionKey: 'sip_profile:51',
      inboxId: 4769,
      sipProfileId: 51,
      callingSupported: true,
      registered: true,
    });
    await initialization;

    expect(pendingClient.destroyDevice).toHaveBeenCalledTimes(1);
    expect(WebphoneClient.sessions['sip_profile:51']).toBeUndefined();
    expect(WebphoneClient.nativeSipClients['sip_profile:51']).toBeUndefined();
    expect(
      WebphoneClient.nativeSessionConfigs['sip_profile:51']
    ).toBeUndefined();
  });

  it('does not resurrect a destroyed session from an in-flight retry', async () => {
    vi.useFakeTimers();
    const initialSession = {
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
    };
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [initialSession],
    });
    janusInitializeMock.mockRejectedValueOnce(
      new Error('temporary registration failed')
    );
    let resolveRefresh;

    try {
      await WebphoneClient.bootstrapIncomingSupport();
      getNativeWebphoneTokenMock.mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveRefresh = resolve;
          })
      );

      await vi.advanceTimersByTimeAsync(1_500);
      const retryPromise =
        WebphoneClient.nativeSessionRetryPromises['sip_profile:41'];
      expect(retryPromise).toBeDefined();

      await WebphoneClient.destroyNativeSession('sip_profile:41');
      resolveRefresh({
        ...initialSession,
        janusServer:
          'wss://dev.one-link.kz/janus-sipuni?janus_ticket=fresh-ticket',
      });
      await retryPromise;

      expect(janusInitializeMock).toHaveBeenCalledTimes(1);
      expect(WebphoneClient.sessions['sip_profile:41']).toBeUndefined();
      expect(WebphoneClient.nativeSipClients['sip_profile:41']).toBeUndefined();
      expect(
        WebphoneClient.nativeSessionRetryTimers['sip_profile:41']
      ).toBeUndefined();
    } finally {
      Object.values(WebphoneClient.nativeSessionRetryTimers || {}).forEach(
        timer => {
          window.clearTimeout(timer);
        }
      );
      WebphoneClient.nativeSessionRetryTimers = {};
      vi.useRealTimers();
    }
  });

  it('keeps retrying slowly after a SIP credential rejection', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      multi_session: true,
      sessions: [
        {
          provider: 'sipuni',
          sip_profile_id: 41,
          inbox_id: 4771,
          calling_supported: true,
          janusServer: 'wss://dev.one-link.kz/janus-sipuni',
          sip: {
            username: 'operator-41',
            password: 'invalid-secret',
            host: 'sipuni.test',
          },
        },
      ],
    });
    janusInitializeMock.mockRejectedValue(
      Object.assign(new Error('sip_credentials_rejected'), { sipCode: 403 })
    );

    const response = await WebphoneClient.bootstrapIncomingSupport();

    expect(response.sessions[0]).toEqual(
      expect.objectContaining({
        callingSupported: false,
        registered: false,
        reason: 'sip_provider_credentials_failed',
      })
    );
    expect(
      WebphoneClient.nativeSessionRetryTimers['sip_profile:41']
    ).toBeDefined();
    expect(WebphoneClient.nativeSessionRetryState['sip_profile:41']).toEqual(
      expect.objectContaining({
        blocked: false,
        credentialFailure: true,
        reason: 'sip_provider_credentials_failed',
      })
    );
    WebphoneClient.clearNativeSessionRetry('sip_profile:41');
  });

  it('waits a minute before retrying a credential rejection', async () => {
    vi.useFakeTimers();
    const sessionKey = 'sip_profile:41';
    const retrySpy = vi
      .spyOn(WebphoneClient, 'retryNativeSession')
      .mockResolvedValue(null);
    WebphoneClient.nativeSessionRetryState[sessionKey] = {
      response: { provider: 'sipuni', sip_profile_id: 41, inbox_id: 4771 },
      inboxId: 4771,
      provider: 'sipuni',
      blocked: false,
      credentialFailure: true,
    };

    try {
      WebphoneClient.scheduleNativeSessionRetry(sessionKey);

      await vi.advanceTimersByTimeAsync(59_000);
      expect(retrySpy).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1_000);
      expect(retrySpy).toHaveBeenCalledWith(sessionKey);
    } finally {
      retrySpy.mockRestore();
      WebphoneClient.clearNativeSessionRetry(sessionKey);
      delete WebphoneClient.nativeSessionRetryState[sessionKey];
      vi.useRealTimers();
    }
  });

  it('mirrors the owner tab instead of registering SIP in a secondary tab', async () => {
    WebphoneClient.tabLeadership.isLeader = false;
    try {
      const session = await WebphoneClient.initializeFromSession({
        provider: 'sipuni',
        sip_profile_id: 41,
        inbox_id: 4771,
        calling_supported: false,
        registered: true,
        reason: 'sip_profile_registration_lease_owned_by_another_tab',
      });

      expect(janusInitializeMock).not.toHaveBeenCalled();
      expect(session).toEqual(
        expect.objectContaining({
          sessionKey: 'sip_profile:41',
          mirrored: true,
          registered: true,
          callingSupported: true,
          reason: 'webphone_active_in_owner_tab',
        })
      );
      expect(WebphoneClient.nativeSessionRetryTimers['sip_profile:41']).toBe(
        undefined
      );

      WebphoneClient.applyMirroredSessions([
        {
          provider: 'sipuni',
          sessionKey: 'sip_profile:41',
          inboxId: 4771,
          registered: false,
          reason: 'sip_unregistered',
        },
      ]);
      expect(WebphoneClient.sessions['sip_profile:41']).toEqual(
        expect.objectContaining({
          registered: false,
          reason: 'sip_unregistered',
        })
      );

      WebphoneClient.applyMirroredSessions([]);
      expect(WebphoneClient.sessions['sip_profile:41']).toBe(undefined);
    } finally {
      WebphoneClient.tabLeadership.isLeader = true;
    }
  });

  it('joins the owner election of the account the tab works in now', () => {
    const previousPath = window.location.pathname;
    const { tabLeadership } = WebphoneClient;
    const initialScope = tabLeadership.scope;
    WebphoneClient.sessions['sip_profile:41'] = {
      provider: 'sipuni',
      sessionKey: 'sip_profile:41',
      mirrored: true,
    };
    try {
      window.history.pushState({}, '', '/app/accounts/2/dashboard');

      expect(WebphoneClient.syncTabLeadershipScope()).toBe(true);
      expect(tabLeadership.scope).toMatch(/^account:2:user:/);
      expect(WebphoneClient.sessions['sip_profile:41']).toBe(undefined);
      expect(WebphoneClient.syncTabLeadershipScope()).toBe(false);
    } finally {
      window.history.pushState({}, '', previousPath);
      tabLeadership.setScope(initialScope);
    }
  });

  it('keeps a low-frequency recovery loop after the fast retry window', async () => {
    vi.useFakeTimers();
    const sessionKey = 'sip_profile:41';
    const retrySpy = vi
      .spyOn(WebphoneClient, 'retryNativeSession')
      .mockResolvedValue(null);
    WebphoneClient.nativeSessionConfigs[sessionKey] = {
      response: { provider: 'sipuni', sip_profile_id: 41, inbox_id: 4771 },
      inboxId: 4771,
      provider: 'sipuni',
    };
    WebphoneClient.nativeSessionRetryState[sessionKey] = {
      ...WebphoneClient.nativeSessionConfigs[sessionKey],
      attempt: 100,
      blocked: false,
    };

    try {
      WebphoneClient.scheduleNativeSessionRetry(sessionKey);
      expect(WebphoneClient.nativeSessionRetryTimers[sessionKey]).toBeDefined();

      await vi.advanceTimersByTimeAsync(73_000);
      expect(retrySpy).toHaveBeenCalledWith(sessionKey);
    } finally {
      retrySpy.mockRestore();
      WebphoneClient.clearNativeSessionRetry(sessionKey);
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

  // Saving the channel settings destroys the line and re-initialises it for
  // that inbox. A refused registration must leave the line listed (as failed)
  // so the phone stays on screen instead of vanishing until a later bootstrap.
  it('keeps an inbox-scoped native line listed when its registration fails', async () => {
    getNativeWebphoneTokenMock.mockResolvedValue({
      provider: 'beeline',
      calling_supported: true,
      sip_profile_id: 145,
      inbox_id: 5245,
      session_key: 'sip_profile:145',
      janusServer: 'wss://janus-beeline.example.test/janus-beeline',
      sip: {
        username: 'ext-1',
        password: 'sip-secret',
        host: 'VPBX-COMPANY-TEST.CLOUDPBX.BEELINE.KZ',
      },
    });
    janusInitializeMock.mockRejectedValue(
      new Error('sip_profile_registration_context_mismatch')
    );
    const changes = [];
    const onChange = event => changes.push(event.detail);
    WebphoneClient.addEventListener('call:sessions-changed', onChange);

    await expect(
      WebphoneClient.initializeDevice(5245, {
        native: true,
        provider: 'beeline',
      })
    ).rejects.toThrow('sip_profile_registration_context_mismatch');
    WebphoneClient.removeEventListener('call:sessions-changed', onChange);

    expect(WebphoneClient.sessions['sip_profile:145']).toEqual(
      expect.objectContaining({
        provider: 'beeline',
        inboxId: 5245,
        sipProfileId: 145,
        registered: false,
        reason: 'sip_profile_registration_context_mismatch',
      })
    );
    expect(changes).toContainEqual({
      sessionKey: 'sip_profile:145',
      action: 'updated',
    });
  });

  it('does not overwrite a newer line with the failure of a replaced one', async () => {
    getNativeWebphoneTokenMock.mockResolvedValue({
      provider: 'beeline',
      calling_supported: true,
      sip_profile_id: 145,
      inbox_id: 5245,
      session_key: 'sip_profile:145',
      janusServer: 'wss://janus-beeline.example.test/janus-beeline',
      sip: { username: 'ext-1', password: 'sip-secret', host: 'pbx.test' },
    });
    const newerSession = {
      provider: 'beeline',
      sessionKey: 'sip_profile:145',
      inboxId: 5245,
      callingSupported: true,
      registered: true,
    };
    janusInitializeMock.mockImplementation(async () => {
      // A config refresh replaced this client while it was registering.
      WebphoneClient.invalidateNativeSession('sip_profile:145');
      WebphoneClient.sessions['sip_profile:145'] = newerSession;
      throw new Error('stale_sip_registration');
    });

    await expect(
      WebphoneClient.initializeDevice(5245, { native: true })
    ).rejects.toThrow('stale_sip_registration');

    expect(WebphoneClient.sessions['sip_profile:145']).toBe(newerSession);
  });

  it('releases native SIP leases with keepalive semantics on pagehide', async () => {
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
    await WebphoneClient.initializeDevice(4083, { native: true });

    window.dispatchEvent(new Event('pagehide'));
    await vi.waitFor(() => {
      expect(janusDestroyMock).toHaveBeenCalledWith({
        keepalivePresence: true,
      });
    });
    expect(WebphoneClient.sessions['sip_profile:501']).toEqual(
      expect.objectContaining({
        registered: false,
        reason: 'page_hidden',
      })
    );
  });

  it('registers the unload guard only while a native SIP call is active', async () => {
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
    await WebphoneClient.initializeDevice(4083, { native: true });
    const client = WebphoneClient.nativeSipClients['sip_profile:501'];
    const addSpy = vi.spyOn(window, 'addEventListener');
    const removeSpy = vi.spyOn(window, 'removeEventListener');
    client.hasActiveCall = true;

    WebphoneClient.syncNativeCallUnloadGuard();
    expect(addSpy).toHaveBeenCalledWith(
      'beforeunload',
      WebphoneClient.handleBeforeUnload
    );
    const activeCallUnload = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(activeCallUnload);
    expect(activeCallUnload.defaultPrevented).toBe(true);
    expect(janusDestroyMock).not.toHaveBeenCalled();

    client.hasActiveCall = false;
    WebphoneClient.syncNativeCallUnloadGuard();
    expect(removeSpy).toHaveBeenCalledWith(
      'beforeunload',
      WebphoneClient.handleBeforeUnload
    );
    const idleUnload = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(idleUnload);
    expect(idleUnload.defaultPrevented).toBe(false);
    addSpy.mockRestore();
    removeSpy.mockRestore();
  });

  it.each([
    [
      'a pending incoming call',
      { pendingIncomingCall: { callRef: 'incoming' } },
    ],
    ['a sent outbound SIP call', { outboundAttempt: { sipCallSent: true } }],
  ])('guards page unload for %s', async (_description, callState) => {
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
    await WebphoneClient.initializeDevice(4083, { native: true });
    Object.assign(
      WebphoneClient.nativeSipClients['sip_profile:501'],
      callState
    );

    WebphoneClient.syncNativeCallUnloadGuard();
    const event = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(true);
  });

  it.each([
    ['rejectIncomingCall', 'pendingIncomingCall'],
    ['endClientCall', 'hasActiveCall'],
  ])(
    'removes the unload guard after local %s cleanup',
    async (action, stateField) => {
      const client = {
        rejectIncomingCall: vi.fn(async () => {
          client.pendingIncomingCall = null;
        }),
        endClientCall: vi.fn(async () => {
          client.hasActiveCall = false;
        }),
        [stateField]:
          stateField === 'pendingIncomingCall' ? { callRef: 'incoming' } : true,
      };
      WebphoneClient.nativeSipClients['sip_profile:501'] = client;
      WebphoneClient.sessions['sip_profile:501'] = {
        provider: 'sipuni',
        sessionKey: 'sip_profile:501',
        sipProfileId: 501,
      };
      WebphoneClient.syncNativeCallUnloadGuard();

      await WebphoneClient[action]({
        provider: 'sipuni',
        sessionKey: 'sip_profile:501',
      });

      const event = new Event('beforeunload', { cancelable: true });
      window.dispatchEvent(event);
      expect(event.defaultPrevented).toBe(false);
      expect(WebphoneClient.nativeCallUnloadGuardRegistered).toBe(false);
    }
  );

  it('removes a stale unload guard when replacing the only active session', () => {
    const staleClient = {
      hasActiveCall: true,
      destroyDevice: vi.fn(),
      addEventListener: vi.fn(),
    };
    WebphoneClient.nativeSipClients = {
      'sip_profile:501': staleClient,
      'sip_profile:502': { hasActiveCall: false },
    };
    WebphoneClient.nativeSipClientGenerations = {
      'sip_profile:501': 1,
      'sip_profile:502': 1,
    };
    WebphoneClient.syncNativeCallUnloadGuard();

    WebphoneClient.nativeSipClientFor('sipuni', 'sip_profile:501', 2);

    const event = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(false);
    expect(WebphoneClient.nativeCallUnloadGuardRegistered).toBe(false);
    expect(staleClient.destroyDevice).toHaveBeenCalledOnce();
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

  it('forwards exact call references to scoped native SIP cleanup', async () => {
    const client = {
      rejectIncomingCall: vi.fn(),
      endClientCall: vi.fn(),
    };
    const session = {
      provider: 'sipuni',
      sessionKey: 'sip_profile:501',
      sipProfileId: 501,
      inboxId: 4083,
      registered: true,
      callingSupported: true,
    };
    WebphoneClient.nativeSipClients[session.sessionKey] = client;
    WebphoneClient.sessions[session.sessionKey] = session;
    WebphoneClient.providerSessions.sipuni = session;

    const callScope = {
      provider: 'sipuni',
      sessionKey: 'sip_profile:501',
      sipProfileId: 501,
      inboxId: 4083,
      callSid: 'provider-call-a',
      janusCallRef: 'janus-call-a',
    };
    await WebphoneClient.rejectIncomingCall(callScope);
    await WebphoneClient.endClientCall(callScope);

    expect(client.rejectIncomingCall).toHaveBeenCalledWith(
      expect.objectContaining({
        callRef: 'provider-call-a',
        janusCallRef: 'janus-call-a',
      })
    );
    expect(client.endClientCall).toHaveBeenCalledWith(
      expect.objectContaining({
        callRef: 'provider-call-a',
        janusCallRef: 'janus-call-a',
      })
    );
  });

  describe('sign-out and a browser shared by several users', () => {
    const SESSION_COOKIE = 'cw_d_session_info';
    const LOGOUT_OPTIONS = {
      keepalivePresence: true,
      awaitPresenceRelease: true,
    };

    const registerNativeSession = async () => {
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
      await WebphoneClient.initializeDevice(4083, { native: true });
    };

    afterEach(() => {
      Cookies.remove(SESSION_COOKIE);
      WebphoneClient.loadedUserUid = '';
      WebphoneClient.staleUserRelease = null;
      WebphoneClient.tabLeadership.isLeader = true;
      vi.useRealTimers();
    });

    it('releases the phone of the owner tab with an awaited keepalive unregister', async () => {
      await registerNativeSession();

      await WebphoneClient.releaseForLogout();

      expect(janusDestroyMock).toHaveBeenCalledWith(LOGOUT_OPTIONS);
      expect(WebphoneClient.sessions['sip_profile:501']).toBeUndefined();
    });

    it('asks the owner tab to release the phone when a follower tab signs out', async () => {
      const { tabLeadership } = WebphoneClient;
      const postSpy = vi
        .spyOn(tabLeadership, 'post')
        .mockImplementation(() => {});
      tabLeadership.isLeader = false;
      try {
        const release = WebphoneClient.releaseForLogout();
        const [request] = postSpy.mock.calls
          .map(([message]) => message)
          .filter(message => message.type === 'logout-release');
        expect(request.requestId).toEqual(expect.any(String));

        tabLeadership.dispatchEvent(
          new CustomEvent('message', {
            detail: {
              type: 'logout-release-done',
              requestId: request.requestId,
            },
          })
        );
        await release;

        expect(janusDestroyMock).not.toHaveBeenCalled();
      } finally {
        postSpy.mockRestore();
      }
    });

    it('does not wait for an owner tab that never answers on sign-out', async () => {
      vi.useFakeTimers();
      const { tabLeadership } = WebphoneClient;
      const postSpy = vi
        .spyOn(tabLeadership, 'post')
        .mockImplementation(() => {});
      tabLeadership.isLeader = false;
      try {
        let settled = false;
        WebphoneClient.releaseForLogout().then(() => {
          settled = true;
        });

        await vi.advanceTimersByTimeAsync(1_900);
        expect(settled).toBe(false);
        await vi.advanceTimersByTimeAsync(200);
        expect(settled).toBe(true);
      } finally {
        postSpy.mockRestore();
      }
    });

    it('releases the phone when a follower tab of the same user signs out', async () => {
      await registerNativeSession();
      const postSpy = vi
        .spyOn(WebphoneClient.tabLeadership, 'post')
        .mockImplementation(() => {});
      try {
        WebphoneClient.handleTabMessage({
          type: 'logout-release',
          requestId: 'request-1',
          from: 'tab-follower',
        });

        await vi.waitFor(() => {
          expect(postSpy).toHaveBeenCalledWith({
            type: 'logout-release-done',
            requestId: 'request-1',
            to: 'tab-follower',
          });
        });
        expect(janusDestroyMock).toHaveBeenCalledWith(LOGOUT_OPTIONS);
      } finally {
        postSpy.mockRestore();
      }
    });

    it('keeps the call and the unload guard when the owner tab signs out during a call', async () => {
      await registerNativeSession();
      const client = WebphoneClient.nativeSipClients['sip_profile:501'];
      client.hasActiveCall = true;
      try {
        WebphoneClient.syncNativeCallUnloadGuard();

        await WebphoneClient.releaseForLogout();

        expect(janusDestroyMock).not.toHaveBeenCalled();
        expect(WebphoneClient.sessions['sip_profile:501']).toBeDefined();
        expect(WebphoneClient.nativeCallUnloadGuardRegistered).toBe(true);
        const unload = new Event('beforeunload', { cancelable: true });
        window.dispatchEvent(unload);
        expect(unload.defaultPrevented).toBe(true);
      } finally {
        client.hasActiveCall = false;
        WebphoneClient.syncNativeCallUnloadGuard();
      }
    });

    it('keeps the call of the owner tab when a follower tab signs out', async () => {
      await registerNativeSession();
      const client = WebphoneClient.nativeSipClients['sip_profile:501'];
      client.hasActiveCall = true;
      const postSpy = vi
        .spyOn(WebphoneClient.tabLeadership, 'post')
        .mockImplementation(() => {});
      try {
        WebphoneClient.handleTabMessage({
          type: 'logout-release',
          requestId: 'request-2',
          from: 'tab-follower',
        });

        await vi.waitFor(() => {
          expect(postSpy).toHaveBeenCalledWith({
            type: 'logout-release-done',
            requestId: 'request-2',
            to: 'tab-follower',
          });
        });
        expect(janusDestroyMock).not.toHaveBeenCalled();
        expect(WebphoneClient.sessions['sip_profile:501']).toBeDefined();
      } finally {
        postSpy.mockRestore();
        client.hasActiveCall = false;
        WebphoneClient.syncNativeCallUnloadGuard();
      }
    });

    it('gives the phone up when another user signed in in this browser', async () => {
      await registerNativeSession();
      WebphoneClient.loadedUserUid = 'asel@example.com';
      Cookies.set(
        SESSION_COOKIE,
        JSON.stringify({ uid: 'marina@example.com' })
      );

      WebphoneClient.resumeNativeSessions();

      await vi.waitFor(() => {
        expect(janusDestroyMock).toHaveBeenCalledWith({
          keepalivePresence: true,
        });
      });
      expect(WebphoneClient.sessions['sip_profile:501']).toBeUndefined();
    });

    it('never registers the phone again for a tab whose user was replaced', async () => {
      WebphoneClient.loadedUserUid = 'asel@example.com';
      Cookies.set(
        SESSION_COOKIE,
        JSON.stringify({ uid: 'marina@example.com' })
      );

      await expect(
        WebphoneClient.initializeDevice(4083, { native: true })
      ).resolves.toBeNull();
      await expect(
        WebphoneClient.bootstrapIncomingSupport()
      ).resolves.toBeNull();

      expect(getNativeWebphoneTokenMock).not.toHaveBeenCalled();
      expect(getWebphoneTokenMock).not.toHaveBeenCalled();
    });

    it('keeps the phone while the signed-in user stays the same', async () => {
      await registerNativeSession();
      WebphoneClient.loadedUserUid = 'asel@example.com';
      Cookies.set(SESSION_COOKIE, JSON.stringify({ uid: 'asel@example.com' }));

      WebphoneClient.resumeNativeSessions();

      expect(janusDestroyMock).not.toHaveBeenCalled();
      expect(WebphoneClient.sessions['sip_profile:501']).toBeDefined();
    });
  });

  describe('waiting for the phone and incoming calls', () => {
    const scope = {
      provider: 'sipuni',
      inboxId: 4083,
      sessionKey: 'sip_profile:777',
    };
    const phoneSession = registered => ({
      provider: 'sipuni',
      sessionKey: 'sip_profile:777',
      inboxId: 4083,
      sipProfileId: 777,
      callingSupported: true,
      registered,
      reason: registered ? null : 'outbound_sip_handle_reset',
    });

    afterEach(() => {
      delete WebphoneClient.sessions['sip_profile:777'];
      delete WebphoneClient.providerSessions.sipuni;
      delete WebphoneClient.nativeSipClients['sip_profile:777'];
      Cookies.remove('cw_d_session_info');
      WebphoneClient.loadedUserUid = '';
      vi.useRealTimers();
    });

    it('resolves with the session as soon as the phone registered again', async () => {
      WebphoneClient.rememberSession(phoneSession(false));

      const waiting = WebphoneClient.waitForRegistration(scope);
      WebphoneClient.rememberSession(phoneSession(true));

      await expect(waiting).resolves.toMatchObject({ registered: true });
    });

    it('resolves at once when the phone is already registered', async () => {
      WebphoneClient.rememberSession(phoneSession(true));

      await expect(
        WebphoneClient.waitForRegistration(scope)
      ).resolves.toMatchObject({ registered: true });
    });

    it('gives up with null when the phone stays unregistered', async () => {
      vi.useFakeTimers();
      WebphoneClient.rememberSession(phoneSession(false));
      let result;
      WebphoneClient.waitForRegistration(scope, 3_000).then(value => {
        result = value;
      });

      await vi.advanceTimersByTimeAsync(2_900);
      expect(result).toBeUndefined();
      await vi.advanceTimersByTimeAsync(200);
      expect(result).toBeNull();
    });

    it('knows when an incoming call rings in the phone of this browser', () => {
      expect(WebphoneClient.hasIncomingCallRinging()).toBe(false);

      WebphoneClient.nativeSipClients['sip_profile:777'] = {
        pendingIncomingCall: { callId: 'ringing-1' },
      };
      expect(WebphoneClient.hasIncomingCallRinging()).toBe(true);

      WebphoneClient.nativeSipClients['sip_profile:777'] = {
        pendingIncomingCall: null,
      };
      expect(WebphoneClient.hasIncomingCallRinging()).toBe(false);
    });

    it('does not retry the phone of a user who was replaced in this browser', async () => {
      WebphoneClient.loadedUserUid = 'asel@example.com';
      Cookies.set(
        'cw_d_session_info',
        JSON.stringify({ uid: 'marina@example.com' })
      );

      await expect(
        WebphoneClient.retryNativeSession('sip_profile:777')
      ).resolves.toBeNull();

      expect(getNativeWebphoneTokenMock).not.toHaveBeenCalled();
    });
  });
});
