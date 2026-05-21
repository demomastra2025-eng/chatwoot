import { beforeEach, describe, expect, it, vi } from 'vitest';

const {
  getWebphoneTokenMock,
  twilioInitializeMock,
  fonosterInitializeMock,
  fonosterDestroyMock,
} = vi.hoisted(() => ({
  getWebphoneTokenMock: vi.fn(),
  twilioInitializeMock: vi.fn(),
  fonosterInitializeMock: vi.fn(),
  fonosterDestroyMock: vi.fn(),
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getWebphoneToken: getWebphoneTokenMock,
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
    rejectIncomingCall: vi.fn(),
    endClientCall: vi.fn(),
    destroyDevice: fonosterDestroyMock,
  },
}));

import WebphoneClient from './webphoneClient';

describe('webphoneClient', () => {
  beforeEach(() => {
    getWebphoneTokenMock.mockReset();
    twilioInitializeMock.mockReset();
    fonosterInitializeMock.mockReset();
    fonosterDestroyMock.mockReset();
    WebphoneClient.activeProvider = null;
    WebphoneClient.providerSessions = {};
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

  it('marks fonoster browser calling unsupported when the bridge contract says so', async () => {
    getWebphoneTokenMock.mockResolvedValue({
      provider: 'fonoster',
      calling_supported: false,
      reason: 'agent_binding_missing',
    });
    WebphoneClient.activeProvider = 'fonoster';

    const response = await WebphoneClient.bootstrapIncomingSupport();

    expect(response).toEqual(
      expect.objectContaining({
        provider: 'fonoster',
        callingSupported: false,
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

  it('keeps outbound fonoster calls out of the browser-join path', () => {
    WebphoneClient.providerSessions.fonoster = {
      provider: 'fonoster',
      callingSupported: true,
    };

    expect(
      WebphoneClient.supportsBrowserCalling('fonoster', {
        callDirection: 'outbound',
      })
    ).toBe(false);
    expect(
      WebphoneClient.supportsBrowserCalling('fonoster', {
        callDirection: 'inbound',
      })
    ).toBe(true);
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
