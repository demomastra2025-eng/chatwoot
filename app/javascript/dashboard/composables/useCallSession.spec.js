import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { createApp } from 'vue';

const {
  bootstrapIncomingSupportMock,
  endClientCallMock,
  initializeDeviceMock,
  joinClientCallMock,
  rejectBackendCallMock,
  rejectClientCallMock,
  supportsBrowserCallingMock,
} = vi.hoisted(() => ({
  bootstrapIncomingSupportMock: vi.fn(),
  endClientCallMock: vi.fn(),
  initializeDeviceMock: vi.fn(),
  joinClientCallMock: vi.fn(),
  rejectBackendCallMock: vi.fn(),
  rejectClientCallMock: vi.fn(),
  supportsBrowserCallingMock: vi.fn(),
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
    addEventListener: vi.fn(),
    bootstrapIncomingSupport: bootstrapIncomingSupportMock,
    endClientCall: endClientCallMock,
    initializeDevice: initializeDeviceMock,
    joinClientCall: joinClientCallMock,
    rejectIncomingCall: rejectClientCallMock,
    removeEventListener: vi.fn(),
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
        reason: 'operator_declined',
        status: 'rejected',
      }
    );
    expect(VoiceAPI.leaveConference).not.toHaveBeenCalled();
    expect(callsStore.calls).toEqual([]);
  });

  it('releases the backend call when claim succeeds but no SIP incoming call is available to answer', async () => {
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

    expect(result).toEqual({ provider: 'fonoster', joinSupported: false });
    expect(VoiceAPI.claimIncomingCall).toHaveBeenCalledWith(
      'call-no-sip-answer'
    );
    expect(rejectBackendCallMock).toHaveBeenCalledWith('call-no-sip-answer', {
      reason: 'browser_webphone_not_ready',
      status: 'no_answer',
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
});
