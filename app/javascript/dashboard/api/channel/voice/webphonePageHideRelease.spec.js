import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('janus-gateway', () => ({
  default: { init: vi.fn(), attachMediaStream: vi.fn() },
}));

vi.mock('dashboard/api/channel/voice/twilioVoiceClient', () => ({
  default: {
    addEventListener: vi.fn(),
    initializeDevice: vi.fn(),
    destroyDevice: vi.fn(),
  },
}));

import { createJanusSipVoiceClient } from './janusSipVoiceClient';
import WebphoneClient from './webphoneClient';

// The real chain: the page goes away (pagehide), the tab gives its SIP line
// up, and the browser queues the release beacon with the signed key of the
// lease. Nothing waits for the lease to expire.
describe('freeing the line when the page goes away', () => {
  const releasePath = '/api/v1/accounts/530/telephony/webphone/release';
  const originalAxios = window.axios;
  const originalPathname = window.location.pathname;
  const sessionKey = 'sip_profile:501';
  let sendBeacon;
  let fetchMock;

  const holdTheLine = (releaseKey = 'signed-release-key') => {
    const response = {
      provider: 'sipuni',
      calling_supported: true,
      sip_profile_id: 501,
      inbox_id: 4083,
      session_key: sessionKey,
    };
    const client = createJanusSipVoiceClient();
    client.sessionConfig = {
      ...response,
      sessionKey,
      sipProfileId: 501,
      registrationInstanceId: 'registration-1',
      registrationReleaseKey: releaseKey,
    };
    client.inboxId = 4083;
    client.sipProfileId = 501;
    client.initialized = true;
    client.registered = true;
    WebphoneClient.nativeSipClients[sessionKey] = client;
    WebphoneClient.rememberNativeSessionConfig(sessionKey, response, {
      inboxId: 4083,
      provider: 'sipuni',
    });
    return client;
  };

  beforeEach(() => {
    window.axios = { post: vi.fn(), defaults: { headers: { common: {} } } };
    window.history.pushState({}, '', '/app/accounts/530/dashboard');
    sendBeacon = vi.fn(() => true);
    Object.defineProperty(window.navigator, 'sendBeacon', {
      value: sendBeacon,
      configurable: true,
      writable: true,
    });
    fetchMock = vi.fn(() => Promise.resolve({ ok: true }));
    vi.stubGlobal('fetch', fetchMock);
    WebphoneClient.nativeSipClients = {};
    WebphoneClient.nativeSessionConfigs = {};
    WebphoneClient.nativeSessionRetryTimers = {};
    WebphoneClient.nativeSessionRetryState = {};
    WebphoneClient.sessions = {};
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPathname);
    delete window.navigator.sendBeacon;
    vi.unstubAllGlobals();
  });

  it('queues the release beacon with the lease key when the page is hidden', async () => {
    holdTheLine();

    window.dispatchEvent(new Event('pagehide'));

    await vi.waitFor(() => expect(sendBeacon).toHaveBeenCalledOnce());
    const [path, body] = sendBeacon.mock.calls[0];
    expect(path).toBe(releasePath);
    expect(body.get('release_key')).toBe('signed-release-key');
    // The ordinary presence request goes out too; the beacon does not depend on it.
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalled());
  });

  it('does not release anything when the page only enters the back/forward cache', async () => {
    holdTheLine();

    const event = new Event('pagehide');
    event.persisted = true;
    window.dispatchEvent(event);
    await Promise.resolve();

    expect(sendBeacon).not.toHaveBeenCalled();
  });

  it('still frees the line when the phone never got registered', async () => {
    const client = holdTheLine();
    client.registered = false;
    client.initialized = false;

    window.dispatchEvent(new Event('pagehide'));

    await vi.waitFor(() => expect(sendBeacon).toHaveBeenCalledOnce());
    expect(sendBeacon.mock.calls[0][1].get('release_key')).toBe(
      'signed-release-key'
    );
  });
});
