import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { createApp } from 'vue';

const {
  addEventListenerMock,
  answerAiIncomingCallMock,
  bootstrapIncomingSupportMock,
  destroyDeviceMock,
  endClientCallMock,
  hasPendingIncomingCallMock,
  initializeDeviceMock,
  joinClientCallMock,
  waitForPendingIncomingCallMock,
  removeEventListenerMock,
  rejectBackendCallMock,
  reportBrowserSipAnsweredMock,
  reportBrowserSipIncomingMock,
  rejectClientCallMock,
  routeMock,
  inboxGetterMock,
  selectedChatMock,
  conversationByIdGetterMock,
  supportsBrowserCallingMock,
} = vi.hoisted(() => ({
  addEventListenerMock: vi.fn(),
  answerAiIncomingCallMock: vi.fn(),
  bootstrapIncomingSupportMock: vi.fn(),
  destroyDeviceMock: vi.fn(),
  endClientCallMock: vi.fn(),
  hasPendingIncomingCallMock: vi.fn(),
  initializeDeviceMock: vi.fn(),
  joinClientCallMock: vi.fn(),
  waitForPendingIncomingCallMock: vi.fn(),
  removeEventListenerMock: vi.fn(),
  rejectBackendCallMock: vi.fn(),
  reportBrowserSipAnsweredMock: vi.fn(),
  reportBrowserSipIncomingMock: vi.fn(),
  rejectClientCallMock: vi.fn(),
  routeMock: { params: {} },
  inboxGetterMock: vi.fn(),
  selectedChatMock: { value: {} },
  conversationByIdGetterMock: vi.fn(),
  supportsBrowserCallingMock: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => routeMock,
}));

vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      'inboxes/getInbox': inboxGetterMock,
      get getSelectedChat() {
        return selectedChatMock.value;
      },
      getConversationById: conversationByIdGetterMock,
    },
  }),
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    claimIncomingCall: vi.fn().mockResolvedValue({ claimed: true }),
    joinConference: vi.fn(),
    leaveConference: vi.fn(),
    rejectIncomingCall: rejectBackendCallMock,
    reportBrowserSipAnswered: reportBrowserSipAnsweredMock,
    reportBrowserSipIncoming: reportBrowserSipIncomingMock,
  },
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    addEventListener: addEventListenerMock,
    answerAiIncomingCall: answerAiIncomingCallMock,
    bootstrapIncomingSupport: bootstrapIncomingSupportMock,
    destroyDevice: destroyDeviceMock,
    endClientCall: endClientCallMock,
    hasPendingIncomingCall: hasPendingIncomingCallMock,
    initializeDevice: initializeDeviceMock,
    joinClientCall: joinClientCallMock,
    waitForPendingIncomingCall: waitForPendingIncomingCallMock,
    rejectIncomingCall: rejectClientCallMock,
    removeEventListener: removeEventListenerMock,
    supportsBrowserCalling: supportsBrowserCallingMock,
  },
}));

import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import { useCallsStore } from 'dashboard/stores/calls';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { useCallSession } from './useCallSession';

let mountedApps = [];

const mountUseCallSession = () => {
  let composable;
  const app = createApp({
    setup() {
      composable = useCallSession();
      return () => null;
    },
  });
  const element = document.createElement('div');
  document.body.appendChild(element);
  app.mount(element);
  mountedApps.push({ app, element });
  return composable;
};

describe('useCallSession', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    routeMock.params = {};
    selectedChatMock.value = {};
    inboxGetterMock.mockReturnValue(null);
    conversationByIdGetterMock.mockReturnValue(null);
    bootstrapIncomingSupportMock.mockResolvedValue({ provider: 'sipuni' });
    reportBrowserSipAnsweredMock.mockResolvedValue({ answered: true });
    destroyDeviceMock.mockResolvedValue({ provider: 'sipuni' });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
    });
    joinClientCallMock.mockResolvedValue({
      provider: 'sipuni',
      answered: true,
    });
    waitForPendingIncomingCallMock.mockResolvedValue({
      callRef: 'raw-janus-call-id',
    });
    rejectBackendCallMock.mockResolvedValue({ status: 'rejected' });
    reportBrowserSipIncomingMock.mockResolvedValue({
      callSid: 'binotel:janus:call-1',
      status: 'ringing',
      provider: 'binotel',
      inbox_id: 4770,
      call_direction: 'inbound',
      from_number: '+77475318623',
      operator_candidates: [{ sip_profile_id: 40, user_id: 179 }],
      operator_internal_extension: '901',
      sip_profile_id: 40,
      janus_call_ref: 'raw-janus-call-id',
      janus_session_key: 'sip_profile:40',
    });
    rejectClientCallMock.mockResolvedValue({
      provider: 'sipuni',
      declined: true,
    });
    hasPendingIncomingCallMock.mockReturnValue(false);
    answerAiIncomingCallMock.mockResolvedValue({
      provider: 'sipuni',
      answered: true,
    });
    supportsBrowserCallingMock.mockReturnValue(true);
    VoiceAPI.claimIncomingCall.mockResolvedValue({ claimed: true });
  });

  afterEach(() => {
    mountedApps.forEach(({ app, element }) => {
      app.unmount();
      element.remove();
    });
    mountedApps = [];
    vi.useRealTimers();
  });

  it('retries browser calling bootstrap after a transient failure', async () => {
    vi.useFakeTimers();
    const consoleErrorSpy = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});
    bootstrapIncomingSupportMock
      .mockRejectedValueOnce(new Error('bridge unavailable'))
      .mockResolvedValueOnce({ provider: 'sipuni' });

    mountUseCallSession();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock).toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(10_000);

    expect(bootstrapIncomingSupportMock).toHaveBeenCalledTimes(2);
    consoleErrorSpy.mockRestore();
  });

  it('bootstraps browser calling for the active voice inbox route', async () => {
    routeMock.params = { inbox_id: '4696' };
    inboxGetterMock.mockReturnValue({ id: 4696, provider: 'sipuni' });

    mountUseCallSession();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock).toHaveBeenCalledTimes(1);
    expect(initializeDeviceMock).toHaveBeenCalledWith(4696, { native: true });
  });

  it('periodically refreshes browser calling bootstrap for open dashboards', async () => {
    vi.useFakeTimers();
    mountUseCallSession();
    await Promise.resolve();

    const initialBootstrapCalls =
      bootstrapIncomingSupportMock.mock.calls.length;

    await vi.advanceTimersByTimeAsync(300_000);
    await Promise.resolve();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock.mock.calls.length).toBeGreaterThan(
      initialBootstrapCalls
    );
  });

  it('refreshes browser SIP registration from realtime config events when idle', async () => {
    inboxGetterMock.mockReturnValue({ id: 4776, provider: 'sipuni' });
    mountUseCallSession();
    await Promise.resolve();
    const initialDestroyCalls = destroyDeviceMock.mock.calls.length;

    emitter.emit(BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED, {
      account_id: 530,
      provider: 'sipuni',
      inbox_id: 4776,
      sip_profile_ids: [48],
    });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(destroyDeviceMock.mock.calls.length).toBeGreaterThan(
      initialDestroyCalls
    );
    expect(destroyDeviceMock.mock.calls.at(-1)?.[0]).toEqual(
      expect.objectContaining({
        provider: 'sipuni',
        inboxId: 4776,
        sipProfileId: null,
        sessionKey: null,
      })
    );
    expect(initializeDeviceMock).toHaveBeenCalledWith(4776, { native: true });
  });

  it('replays an identical config event received during an in-flight refresh', async () => {
    let resolveFirstRefresh;
    const firstRefresh = new Promise(resolve => {
      resolveFirstRefresh = resolve;
    });
    inboxGetterMock.mockReturnValue({ id: 4776, provider: 'sipuni' });
    mountUseCallSession();
    await Promise.resolve();
    bootstrapIncomingSupportMock.mockImplementationOnce(() => firstRefresh);
    const initialDestroyCalls = destroyDeviceMock.mock.calls.length;
    const configEvent = {
      account_id: 530,
      provider: 'sipuni',
      inbox_id: 4776,
      sip_profile_ids: [48],
    };

    emitter.emit(BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED, configEvent);
    await Promise.resolve();
    await Promise.resolve();
    emitter.emit(BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED, configEvent);
    resolveFirstRefresh({ provider: 'sipuni' });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(destroyDeviceMock.mock.calls.length).toBe(initialDestroyCalls + 2);
  });

  it('defers browser SIP refresh while a call is active and applies it after the call ends', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni:operator-call',
      provider: 'sipuni',
      inboxId: 4776,
      status: 'ringing',
      callDirection: 'inbound',
    });
    callsStore.setCallActive('sipuni:operator-call');
    inboxGetterMock.mockReturnValue({ id: 4776, provider: 'sipuni' });

    mountUseCallSession();
    await Promise.resolve();
    const initialDestroyCalls = destroyDeviceMock.mock.calls.length;

    emitter.emit(BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED, {
      account_id: 530,
      provider: 'sipuni',
      inbox_id: 4776,
      sip_profile_ids: [48],
    });
    await Promise.resolve();
    await Promise.resolve();

    expect(destroyDeviceMock.mock.calls.length).toBe(initialDestroyCalls);
    expect(bootstrapIncomingSupportMock.mock.calls.length).toBeGreaterThan(0);

    callsStore.dismissCall('sipuni:operator-call');
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(destroyDeviceMock.mock.calls.length).toBeGreaterThan(
      initialDestroyCalls
    );
    expect(destroyDeviceMock.mock.calls.at(-1)?.[0]).toEqual(
      expect.objectContaining({
        provider: 'sipuni',
        inboxId: 4776,
        sipProfileId: null,
        sessionKey: null,
      })
    );
    expect(initializeDeviceMock).toHaveBeenCalledWith(4776, { native: true });
  });

  it('bootstraps browser calling for a Channel::Voice route inbox without provider metadata', async () => {
    routeMock.params = { inbox_id: '4704' };
    inboxGetterMock.mockReturnValue({
      id: 4704,
      channel_type: 'Channel::Voice',
    });

    mountUseCallSession();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock).toHaveBeenCalledTimes(1);
    expect(initializeDeviceMock).toHaveBeenCalledWith(4704);
  });

  it('bootstraps a route inbox with the native token endpoint while inbox metadata is loading', async () => {
    routeMock.params = { inbox_id: '4698' };
    inboxGetterMock.mockReturnValue(null);

    mountUseCallSession();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock).toHaveBeenCalled();
    expect(initializeDeviceMock).toHaveBeenCalledWith(4698, { native: true });
  });

  it('bootstraps browser calling for an active communication thread voice channel', async () => {
    routeMock.params = { communication_thread_id: '1' };
    selectedChatMock.value = {
      id: 1,
      is_communication_thread: true,
      channels: [
        {
          channel: 'Channel::Voice',
          inbox_id: 4704,
        },
      ],
    };

    mountUseCallSession();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock).toHaveBeenCalledTimes(1);
    expect(initializeDeviceMock).toHaveBeenCalledWith(4704);
  });

  it('reports native Binotel Janus incoming calls so the backend creates a call session', async () => {
    mountUseCallSession();
    await Promise.resolve();

    const incomingHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:incoming'
    )?.[1];
    await incomingHandler({
      detail: {
        provider: 'binotel',
        inboxId: 4770,
        sipProfileId: 40,
        registrationInstanceId: 'registration-40',
        registrationConfigVersion: 'version-40',
        sessionKey: 'sip_profile:40',
        janusSessionId: 'janus-session-40',
        janusHandleId: 'janus-handle-40',
        internalExtension: '901',
        callRef: 'raw-janus-call-id',
        from: 'sip:+77475318623@sip53.binotel.com',
      },
    });

    expect(reportBrowserSipIncomingMock).toHaveBeenCalledWith({
      provider: 'binotel',
      inbox_id: 4770,
      call_ref: 'raw-janus-call-id',
      from: 'sip:+77475318623@sip53.binotel.com',
      session_key: 'sip_profile:40',
      sip_profile_id: 40,
      registration_instance_id: 'registration-40',
      registration_config_version: 'version-40',
      janus_session_id: 'janus-session-40',
      janus_handle_id: 'janus-handle-40',
      internal_extension: '901',
    });
    expect(useCallsStore().calls).toEqual([
      expect.objectContaining({
        callSid: 'binotel:janus:call-1',
        provider: 'binotel',
        inboxId: 4770,
        callDirection: 'inbound',
        fromNumber: '+77475318623',
        operatorInternalExtension: '901',
        sipProfileId: 40,
      }),
    ]);
  });

  it('reports native Sipuni Janus incoming calls when no webhook call is tracked', async () => {
    reportBrowserSipIncomingMock.mockResolvedValueOnce({
      callSid: 'sipuni:janus:42:raw-sipuni-call-id',
      status: 'ringing',
      provider: 'sipuni',
      inbox_id: 4772,
      call_direction: 'inbound',
      from_number: '+77017450000',
      operator_candidates: [{ sip_profile_id: 42, user_id: 179 }],
      operator_internal_extension: '207',
      sip_profile_id: 42,
    });
    mountUseCallSession();
    await Promise.resolve();

    const incomingHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:incoming'
    )?.[1];
    await incomingHandler({
      detail: {
        provider: 'sipuni',
        inboxId: 4772,
        sipProfileId: 42,
        sessionKey: 'sip_profile:42',
        internalExtension: '207',
        callRef: 'raw-sipuni-call-id',
        from: 'sip:+77017450000@ats01.kz.sipuni.com',
      },
    });

    expect(reportBrowserSipIncomingMock).toHaveBeenCalledWith({
      provider: 'sipuni',
      inbox_id: 4772,
      call_ref: 'raw-sipuni-call-id',
      from: 'sip:+77017450000@ats01.kz.sipuni.com',
      session_key: 'sip_profile:42',
      sip_profile_id: 42,
      internal_extension: '207',
    });
    expect(useCallsStore().calls).toEqual([
      expect.objectContaining({
        callSid: 'sipuni:janus:42:raw-sipuni-call-id',
        provider: 'sipuni',
        inboxId: 4772,
        callDirection: 'inbound',
        fromNumber: '+77017450000',
        operatorInternalExtension: '207',
        sipProfileId: 42,
      }),
    ]);
  });

  it('destroys a stale browser SIP device when incoming reporting is rejected', async () => {
    const consoleWarnSpy = vi
      .spyOn(console, 'warn')
      .mockImplementation(() => {});
    reportBrowserSipIncomingMock.mockRejectedValueOnce({
      response: { status: 404 },
    });
    mountUseCallSession();
    await Promise.resolve();

    const incomingHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:incoming'
    )?.[1];
    await incomingHandler({
      detail: {
        provider: 'sipuni',
        inboxId: 4772,
        sipProfileId: 42,
        sessionKey: 'sip_profile:42',
        internalExtension: '207',
        callRef: 'stale-sipuni-call-id',
        from: 'sip:+77017450000@ats01.kz.sipuni.com',
      },
    });

    expect(destroyDeviceMock).toHaveBeenCalledWith({
      provider: 'sipuni',
      inboxId: 4772,
      sessionKey: 'sip_profile:42',
      sipProfileId: 42,
    });
    expect(useCallsStore().calls).toEqual([]);
    consoleWarnSpy.mockRestore();
  });

  it('answers Sipuni Janus AI-routed incoming calls without showing operator UI', async () => {
    reportBrowserSipIncomingMock.mockResolvedValueOnce({
      callSid: 'sipuni:janus:42:raw-sipuni-ai-call-id',
      provider: 'sipuni',
      inbox_id: 4772,
      route_action: 'ai',
      janus_call_ref: 'raw-sipuni-ai-call-id',
      janus_session_key: 'sip_profile:42',
      sip_profile_id: 42,
      ai_voice: {
        browser_bridge: {
          stream_url: 'ws://127.0.0.1:8082/v1/voice/sessions/1/stream',
        },
      },
    });
    mountUseCallSession();
    await Promise.resolve();

    const incomingHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:incoming'
    )?.[1];
    await incomingHandler({
      detail: {
        provider: 'sipuni',
        inboxId: 4772,
        sipProfileId: 42,
        sessionKey: 'sip_profile:42',
        internalExtension: '207',
        callRef: 'raw-sipuni-ai-call-id',
        from: 'sip:+77017450000@ats01.kz.sipuni.com',
      },
    });

    expect(answerAiIncomingCallMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider: 'sipuni',
        inboxId: 4772,
        sessionKey: 'sip_profile:42',
        sipProfileId: 42,
        callRef: 'sipuni:janus:42:raw-sipuni-ai-call-id',
        janusCallRef: 'raw-sipuni-ai-call-id',
        streamUrl: 'ws://127.0.0.1:8082/v1/voice/sessions/1/stream',
      })
    );
    expect(useCallsStore().calls).toEqual([]);
  });

  it('ignores AI bridge connected and disconnected events for operator call state', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni:operator-call',
      provider: 'sipuni',
      status: 'ringing',
      callDirection: 'inbound',
    });
    mountUseCallSession();
    await Promise.resolve();

    const connectedHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:connected'
    )?.[1];
    const disconnectedHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:disconnected'
    )?.[1];

    connectedHandler({
      detail: {
        provider: 'sipuni',
        callRef: 'sipuni:janus:42:ai-call',
        aiBridge: true,
      },
    });
    await disconnectedHandler({
      detail: {
        provider: 'sipuni',
        callRef: 'sipuni:janus:42:ai-call',
        aiBridge: true,
        callMediaAccepted: true,
      },
    });

    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callSid: 'sipuni:operator-call',
        isActive: false,
      }),
    ]);
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
  });

  it('ignores AI mode Janus events even when the legacy aiBridge flag is missing', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni:operator-call',
      provider: 'sipuni',
      status: 'ringing',
      callDirection: 'inbound',
    });
    mountUseCallSession();
    await Promise.resolve();

    const connectedHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:connected'
    )?.[1];
    const disconnectedHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:disconnected'
    )?.[1];

    connectedHandler({
      detail: {
        provider: 'sipuni',
        callRef: 'sipuni:janus:42:ai-call',
        callMode: 'ai',
      },
    });
    await disconnectedHandler({
      detail: {
        provider: 'sipuni',
        callRef: 'sipuni:janus:42:ai-call',
        callMode: 'ai',
        callMediaAccepted: true,
      },
    });

    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callSid: 'sipuni:operator-call',
        isActive: false,
      }),
    ]);
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
  });

  it('correlates Sipuni Janus incoming calls with tracked webhook calls through the backend', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni:1782931413.293602',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 4772,
      status: 'ringing',
    });
    reportBrowserSipIncomingMock.mockResolvedValueOnce({
      callSid: 'sipuni:1782931413.293602',
      status: 'ringing',
      provider: 'sipuni',
      inbox_id: 4772,
      call_direction: 'inbound',
      from_number: '+77017450000',
      operator_internal_extension: '207',
      sip_profile_id: 42,
    });
    mountUseCallSession();
    await Promise.resolve();

    const incomingHandler = addEventListenerMock.mock.calls.find(
      ([eventName]) => eventName === 'call:incoming'
    )?.[1];
    await incomingHandler({
      detail: {
        provider: 'sipuni',
        inboxId: 4772,
        sipProfileId: 42,
        sessionKey: 'sip_profile:42',
        internalExtension: '207',
        callRef: 'raw-sipuni-call-id',
        from: 'sip:+77017450000@ats01.kz.sipuni.com',
      },
    });

    expect(reportBrowserSipIncomingMock).toHaveBeenCalledWith({
      provider: 'sipuni',
      inbox_id: 4772,
      call_ref: 'raw-sipuni-call-id',
      from: 'sip:+77017450000@ats01.kz.sipuni.com',
      session_key: 'sip_profile:42',
      sip_profile_id: 42,
      internal_extension: '207',
    });
    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callSid: 'sipuni:1782931413.293602',
        provider: 'sipuni',
        inboxId: 4772,
        fromNumber: '+77017450000',
        operatorInternalExtension: '207',
        sipProfileId: 42,
      }),
    ]);
  });

  it('bootstraps unscoped browser calling while a communication thread is loading', async () => {
    routeMock.params = { communication_thread_id: '1' };
    selectedChatMock.value = {};

    mountUseCallSession();
    await Promise.resolve();

    expect(initializeDeviceMock).not.toHaveBeenCalled();
    expect(bootstrapIncomingSupportMock).toHaveBeenCalledTimes(1);
  });

  it('bootstraps browser calling for an incoming browser SIP call inbox before answer', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-cold-incoming-bootstrap',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 4698,
    });

    mountUseCallSession();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock).toHaveBeenCalled();
    expect(initializeDeviceMock).toHaveBeenCalledWith(4698, { native: true });
  });

  it('always asks the backend to reject browser SIP calls after the local SIP decline attempt', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-server-side-reject',
      provider: 'sipuni',
    });
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni' })
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-server-side-reject',
      {
        reason: 'operator_declined',
        status: 'rejected',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('does not release AI-routed Janus calls as operator declined calls', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni:janus:42:ai-call',
      provider: 'sipuni',
      callDirection: 'inbound',
      route_action: 'ai',
      ai_voice: {
        state: 'attached',
      },
    });
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([]);
  });

  it('still asks the backend to reject when the browser SIP client has no pending call to decline', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-no-sip-decline',
      provider: 'sipuni',
    });
    rejectClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni' })
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith('call-no-sip-decline', {
      reason: 'operator_declined',
      status: 'rejected',
    });
    expect(callsStore.calls).toEqual([]);
  });

  it('keeps a browser SIP call visible when backend release fails', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-release-failed',
      provider: 'sipuni',
    });
    rejectBackendCallMock.mockRejectedValue(new Error('backend unavailable'));
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni' })
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith('call-release-failed', {
      reason: 'operator_declined',
      status: 'rejected',
    });
    expect(callsStore.calls).toMatchObject([
      { callSid: 'call-release-failed' },
    ]);
  });

  it('terminates active browser SIP calls through backend bridge release instead of local hangup only', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-active-bridge-release',
      provider: 'sipuni',
    });
    callsStore.setCallActive('call-active-bridge-release');
    const callSession = mountUseCallSession();

    await callSession.endCall({
      conversationId: 6,
      inboxId: 4083,
      provider: 'sipuni',
      callSid: 'call-active-bridge-release',
    });

    expect(endClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni', inboxId: 4083 })
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-active-bridge-release',
      {
        reason: 'operator_hangup',
        status: 'completed',
      }
    );
    expect(rejectBackendCallMock.mock.invocationCallOrder[0]).toBeLessThan(
      endClientCallMock.mock.invocationCallOrder[0]
    );
    expect(VoiceAPI.leaveConference).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([]);
  });

  it('releases the backend browser SIP call when the SIP client reports a remote disconnect', async () => {
    let disconnectHandler;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:disconnected') disconnectHandler = handler;
    });
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-remote-disconnect',
      provider: 'sipuni',
    });
    callsStore.setCallActive('call-remote-disconnect');

    mountUseCallSession();
    await disconnectHandler?.();

    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-remote-disconnect',
      {
        reason: 'remote_hangup',
        status: 'completed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('clears the active browser SIP call immediately on remote disconnect while backend release is pending', async () => {
    let disconnectHandler;
    let resolveRelease;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:disconnected') disconnectHandler = handler;
    });
    rejectBackendCallMock.mockReturnValue(
      new Promise(resolve => {
        resolveRelease = resolve;
      })
    );
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-remote-disconnect-pending',
      provider: 'sipuni',
    });
    callsStore.setCallActive('call-remote-disconnect-pending');

    mountUseCallSession();
    const releasePromise = disconnectHandler?.();
    await Promise.resolve();

    expect(callsStore.calls).toEqual([]);
    resolveRelease({ status: 'completed' });
    await releasePromise;
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-remote-disconnect-pending',
      {
        reason: 'remote_hangup',
        status: 'completed',
      }
    );
  });

  it('removes a pending outbound browser SIP call when the SIP client disconnects by call ref', async () => {
    let disconnectHandler;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:disconnected') disconnectHandler = handler;
    });
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-pending-outbound-disconnect',
      provider: 'sipuni',
      callDirection: 'outbound',
    });

    mountUseCallSession();
    await disconnectHandler?.({
      detail: {
        provider: 'sipuni',
        callRef: 'call-pending-outbound-disconnect',
        callDirection: 'outbound',
      },
    });

    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-pending-outbound-disconnect',
      {
        reason: 'sip_outbound_disconnected',
        status: 'failed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('completes an accepted outbound Asterisk call when Janus disconnects by call ref', async () => {
    let disconnectHandler;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:disconnected') disconnectHandler = handler;
    });
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'asterisk_analog:local:accepted-outbound',
      provider: 'asterisk_analog',
      callDirection: 'outbound',
      answeredAt: '2026-07-15T10:10:28.655Z',
    });

    mountUseCallSession();
    await disconnectHandler?.({
      detail: {
        provider: 'asterisk_analog',
        callRef: 'asterisk_analog:local:accepted-outbound',
        callDirection: 'outbound',
        callMediaAccepted: true,
        reason: 'remote_hangup',
      },
    });

    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'asterisk_analog:local:accepted-outbound',
      {
        reason: 'remote_hangup',
        status: 'completed',
      }
    );
    expect(reportBrowserSipAnsweredMock).toHaveBeenCalledWith(
      'asterisk_analog:local:accepted-outbound',
      { answered_at: '2026-07-15T10:10:28.655Z' }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('marks an outbound Asterisk call active when Janus reports it connected', async () => {
    let connectedHandler;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:connected') connectedHandler = handler;
    });
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'asterisk_analog:local:connected-outbound',
      provider: 'asterisk_analog',
      callDirection: 'outbound',
    });

    mountUseCallSession();
    connectedHandler?.({
      detail: {
        provider: 'asterisk_analog',
        callRef: 'asterisk_analog:local:connected-outbound',
        callDirection: 'outbound',
        callMediaAccepted: true,
      },
    });

    expect(callsStore.activeCall?.callSid).toBe(
      'asterisk_analog:local:connected-outbound'
    );
    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callSid: 'asterisk_analog:local:connected-outbound',
        isActive: true,
      }),
    ]);
  });

  it('maps Janus outbound stages to the existing customer-leg UI model', async () => {
    let stageHandler;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:stage') stageHandler = handler;
    });
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni:local:staged-outbound',
      provider: 'sipuni',
      callDirection: 'outbound',
      browserStartState: 'preparing',
    });

    mountUseCallSession();
    stageHandler?.({
      detail: {
        provider: 'sipuni',
        callRef: 'sipuni:local:staged-outbound',
        stage: 'progress',
      },
    });

    expect(callsStore.calls[0]).toEqual(
      expect.objectContaining({
        browserStartState: 'ringing',
        callEvent: 'callee_ringing',
        callLeg: 'callee',
        rawStatus: 'ringing',
      })
    );

    stageHandler?.({
      detail: {
        provider: 'sipuni',
        callRef: 'sipuni:local:staged-outbound',
        stage: 'accepted',
      },
    });

    expect(callsStore.activeCall).toEqual(
      expect.objectContaining({
        callSid: 'sipuni:local:staged-outbound',
        status: 'in_progress',
        browserStartState: 'connected',
        callEvent: 'callee_answered',
        callLeg: 'callee',
        rawStatus: 'answered',
        answeredAt: expect.any(String),
        isActive: true,
      })
    );
    expect(reportBrowserSipAnsweredMock).toHaveBeenCalledWith(
      'sipuni:local:staged-outbound',
      { answered_at: expect.any(String) }
    );
  });

  it('still releases an active browser SIP call when the local RTC hangup fails', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-local-hangup-failed',
      provider: 'sipuni',
    });
    callsStore.setCallActive('call-local-hangup-failed');
    endClientCallMock.mockRejectedValue(new Error('rtc hangup failed'));
    const callSession = mountUseCallSession();

    await callSession.endCall({
      conversationId: 6,
      inboxId: 4083,
      provider: 'sipuni',
      callSid: 'call-local-hangup-failed',
    });

    expect(endClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni', inboxId: 4083 })
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-local-hangup-failed',
      {
        reason: 'operator_hangup',
        status: 'completed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('ignores duplicate active browser SIP hangup clicks while release is in flight', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-double-hangup',
      provider: 'sipuni',
    });
    callsStore.setCallActive('call-double-hangup');
    let resolveRelease;
    rejectBackendCallMock.mockReturnValue(
      new Promise(resolve => {
        resolveRelease = resolve;
      })
    );
    const callSession = mountUseCallSession();
    const payload = {
      conversationId: 6,
      inboxId: 4083,
      provider: 'sipuni',
      callSid: 'call-double-hangup',
    };

    const firstRelease = callSession.endCall(payload);
    const secondRelease = callSession.endCall(payload);
    await Promise.resolve();

    expect(rejectBackendCallMock).toHaveBeenCalledTimes(1);
    expect(endClientCallMock).not.toHaveBeenCalled();
    resolveRelease({ status: 'completed' });
    await Promise.all([firstRelease, secondRelease]);
    expect(endClientCallMock).toHaveBeenCalledTimes(1);
    expect(callsStore.calls).toEqual([]);
  });

  it('does not block a different browser SIP call while another hangup release is in flight', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({ callSid: 'call-first-hangup', provider: 'sipuni' });
    callsStore.addCall({ callSid: 'call-second-hangup', provider: 'sipuni' });
    const releaseResolvers = {};
    rejectBackendCallMock.mockImplementation(
      callSid =>
        new Promise(resolve => {
          releaseResolvers[callSid] = resolve;
        })
    );
    const callSession = mountUseCallSession();

    const firstRelease = callSession.endCall({
      conversationId: 6,
      inboxId: 4083,
      provider: 'sipuni',
      callSid: 'call-first-hangup',
    });
    const secondRelease = callSession.endCall({
      conversationId: 7,
      inboxId: 4083,
      provider: 'sipuni',
      callSid: 'call-second-hangup',
    });
    await Promise.resolve();

    expect(rejectBackendCallMock).toHaveBeenCalledTimes(2);
    expect(endClientCallMock).not.toHaveBeenCalled();
    releaseResolvers['call-first-hangup']({ status: 'completed' });
    releaseResolvers['call-second-hangup']({ status: 'completed' });
    await Promise.all([firstRelease, secondRelease]);
    expect(endClientCallMock).toHaveBeenCalledTimes(2);
    expect(callsStore.calls).toEqual([]);
  });

  it('ignores duplicate incoming browser SIP reject clicks while release is in flight', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-double-reject',
      provider: 'sipuni',
    });
    let resolveRelease;
    rejectBackendCallMock.mockReturnValue(
      new Promise(resolve => {
        resolveRelease = resolve;
      })
    );
    const callSession = mountUseCallSession();

    const firstRelease = callSession.rejectIncomingCall(callsStore.calls[0]);
    const secondRelease = callSession.rejectIncomingCall(callsStore.calls[0]);
    await secondRelease;

    expect(rejectClientCallMock).toHaveBeenCalledTimes(1);
    expect(rejectBackendCallMock).toHaveBeenCalledTimes(1);
    resolveRelease({ status: 'rejected' });
    await firstRelease;
    expect(callsStore.calls).toEqual([]);
  });

  it('still releases an incoming browser SIP call when local SIP decline throws', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-local-decline-failed',
      provider: 'sipuni',
    });
    rejectClientCallMock.mockRejectedValue(new Error('sip decline failed'));
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni' })
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-local-decline-failed',
      {
        reason: 'operator_declined',
        status: 'rejected',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('releases a claimed inbound browser SIP call when no SIP incoming call is available to answer', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-no-sip-answer',
      provider: 'sipuni',
      callDirection: 'inbound',
    });
    joinClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-no-sip-answer',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'sip_invite_not_received',
    });
    expect(VoiceAPI.claimIncomingCall).toHaveBeenCalledWith(
      'call-no-sip-answer'
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith('call-no-sip-answer', {
      reason: 'sip_invite_not_received',
      status: 'no_answer',
    });
    expect(callsStore.calls).toEqual([]);
  });

  it('stores the communication thread returned by an incoming call claim', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-claim-thread',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 724,
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
    });
    VoiceAPI.claimIncomingCall.mockResolvedValue({
      claimed: true,
      status: 'in_progress',
      communication_thread_id: 25,
    });
    joinClientCallMock.mockResolvedValue({
      provider: 'sipuni',
      answered: true,
    });
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 724,
      inboxId: 4769,
      callSid: 'call-claim-thread',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(callsStore.calls).toMatchObject([
      {
        callSid: 'call-claim-thread',
        status: 'connecting',
        communicationThreadId: 25,
        isActive: true,
      },
    ]);
    expect(result).toMatchObject({
      provider: 'sipuni',
      joinSupported: true,
      communicationThreadId: 25,
    });
  });

  it('does not claim a Sipuni communication thread call when the Janus INVITE is not available', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-claim-thread-waiting-for-invite',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 724,
      communicationThreadId: 25,
      sipProfileId: 42,
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
      sipProfileId: 42,
    });
    waitForPendingIncomingCallMock.mockResolvedValueOnce(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 724,
      inboxId: 4769,
      callSid: 'call-claim-thread-waiting-for-invite',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'sip_invite_not_received',
      communicationThreadId: 25,
    });
    expect(waitForPendingIncomingCallMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider: 'sipuni',
        inboxId: 4769,
        sipProfileId: 42,
      }),
      { timeoutMs: 2500 }
    );
    expect(VoiceAPI.claimIncomingCall).not.toHaveBeenCalled();
    expect(joinClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callSid: 'call-claim-thread-waiting-for-invite',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'sip_invite_not_received',
      }),
    ]);
  });

  it('keeps a Sipuni call visible when Janus preflight fails before claim', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-release-missing-invite-failed',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 724,
      sipProfileId: 42,
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
      sipProfileId: 42,
    });
    waitForPendingIncomingCallMock.mockResolvedValueOnce(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 724,
      inboxId: 4769,
      callSid: 'call-release-missing-invite-failed',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'sip_invite_not_received',
    });
    expect(VoiceAPI.claimIncomingCall).not.toHaveBeenCalled();
    expect(joinClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callSid: 'call-release-missing-invite-failed',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'sip_invite_not_received',
      }),
    ]);
  });

  it('releases the backend call when the browser SIP answer fails after claim', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-sip-answer-failed',
      provider: 'sipuni',
      callDirection: 'inbound',
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
    });
    joinClientCallMock.mockRejectedValue(
      new Error('microphone permission denied')
    );
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-sip-answer-failed',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'browser_webphone_not_ready',
    });
    expect(VoiceAPI.claimIncomingCall).toHaveBeenCalledWith(
      'call-sip-answer-failed'
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-sip-answer-failed',
      {
        reason: 'browser_webphone_not_ready',
        status: 'no_answer',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('releases a registered browser SIP call when the delayed SIP INVITE never arrives', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-registered-waiting-for-invite',
      provider: 'sipuni',
      callDirection: 'inbound',
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
    });
    joinClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-registered-waiting-for-invite',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'sip_invite_not_received',
    });
    expect(VoiceAPI.claimIncomingCall).toHaveBeenCalledWith(
      'call-registered-waiting-for-invite'
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-registered-waiting-for-invite',
      {
        reason: 'sip_invite_not_received',
        status: 'no_answer',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('joins outbound browser SIP calls in the browser without claiming an incoming call first', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-browser-join',
      provider: 'sipuni',
      callDirection: 'outbound',
    });
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4083,
      callSid: 'call-outbound-browser-join',
      provider: 'sipuni',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: true,
      waitingForAnswer: true,
    });
    expect(VoiceAPI.claimIncomingCall).not.toHaveBeenCalled();
    expect(joinClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider: 'sipuni',
        inboxId: 4083,
        conversationId: 6,
        callRef: 'call-outbound-browser-join',
        callDirection: 'outbound',
      })
    );
    expect(callsStore.activeCall).toBeNull();
    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        browserJoined: true,
        callSid: 'call-outbound-browser-join',
        isActive: false,
      }),
    ]);
  });

  it('fails and dismisses outbound browser SIP calls when the operator SIP INVITE never arrives', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-no-sip-invite',
      provider: 'sipuni',
      callDirection: 'outbound',
    });
    joinClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4083,
      callSid: 'call-outbound-no-sip-invite',
      provider: 'sipuni',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'sip_invite_not_received',
      callSid: 'call-outbound-no-sip-invite',
    });
    expect(VoiceAPI.claimIncomingCall).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-outbound-no-sip-invite',
      {
        reason: 'sip_invite_not_received',
        status: 'failed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('releases outbound non-browser SIP calls when Janus does not start the call', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni-outbound-no-invite',
      provider: 'sipuni',
      callDirection: 'outbound',
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
    });
    joinClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4769,
      callSid: 'sipuni-outbound-no-invite',
      provider: 'sipuni',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'sip_invite_not_received',
      callSid: 'sipuni-outbound-no-invite',
    });
    expect(VoiceAPI.claimIncomingCall).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'sipuni-outbound-no-invite',
      {
        reason: 'sip_invite_not_received',
        status: 'failed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('releases outbound Binotel calls when Janus registration fails before SIP INVITE', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'binotel-outbound-registration-timeout',
      provider: 'binotel',
      callDirection: 'outbound',
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'binotel',
      callingSupported: true,
      registered: false,
    });
    joinClientCallMock.mockRejectedValue(new Error('sip_registration_timeout'));
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4770,
      callSid: 'binotel-outbound-registration-timeout',
      provider: 'binotel',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'binotel',
      joinSupported: false,
      reason: 'sip_invite_not_received',
      callSid: 'binotel-outbound-registration-timeout',
    });
    expect(VoiceAPI.claimIncomingCall).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'binotel-outbound-registration-timeout',
      {
        reason: 'sip_invite_not_received',
        status: 'failed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('releases outbound Binotel calls when browser SIP initialization fails before SIP INVITE', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'binotel-outbound-initialize-timeout',
      provider: 'binotel',
      callDirection: 'outbound',
    });
    initializeDeviceMock.mockRejectedValue(
      new Error('sip_registration_timeout')
    );
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4770,
      callSid: 'binotel-outbound-initialize-timeout',
      provider: 'binotel',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'binotel',
      joinSupported: false,
      reason: 'sip_invite_not_received',
      callSid: 'binotel-outbound-initialize-timeout',
    });
    expect(joinClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'binotel-outbound-initialize-timeout',
      {
        reason: 'sip_invite_not_received',
        status: 'failed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('does not release an outbound browser SIP call again when it was already closed while waiting for SIP INVITE', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-closed-before-invite',
      provider: 'sipuni',
      callDirection: 'outbound',
    });
    joinClientCallMock.mockImplementation(async () => {
      callsStore.dismissCall('call-outbound-closed-before-invite');
      return null;
    });
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4083,
      callSid: 'call-outbound-closed-before-invite',
      provider: 'sipuni',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'call_closed',
      callSid: 'call-outbound-closed-before-invite',
    });
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([]);
  });

  it('cancels pending outbound browser SIP calls without using incoming SIP decline', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-cancel',
      provider: 'sipuni',
      callDirection: 'outbound',
    });
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).not.toHaveBeenCalled();
    expect(endClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni' })
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith('call-outbound-cancel', {
      reason: 'operator_cancelled',
      status: 'cancelled',
    });
    expect(callsStore.calls).toEqual([]);
  });

  it('keeps the call visible as browser-unsupported when backend claim says the operator is not registered', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-operator-not-registered',
      provider: 'sipuni',
      callDirection: 'inbound',
    });
    VoiceAPI.claimIncomingCall.mockRejectedValue({
      response: {
        data: {
          code: 'OPERATOR_NOT_CANDIDATE',
          details: { reason: 'operator_not_registered' },
        },
      },
    });
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-operator-not-registered',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'operator_not_registered',
    });
    expect(rejectClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toMatchObject([
      {
        callSid: 'call-operator-not-registered',
        browserJoinSupported: false,
      },
    ]);
  });

  it('keeps a Sipuni incoming call retryable when claim is attempted before the operator leg is ready', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'sipuni-pre-operator-call',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 4769,
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
    });
    VoiceAPI.claimIncomingCall.mockRejectedValue({
      response: {
        status: 403,
        data: {
          code: 'OPERATOR_NOT_CANDIDATE',
          details: { reason: 'sipuni_operator_leg_not_ready' },
        },
      },
    });
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'sipuni-pre-operator-call',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 4769,
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      retryable: true,
      reason: 'sipuni_operator_leg_not_ready',
    });
    expect(joinClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toMatchObject([
      {
        callSid: 'sipuni-pre-operator-call',
        browserJoinSupported: null,
      },
    ]);
  });

  it('dismisses an inbound browser SIP call when backend claim says it is already terminal', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-terminal-before-claim',
      provider: 'sipuni',
      callDirection: 'inbound',
    });
    VoiceAPI.claimIncomingCall.mockRejectedValue({
      response: {
        status: 409,
        data: {
          code: 'CALL_NOT_CLAIMABLE',
          details: { status: 'rejected' },
        },
      },
    });
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-terminal-before-claim',
      provider: 'sipuni',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'sipuni',
      joinSupported: false,
      reason: 'CALL_NOT_CLAIMABLE',
    });
    expect(rejectClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([]);
  });
});
