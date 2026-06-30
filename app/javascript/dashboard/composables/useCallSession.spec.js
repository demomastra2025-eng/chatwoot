import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { createApp } from 'vue';

const {
  addEventListenerMock,
  bootstrapIncomingSupportMock,
  endClientCallMock,
  initializeDeviceMock,
  joinClientCallMock,
  removeEventListenerMock,
  rejectBackendCallMock,
  rejectClientCallMock,
  routeMock,
  inboxGetterMock,
  selectedChatMock,
  conversationByIdGetterMock,
  supportsBrowserCallingMock,
} = vi.hoisted(() => ({
  addEventListenerMock: vi.fn(),
  bootstrapIncomingSupportMock: vi.fn(),
  endClientCallMock: vi.fn(),
  initializeDeviceMock: vi.fn(),
  joinClientCallMock: vi.fn(),
  removeEventListenerMock: vi.fn(),
  rejectBackendCallMock: vi.fn(),
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
  },
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    addEventListener: addEventListenerMock,
    bootstrapIncomingSupport: bootstrapIncomingSupportMock,
    endClientCall: endClientCallMock,
    initializeDevice: initializeDeviceMock,
    joinClientCall: joinClientCallMock,
    rejectIncomingCall: rejectClientCallMock,
    removeEventListener: removeEventListenerMock,
    supportsBrowserCalling: supportsBrowserCallingMock,
  },
}));

import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import { useCallsStore } from 'dashboard/stores/calls';
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
    bootstrapIncomingSupportMock.mockResolvedValue({ provider: 'fonoster' });
    initializeDeviceMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
    });
    joinClientCallMock.mockResolvedValue({
      provider: 'fonoster',
      answered: true,
    });
    rejectBackendCallMock.mockResolvedValue({ status: 'rejected' });
    rejectClientCallMock.mockResolvedValue({
      provider: 'fonoster',
      declined: true,
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
      .mockResolvedValueOnce({ provider: 'fonoster' });

    mountUseCallSession();
    await Promise.resolve();

    expect(bootstrapIncomingSupportMock).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(10_000);

    expect(bootstrapIncomingSupportMock).toHaveBeenCalledTimes(2);
    consoleErrorSpy.mockRestore();
  });

  it('bootstraps browser calling for the active voice inbox route', async () => {
    routeMock.params = { inbox_id: '4696' };
    inboxGetterMock.mockReturnValue({ id: 4696, provider: 'fonoster' });

    mountUseCallSession();
    await Promise.resolve();

    expect(initializeDeviceMock).toHaveBeenCalledWith(4696, { native: true });
    expect(bootstrapIncomingSupportMock).not.toHaveBeenCalled();
  });

  it('bootstraps browser calling for a Channel::Voice route inbox without provider metadata', async () => {
    routeMock.params = { inbox_id: '4704' };
    inboxGetterMock.mockReturnValue({
      id: 4704,
      channel_type: 'Channel::Voice',
    });

    mountUseCallSession();
    await Promise.resolve();

    expect(initializeDeviceMock).toHaveBeenCalledWith(4704);
    expect(bootstrapIncomingSupportMock).not.toHaveBeenCalled();
  });

  it('does not request an unscoped webphone token while route inbox metadata is loading', async () => {
    routeMock.params = { inbox_id: '4698' };
    inboxGetterMock.mockReturnValue(null);

    mountUseCallSession();
    await Promise.resolve();

    expect(initializeDeviceMock).not.toHaveBeenCalled();
    expect(bootstrapIncomingSupportMock).not.toHaveBeenCalled();
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

    expect(initializeDeviceMock).toHaveBeenCalledWith(4704);
    expect(bootstrapIncomingSupportMock).not.toHaveBeenCalled();
  });

  it('does not request an unscoped webphone token while a communication thread is loading', async () => {
    routeMock.params = { communication_thread_id: '1' };
    selectedChatMock.value = {};

    mountUseCallSession();
    await Promise.resolve();

    expect(initializeDeviceMock).not.toHaveBeenCalled();
    expect(bootstrapIncomingSupportMock).not.toHaveBeenCalled();
  });

  it('bootstraps browser calling for an incoming Fonoster call inbox before answer', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-cold-incoming-bootstrap',
      provider: 'fonoster',
      callDirection: 'inbound',
      inboxId: 4698,
    });

    mountUseCallSession();
    await Promise.resolve();

    expect(initializeDeviceMock).toHaveBeenCalledWith(4698, { native: true });
  });

  it('always asks the backend to reject Fonoster calls after the local SIP decline attempt', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-server-side-reject',
      provider: 'fonoster',
    });
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith('fonoster');
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-server-side-reject',
      {
        reason: 'operator_declined',
        status: 'rejected',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('still asks the backend to reject when the Fonoster SIP client has no pending call to decline', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-no-sip-decline',
      provider: 'fonoster',
    });
    rejectClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith('fonoster');
    expect(rejectBackendCallMock).toHaveBeenCalledWith('call-no-sip-decline', {
      reason: 'operator_declined',
      status: 'rejected',
    });
    expect(callsStore.calls).toEqual([]);
  });

  it('keeps a Fonoster call visible when backend release fails', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-release-failed',
      provider: 'fonoster',
    });
    rejectBackendCallMock.mockRejectedValue(new Error('backend unavailable'));
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith('fonoster');
    expect(rejectBackendCallMock).toHaveBeenCalledWith('call-release-failed', {
      reason: 'operator_declined',
      status: 'rejected',
    });
    expect(callsStore.calls).toMatchObject([
      { callSid: 'call-release-failed' },
    ]);
  });

  it('terminates active Fonoster calls through backend bridge release instead of local hangup only', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-active-bridge-release',
      provider: 'fonoster',
    });
    callsStore.setCallActive('call-active-bridge-release');
    const callSession = mountUseCallSession();

    await callSession.endCall({
      conversationId: 6,
      inboxId: 4083,
      provider: 'fonoster',
      callSid: 'call-active-bridge-release',
    });

    expect(endClientCallMock).toHaveBeenCalledWith('fonoster');
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

  it('releases the backend Fonoster call when the SIP client reports a remote disconnect', async () => {
    let disconnectHandler;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:disconnected') disconnectHandler = handler;
    });
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-remote-disconnect',
      provider: 'fonoster',
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

  it('clears the active Fonoster call immediately on remote disconnect while backend release is pending', async () => {
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
      provider: 'fonoster',
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

  it('removes a pending outbound Fonoster call when the SIP client disconnects by call ref', async () => {
    let disconnectHandler;
    addEventListenerMock.mockImplementation((eventName, handler) => {
      if (eventName === 'call:disconnected') disconnectHandler = handler;
    });
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-pending-outbound-disconnect',
      provider: 'fonoster',
      callDirection: 'outbound',
    });

    mountUseCallSession();
    await disconnectHandler?.({
      detail: {
        provider: 'fonoster',
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

  it('still releases an active Fonoster call when the local RTC hangup fails', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-local-hangup-failed',
      provider: 'fonoster',
    });
    callsStore.setCallActive('call-local-hangup-failed');
    endClientCallMock.mockRejectedValue(new Error('rtc hangup failed'));
    const callSession = mountUseCallSession();

    await callSession.endCall({
      conversationId: 6,
      inboxId: 4083,
      provider: 'fonoster',
      callSid: 'call-local-hangup-failed',
    });

    expect(endClientCallMock).toHaveBeenCalledWith('fonoster');
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-local-hangup-failed',
      {
        reason: 'operator_hangup',
        status: 'completed',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('ignores duplicate active Fonoster hangup clicks while release is in flight', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-double-hangup',
      provider: 'fonoster',
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
      provider: 'fonoster',
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

  it('does not block a different Fonoster call while another hangup release is in flight', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({ callSid: 'call-first-hangup', provider: 'fonoster' });
    callsStore.addCall({ callSid: 'call-second-hangup', provider: 'fonoster' });
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
      provider: 'fonoster',
      callSid: 'call-first-hangup',
    });
    const secondRelease = callSession.endCall({
      conversationId: 7,
      inboxId: 4083,
      provider: 'fonoster',
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

  it('ignores duplicate incoming Fonoster reject clicks while release is in flight', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-double-reject',
      provider: 'fonoster',
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

  it('still releases an incoming Fonoster call when local SIP decline throws', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-local-decline-failed',
      provider: 'fonoster',
    });
    rejectClientCallMock.mockRejectedValue(new Error('sip decline failed'));
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).toHaveBeenCalledWith('fonoster');
    expect(rejectBackendCallMock).toHaveBeenCalledWith(
      'call-local-decline-failed',
      {
        reason: 'operator_declined',
        status: 'rejected',
      }
    );
    expect(callsStore.calls).toEqual([]);
  });

  it('keeps an inbound Fonoster call alive when no SIP incoming call is available to answer yet', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-no-sip-answer',
      provider: 'fonoster',
      callDirection: 'inbound',
    });
    joinClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-no-sip-answer',
      provider: 'fonoster',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
      joinSupported: false,
      reason: 'sip_invite_not_received',
    });
    expect(VoiceAPI.claimIncomingCall).toHaveBeenCalledWith(
      'call-no-sip-answer'
    );
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toMatchObject([
      {
        callSid: 'call-no-sip-answer',
        browserJoinSupported: null,
      },
    ]);
  });

  it('releases the backend call when the browser SIP answer fails after claim', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-sip-answer-failed',
      provider: 'fonoster',
      callDirection: 'inbound',
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
      registered: true,
    });
    joinClientCallMock.mockRejectedValue(
      new Error('microphone permission denied')
    );
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-sip-answer-failed',
      provider: 'fonoster',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
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

  it('keeps a registered Fonoster call alive when the delayed SIP INVITE is not yet available', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-registered-waiting-for-invite',
      provider: 'fonoster',
      callDirection: 'inbound',
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
      registered: true,
    });
    joinClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      callSid: 'call-registered-waiting-for-invite',
      provider: 'fonoster',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
      joinSupported: false,
      reason: 'sip_invite_not_received',
    });
    expect(VoiceAPI.claimIncomingCall).toHaveBeenCalledWith(
      'call-registered-waiting-for-invite'
    );
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toMatchObject([
      {
        callSid: 'call-registered-waiting-for-invite',
        browserJoinSupported: null,
      },
    ]);
  });

  it('joins outbound Fonoster calls in the browser without claiming an incoming call first', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-browser-join',
      provider: 'fonoster',
      callDirection: 'outbound',
    });
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4083,
      callSid: 'call-outbound-browser-join',
      provider: 'fonoster',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
      joinSupported: true,
      waitingForAnswer: true,
    });
    expect(VoiceAPI.claimIncomingCall).not.toHaveBeenCalled();
    expect(joinClientCallMock).toHaveBeenCalledWith({
      provider: 'fonoster',
      conversationId: 6,
      callRef: 'call-outbound-browser-join',
      callDirection: 'outbound',
    });
    expect(callsStore.activeCall).toBeNull();
    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        browserJoined: true,
        callSid: 'call-outbound-browser-join',
        isActive: false,
      }),
    ]);
  });

  it('fails and dismisses outbound Fonoster calls when the operator SIP INVITE never arrives', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-no-sip-invite',
      provider: 'fonoster',
      callDirection: 'outbound',
    });
    joinClientCallMock.mockResolvedValue(null);
    const callSession = mountUseCallSession();

    const result = await callSession.joinCall({
      conversationId: 6,
      inboxId: 4083,
      callSid: 'call-outbound-no-sip-invite',
      provider: 'fonoster',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
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

  it('does not release an outbound Fonoster call again when it was already closed while waiting for SIP INVITE', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-closed-before-invite',
      provider: 'fonoster',
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
      provider: 'fonoster',
      callDirection: 'outbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
      joinSupported: false,
      reason: 'call_closed',
      callSid: 'call-outbound-closed-before-invite',
    });
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([]);
  });

  it('cancels pending outbound Fonoster calls without using incoming SIP decline', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-outbound-cancel',
      provider: 'fonoster',
      callDirection: 'outbound',
    });
    const callSession = mountUseCallSession();

    await callSession.rejectIncomingCall(callsStore.calls[0]);

    expect(rejectClientCallMock).not.toHaveBeenCalled();
    expect(endClientCallMock).toHaveBeenCalledWith('fonoster');
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
      provider: 'fonoster',
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
      provider: 'fonoster',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
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

  it('dismisses an inbound Fonoster call when backend claim says it is already terminal', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'call-terminal-before-claim',
      provider: 'fonoster',
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
      provider: 'fonoster',
      callDirection: 'inbound',
    });

    expect(result).toEqual({
      provider: 'fonoster',
      joinSupported: false,
      reason: 'CALL_NOT_CLAIMABLE',
    });
    expect(rejectClientCallMock).not.toHaveBeenCalled();
    expect(rejectBackendCallMock).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([]);
  });
});
