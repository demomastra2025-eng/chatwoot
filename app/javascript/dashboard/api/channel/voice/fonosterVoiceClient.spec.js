import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
  connectMock,
  disconnectMock,
  registerMock,
  unregisterMock,
  answerMock,
  defaultSessionDescriptionHandlerFactoryMock,
  updateWebphonePresenceMock,
  simpleUserConstructorMock,
} = vi.hoisted(() => ({
  connectMock: vi.fn(),
  disconnectMock: vi.fn(),
  registerMock: vi.fn(),
  unregisterMock: vi.fn(),
  answerMock: vi.fn(),
  defaultSessionDescriptionHandlerFactoryMock: vi.fn(factory => factory),
  updateWebphonePresenceMock: vi.fn(),
  simpleUserConstructorMock: vi.fn(),
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    updateWebphonePresence: updateWebphonePresenceMock,
  },
}));

vi.mock('sip.js', () => ({
  Web: {
    defaultSessionDescriptionHandlerFactory:
      defaultSessionDescriptionHandlerFactoryMock,
    SimpleUser: simpleUserConstructorMock,
  },
}));

const completeSessionConfig = {
  provider: 'fonoster',
  calling_supported: true,
  token: 'test-token',
  username: 'agent-42',
  domain: 'agents.example.test',
  signalingServer: 'wss://bridge.example/ws',
  targetAor: 'sip:agent-42@agents.example.test',
};

const importClient = async () => {
  vi.resetModules();
  const mod = await import('./fonosterVoiceClient');
  return mod.default;
};

describe('fonosterVoiceClient', () => {
  const originalMediaDevicesDescriptor = Object.getOwnPropertyDescriptor(
    navigator,
    'mediaDevices'
  );

  beforeEach(() => {
    connectMock.mockReset();
    disconnectMock.mockReset();
    registerMock.mockReset();
    unregisterMock.mockReset();
    answerMock.mockReset();
    defaultSessionDescriptionHandlerFactoryMock.mockClear();
    defaultSessionDescriptionHandlerFactoryMock.mockImplementation(
      factory => factory
    );
    updateWebphonePresenceMock.mockReset();
    simpleUserConstructorMock.mockReset();

    connectMock.mockResolvedValue(undefined);
    disconnectMock.mockResolvedValue(undefined);
    unregisterMock.mockResolvedValue(undefined);
    answerMock.mockResolvedValue(undefined);
    updateWebphonePresenceMock.mockResolvedValue({});
  });

  afterEach(() => {
    if (originalMediaDevicesDescriptor) {
      Object.defineProperty(
        navigator,
        'mediaDevices',
        originalMediaDevicesDescriptor
      );
      return;
    }

    Reflect.deleteProperty(navigator, 'mediaDevices');
  });

  it('reports browser presence when SIP registration succeeds', async () => {
    registerMock.mockImplementation(() => {
      simpleUserConstructorMock.mock.calls[0][1].delegate.onRegistered();
      return Promise.resolve();
    });
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    const response = await client.initializeDevice(completeSessionConfig);

    expect(response).toEqual(
      expect.objectContaining({ provider: 'fonoster', registered: true })
    );
    expect(updateWebphonePresenceMock).not.toHaveBeenCalledWith(false);
    expect(updateWebphonePresenceMock).toHaveBeenCalledWith(true);
  });

  it('reports browser presence when SIP register resolves even if delegate callback is missed', async () => {
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    const response = await client.initializeDevice(completeSessionConfig);

    expect(response).toEqual(
      expect.objectContaining({ provider: 'fonoster', registered: true })
    );
    expect(updateWebphonePresenceMock).toHaveBeenCalledWith(true);
  });

  it('refreshes browser presence while the SIP registration stays active', async () => {
    vi.useFakeTimers();
    registerMock.mockImplementation(() => {
      simpleUserConstructorMock.mock.calls[0][1].delegate.onRegistered();
      return Promise.resolve();
    });
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    try {
      const client = await importClient();
      await client.initializeDevice(completeSessionConfig);
      updateWebphonePresenceMock.mockClear();

      vi.advanceTimersByTime(60_000);

      expect(updateWebphonePresenceMock).toHaveBeenCalledWith(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it('keeps the active SIP connection but re-registers when only the webphone token rotates', async () => {
    registerMock.mockImplementation(() => {
      simpleUserConstructorMock.mock.calls[0][1].delegate.onRegistered();
      return Promise.resolve();
    });
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    await client.initializeDevice(completeSessionConfig);
    await client.initializeDevice({
      ...completeSessionConfig,
      token: 'rotated-token-for-same-operator',
    });

    expect(simpleUserConstructorMock).toHaveBeenCalledTimes(1);
    expect(unregisterMock).not.toHaveBeenCalled();
    expect(disconnectMock).not.toHaveBeenCalled();
    expect(registerMock).toHaveBeenCalledTimes(2);
    expect(registerMock.mock.calls[1][0]).toEqual({
      requestOptions: {
        extraHeaders: ['X-Connect-Token: rotated-token-for-same-operator'],
      },
    });
  });

  it('disables SIP.js built-in request logging so webphone tokens are not printed to the browser console', async () => {
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    await client.initializeDevice(completeSessionConfig);

    expect(simpleUserConstructorMock.mock.calls[0][1].userAgentOptions).toEqual(
      expect.objectContaining({
        logBuiltinEnabled: false,
        logConfiguration: false,
        logLevel: 'error',
      })
    );
  });

  it('marks browser presence offline when the SIP server disconnects', async () => {
    registerMock.mockImplementation(() => {
      simpleUserConstructorMock.mock.calls[0][1].delegate.onRegistered();
      return Promise.resolve();
    });
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    await client.initializeDevice(completeSessionConfig);
    updateWebphonePresenceMock.mockClear();

    simpleUserConstructorMock.mock.calls[0][1].delegate.onServerDisconnect();

    expect(updateWebphonePresenceMock).toHaveBeenCalledWith(false);
    expect(client.sessionState().registered).toBe(false);
  });

  it('waits briefly for delayed SIP INVITE before giving up on answer', async () => {
    vi.useFakeTimers();
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      answer: answerMock,
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    try {
      const client = await importClient();
      await client.initializeDevice(completeSessionConfig);

      const joinPromise = client.joinClientCall();
      await vi.advanceTimersByTimeAsync(2_000);
      simpleUserConstructorMock.mock.calls[0][1].delegate.onCallReceived();
      await vi.advanceTimersByTimeAsync(100);

      await expect(joinPromise).resolves.toEqual({
        provider: 'fonoster',
        answered: true,
      });
      expect(answerMock).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('waits longer for the operator SIP INVITE on outbound calls', async () => {
    vi.useFakeTimers();
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      answer: answerMock,
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    try {
      const client = await importClient();
      await client.initializeDevice(completeSessionConfig);

      let settled = false;
      const joinPromise = client
        .joinClientCall({ callDirection: 'outbound' })
        .then(result => {
          settled = true;
          return result;
        });

      await vi.advanceTimersByTimeAsync(8_000);
      expect(settled).toBe(false);

      simpleUserConstructorMock.mock.calls[0][1].delegate.onCallReceived();
      await vi.advanceTimersByTimeAsync(100);

      await expect(joinPromise).resolves.toEqual({
        provider: 'fonoster',
        answered: true,
      });
      expect(answerMock).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('prewarms the microphone and reuses that stream for SIP media', async () => {
    const audioTrack = { kind: 'audio', readyState: 'live', stop: vi.fn() };
    const stream = {
      getAudioTracks: () => [audioTrack],
      getTracks: () => [audioTrack],
    };
    const getUserMediaMock = vi.fn().mockResolvedValue(stream);
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia: getUserMediaMock },
    });
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    await client.initializeDevice(completeSessionConfig);
    await expect(client.prewarmMicrophone()).resolves.toEqual({
      provider: 'fonoster',
      prewarmed: true,
    });

    const mediaStreamFactory =
      simpleUserConstructorMock.mock.calls[0][1].userAgentOptions
        .sessionDescriptionHandlerFactory;
    await expect(
      mediaStreamFactory({ audio: true, video: false })
    ).resolves.toBe(stream);

    expect(getUserMediaMock).toHaveBeenCalledTimes(1);
    expect(getUserMediaMock).toHaveBeenCalledWith({
      audio: true,
      video: false,
    });
  });

  it('keeps an in-flight microphone prewarm during cold SIP initialization', async () => {
    let resolveMedia;
    const audioTrack = { kind: 'audio', readyState: 'live', stop: vi.fn() };
    const stream = {
      getAudioTracks: () => [audioTrack],
      getTracks: () => [audioTrack],
    };
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: vi.fn(
          () =>
            new Promise(resolve => {
              resolveMedia = resolve;
            })
        ),
      },
    });
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    const prewarmPromise = client.prewarmMicrophone();
    await client.initializeDevice(completeSessionConfig);
    resolveMedia(stream);

    await expect(prewarmPromise).resolves.toEqual({
      provider: 'fonoster',
      prewarmed: true,
    });
    expect(audioTrack.stop).not.toHaveBeenCalled();
  });

  it('stops the prewarmed microphone if the outbound SIP INVITE never arrives', async () => {
    vi.useFakeTimers();
    const audioTrack = { kind: 'audio', readyState: 'live', stop: vi.fn() };
    const stream = {
      getAudioTracks: () => [audioTrack],
      getTracks: () => [audioTrack],
    };
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia: vi.fn().mockResolvedValue(stream) },
    });
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      answer: answerMock,
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    try {
      const client = await importClient();
      await client.initializeDevice(completeSessionConfig);
      await client.prewarmMicrophone();
      const joinPromise = client.joinClientCall({
        callRef: 'call-no-invite',
        callDirection: 'outbound',
      });

      await vi.advanceTimersByTimeAsync(45_000);

      await expect(joinPromise).resolves.toBeNull();
      expect(audioTrack.stop).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('stops a prewarmed microphone when ending a call without an active SIP leg', async () => {
    const audioTrack = { kind: 'audio', readyState: 'live', stop: vi.fn() };
    const stream = {
      getAudioTracks: () => [audioTrack],
      getTracks: () => [audioTrack],
    };
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia: vi.fn().mockResolvedValue(stream) },
    });
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    await client.initializeDevice(completeSessionConfig);
    await client.prewarmMicrophone();

    await expect(client.endClientCall()).resolves.toBeNull();
    expect(audioTrack.stop).toHaveBeenCalledTimes(1);
  });

  it('includes the current call ref when the SIP leg disconnects', async () => {
    registerMock.mockResolvedValue(undefined);
    simpleUserConstructorMock.mockImplementation(() => ({
      answer: answerMock,
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    const listener = vi.fn();
    client.addEventListener('call:disconnected', listener);
    await client.initializeDevice(completeSessionConfig);

    simpleUserConstructorMock.mock.calls[0][1].delegate.onCallReceived();
    await client.joinClientCall({
      callRef: 'call-ref-current',
      callDirection: 'outbound',
    });
    simpleUserConstructorMock.mock.calls[0][1].delegate.onCallHangup();

    expect(listener).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: {
          provider: 'fonoster',
          callRef: 'call-ref-current',
          callDirection: 'outbound',
        },
      })
    );
  });

  it('notifies aggregators that registration is unavailable after server disconnect', async () => {
    registerMock.mockImplementation(() => {
      simpleUserConstructorMock.mock.calls[0][1].delegate.onRegistered();
      return Promise.resolve();
    });
    simpleUserConstructorMock.mockImplementation(() => ({
      connect: connectMock,
      disconnect: disconnectMock,
      register: registerMock,
      unregister: unregisterMock,
      isConnected: () => true,
    }));

    const client = await importClient();
    const listener = vi.fn();
    client.addEventListener('call:unregistered', listener);
    await client.initializeDevice(completeSessionConfig);
    listener.mockClear();

    simpleUserConstructorMock.mock.calls[0][1].delegate.onServerDisconnect();

    expect(listener).toHaveBeenCalledWith(
      expect.objectContaining({ detail: { provider: 'fonoster' } })
    );
  });
});
