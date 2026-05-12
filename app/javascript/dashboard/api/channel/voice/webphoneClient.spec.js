import { beforeEach, describe, expect, it, vi } from 'vitest';

const { getWebphoneTokenMock, twilioInitializeMock, fonosterInitializeMock } =
  vi.hoisted(() => ({
    getWebphoneTokenMock: vi.fn(),
    twilioInitializeMock: vi.fn(),
    fonosterInitializeMock: vi.fn(),
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
    destroyDevice: vi.fn(),
  },
}));

import WebphoneClient from './webphoneClient';

describe('webphoneClient', () => {
  beforeEach(() => {
    getWebphoneTokenMock.mockReset();
    twilioInitializeMock.mockReset();
    fonosterInitializeMock.mockReset();
    WebphoneClient.activeProvider = null;
    WebphoneClient.providerSessions = {};
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
    });
    fonosterInitializeMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: false,
    });

    await WebphoneClient.bootstrapIncomingSupport();

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
