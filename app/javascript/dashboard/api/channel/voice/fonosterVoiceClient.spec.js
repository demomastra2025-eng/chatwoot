import { beforeEach, describe, expect, it, vi } from 'vitest';

const {
  connectMock,
  disconnectMock,
  registerMock,
  unregisterMock,
  answerMock,
  updateWebphonePresenceMock,
  simpleUserConstructorMock,
} = vi.hoisted(() => ({
  connectMock: vi.fn(),
  disconnectMock: vi.fn(),
  registerMock: vi.fn(),
  unregisterMock: vi.fn(),
  answerMock: vi.fn(),
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
  beforeEach(() => {
    connectMock.mockReset();
    disconnectMock.mockReset();
    registerMock.mockReset();
    unregisterMock.mockReset();
    answerMock.mockReset();
    updateWebphonePresenceMock.mockReset();
    simpleUserConstructorMock.mockReset();

    connectMock.mockResolvedValue(undefined);
    disconnectMock.mockResolvedValue(undefined);
    unregisterMock.mockResolvedValue(undefined);
    answerMock.mockResolvedValue(undefined);
    updateWebphonePresenceMock.mockResolvedValue({});
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
    expect(updateWebphonePresenceMock).toHaveBeenCalledWith(false);
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

  it('keeps the active SIP registration when only the webphone token rotates', async () => {
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
    expect(registerMock).toHaveBeenCalledTimes(1);
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
