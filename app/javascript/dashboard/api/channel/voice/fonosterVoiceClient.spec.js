import { beforeEach, describe, expect, it, vi } from 'vitest';

const {
  connectMock,
  disconnectMock,
  registerMock,
  unregisterMock,
  updateWebphonePresenceMock,
  simpleUserConstructorMock,
} = vi.hoisted(() => ({
  connectMock: vi.fn(),
  disconnectMock: vi.fn(),
  registerMock: vi.fn(),
  unregisterMock: vi.fn(),
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
    updateWebphonePresenceMock.mockReset();
    simpleUserConstructorMock.mockReset();

    connectMock.mockResolvedValue(undefined);
    disconnectMock.mockResolvedValue(undefined);
    unregisterMock.mockResolvedValue(undefined);
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
