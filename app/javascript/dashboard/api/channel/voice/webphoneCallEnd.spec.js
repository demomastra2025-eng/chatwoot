/* eslint-disable max-classes-per-file, class-methods-use-this */
// The real WebphoneClient and Janus SIP client, only Janus and the API are
// faked: what the phone header and the sidebar button show after a call.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { phoneWidgetStatusColor } from 'dashboard/stores/phoneWidget';

const {
  pluginSendMock,
  pluginHangupMock,
  pluginDetachMock,
  janusDestroyMock,
  pluginState,
  getNativeWebphoneTokenMock,
  updatePresenceMock,
} = vi.hoisted(() => ({
  pluginSendMock: vi.fn(),
  pluginHangupMock: vi.fn(),
  pluginDetachMock: vi.fn(),
  janusDestroyMock: vi.fn(),
  pluginState: { options: null },
  getNativeWebphoneTokenMock: vi.fn(),
  updatePresenceMock: vi.fn(() =>
    Promise.resolve({
      presence_update_accepted: true,
      registered_for_routing: true,
    })
  ),
}));

vi.mock('webrtc-adapter', () => ({
  default: { browserDetails: { browser: 'chrome' } },
  browserDetails: { browser: 'chrome' },
}));

vi.mock('janus-gateway', () => {
  class JanusMock {
    constructor(options = {}) {
      this.options = options;
      window.setTimeout(() => options.success?.(), 0);
    }

    attach(options = {}) {
      pluginState.options = options;
      options.success?.({
        send: pluginSendMock,
        detach: pluginDetachMock,
        hangup: pluginHangupMock,
        createOffer: offerOptions =>
          offerOptions?.success?.({ type: 'offer', sdp: 'mock-sdp' }),
        createAnswer: answerOptions =>
          answerOptions?.success?.({ type: 'answer', sdp: 'mock-answer' }),
      });
    }

    destroy() {
      janusDestroyMock();
      this.options.destroyed?.();
    }
  }

  JanusMock.initDone = false;
  JanusMock.init = vi.fn(({ callback }) => {
    JanusMock.initDone = true;
    callback?.();
  });
  JanusMock.attachMediaStream = vi.fn();

  return { default: JanusMock };
});

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getWebphoneToken: getNativeWebphoneTokenMock,
    getNativeWebphoneToken: getNativeWebphoneTokenMock,
    updateWebphonePresence: updatePresenceMock,
    updateWebphonePresenceOnUnload: vi.fn(() => Promise.resolve(null)),
    rejectIncomingCall: vi.fn(() => Promise.resolve({})),
    uploadWebphoneRecording: vi.fn(() => Promise.resolve({})),
  },
}));

import WebphoneClient from './webphoneClient';

const SESSION_KEY = 'sip_profile:146';
const CALL_REF = 'sipuni:local:outbound-1';
let ticket = 0;
const tokenResponse = () => {
  ticket += 1;
  return {
    provider: 'sipuni',
    callingSupported: true,
    browserJoinSupported: true,
    janusServer: `wss://dev.example.test/janus-sipuni?janus_ticket=t${ticket}`,
    session_key: SESSION_KEY,
    sip_profile_id: 146,
    registration_config_version: 'config-1',
    registration_instance_id: 'lease-1',
    account_id: 5118,
    inbox_id: 5248,
    sip: {
      username: '990001000018',
      password: 'test-sip-password',
      host: 'ats01.kz.sipuni.com',
      internalExtension: '201',
    },
  };
};

const janusEvent = (event, extra = {}, callId = 'janus-call-1') =>
  pluginState.options?.onmessage?.({
    call_id: callId,
    result: { event, call_id: callId, ...extra },
  });

const sentRequests = request =>
  pluginSendMock.mock.calls.filter(
    ([payload]) => payload?.message?.request === request
  );

const offlinePresenceReports = () =>
  updatePresenceMock.mock.calls.filter(([registered]) => registered === false);

// The dot colour of the phone header and the sidebar button for this line,
// following PhoneWidget's sessionStatus for a line owned by this tab.
const lineColor = () => {
  const session = WebphoneClient.sessions[SESSION_KEY];
  let status = 'disconnected';
  if (session?.registered === true) {
    status = 'ready';
  } else if (
    session?.reason === 'sip_profile_registration_lease_owned_by_another_tab'
  ) {
    status = 'standby';
  } else if (
    session?.callingSupported === false ||
    /error|fail|timeout|auth|credential|password/i.test(session?.reason || '')
  ) {
    status = 'error';
  }
  return phoneWidgetStatusColor(status);
};

const callScope = {
  provider: 'sipuni',
  inboxId: 5248,
  sessionKey: SESSION_KEY,
  sipProfileId: 146,
};

const registerLine = async () => {
  const initialization = WebphoneClient.initializeDevice(5248, {
    native: true,
  });
  await vi.advanceTimersByTimeAsync(10);
  await initialization;
  expect(WebphoneClient.sessions[SESSION_KEY]?.registered).toBe(true);
};

const startOutboundCall = async () => {
  const join = WebphoneClient.joinClientCall({
    ...callScope,
    callRef: CALL_REF,
    callDirection: 'outbound',
    toNumber: '+77015550000',
  });
  await vi.advanceTimersByTimeAsync(0);
  expect(sentRequests('call')).toHaveLength(1);
  janusEvent('calling');
  janusEvent('ringing');
  await join;
};

describe('webphone line after a call ends', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    ticket = 0;
    WebphoneClient.sessions = {};
    WebphoneClient.providerSessions = {};
    WebphoneClient.nativeSipClients = {};
    WebphoneClient.nativeSipClientGenerations = {};
    WebphoneClient.nativeSessionConfigs = {};
    WebphoneClient.nativeSessionRetryTimers = {};
    WebphoneClient.nativeSessionRetryState = {};
    WebphoneClient.nativeSessionRetryPromises = {};
    WebphoneClient.deviceInitializationPromises = {};
    WebphoneClient.activeProvider = null;
    WebphoneClient.activeSessionKey = null;
    pluginSendMock.mockReset();
    pluginSendMock.mockImplementation(({ message } = {}) => {
      if (message?.request === 'register') {
        window.setTimeout(() => {
          pluginState.options?.onmessage?.({ result: { event: 'registered' } });
        }, 0);
      }
    });
    pluginHangupMock.mockClear();
    pluginDetachMock.mockClear();
    janusDestroyMock.mockClear();
    updatePresenceMock.mockClear();
    getNativeWebphoneTokenMock.mockReset();
    getNativeWebphoneTokenMock.mockImplementation(() =>
      Promise.resolve(tokenResponse())
    );
  });

  afterEach(async () => {
    await WebphoneClient.destroyDevice({ provider: 'sipuni' });
    vi.useRealTimers();
  });

  it('keeps the line registered and green when the operator hangs up a ringing outbound call', async () => {
    await registerLine();
    await startOutboundCall();
    const tokensBeforeHangup = getNativeWebphoneTokenMock.mock.calls.length;
    const unregistered = vi.fn();
    WebphoneClient.addEventListener('call:unregistered', unregistered);

    await WebphoneClient.endClientCall({ ...callScope, callRef: CALL_REF });
    expect(lineColor()).toBe('bg-n-teal-9');
    await vi.advanceTimersByTimeAsync(30_000);
    WebphoneClient.removeEventListener('call:unregistered', unregistered);

    expect(sentRequests('hangup')).toHaveLength(1);
    expect(unregistered).not.toHaveBeenCalled();
    expect(offlinePresenceReports()).toHaveLength(0);
    expect(janusDestroyMock).not.toHaveBeenCalled();
    expect(pluginDetachMock).not.toHaveBeenCalled();
    expect(WebphoneClient.sessions[SESSION_KEY].registered).toBe(true);
    expect(lineColor()).toBe('bg-n-teal-9');
    // No token storm: the registered line needs no fresh token after a call.
    expect(getNativeWebphoneTokenMock.mock.calls.length).toBe(
      tokensBeforeHangup
    );
  });

  it('keeps the line registered when the operator hangs up a connected outbound call', async () => {
    await registerLine();
    await startOutboundCall();
    janusEvent('accepted');
    const tokensBeforeHangup = getNativeWebphoneTokenMock.mock.calls.length;

    await WebphoneClient.endClientCall({ ...callScope, callRef: CALL_REF });
    await vi.advanceTimersByTimeAsync(30_000);

    expect(sentRequests('hangup')).toHaveLength(1);
    expect(offlinePresenceReports()).toHaveLength(0);
    expect(janusDestroyMock).not.toHaveBeenCalled();
    expect(WebphoneClient.sessions[SESSION_KEY].registered).toBe(true);
    expect(lineColor()).toBe('bg-n-teal-9');
    expect(getNativeWebphoneTokenMock.mock.calls.length).toBe(
      tokensBeforeHangup
    );
  });

  it('places the next call on the same registration after a hang-up', async () => {
    await registerLine();
    await startOutboundCall();
    await WebphoneClient.endClientCall({ ...callScope, callRef: CALL_REF });
    await vi.advanceTimersByTimeAsync(5_000);
    pluginSendMock.mockClear();

    const join = WebphoneClient.joinClientCall({
      ...callScope,
      callRef: 'sipuni:local:outbound-2',
      callDirection: 'outbound',
      toNumber: '+77015550001',
    });
    await vi.advanceTimersByTimeAsync(0);
    janusEvent('calling', {}, 'janus-call-2');
    await join;

    expect(sentRequests('register')).toHaveLength(0);
    expect(sentRequests('call')).toHaveLength(1);
    expect(WebphoneClient.sessions[SESSION_KEY].registered).toBe(true);
  });

  it('keeps the registration when the phone is shown again (a new token for the same line)', async () => {
    await registerLine();
    const unregistered = vi.fn();
    WebphoneClient.addEventListener('call:unregistered', unregistered);
    pluginSendMock.mockClear();

    // Showing the hidden phone mounts the call list again, which bootstraps
    // the line with a fresh token (new Janus ticket, same lease).
    const again = WebphoneClient.initializeDevice(5248, { native: true });
    await vi.advanceTimersByTimeAsync(10);
    await again;
    await vi.advanceTimersByTimeAsync(30_000);
    WebphoneClient.removeEventListener('call:unregistered', unregistered);

    expect(unregistered).not.toHaveBeenCalled();
    expect(sentRequests('register')).toHaveLength(0);
    expect(sentRequests('unregister')).toHaveLength(0);
    expect(offlinePresenceReports()).toHaveLength(0);
    expect(janusDestroyMock).not.toHaveBeenCalled();
    expect(lineColor()).toBe('bg-n-teal-9');
  });

  it('keeps the line registered when the callee hangs up', async () => {
    await registerLine();
    await startOutboundCall();
    janusEvent('accepted');

    janusEvent('hangup', { code: 200, reason: 'Session Terminated' });
    await vi.advanceTimersByTimeAsync(30_000);

    expect(offlinePresenceReports()).toHaveLength(0);
    expect(WebphoneClient.sessions[SESSION_KEY].registered).toBe(true);
    expect(lineColor()).toBe('bg-n-teal-9');
  });
});
