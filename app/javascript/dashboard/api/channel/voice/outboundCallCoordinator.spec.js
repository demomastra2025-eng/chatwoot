import { beforeEach, describe, expect, it, vi } from 'vitest';

const { joinClientCallMock, rejectIncomingCallMock } = vi.hoisted(() => ({
  joinClientCallMock: vi.fn(),
  rejectIncomingCallMock: vi.fn(),
}));

vi.mock('./webphoneClient', () => ({
  default: { joinClientCall: joinClientCallMock },
}));

vi.mock('./voiceAPIClient', () => ({
  default: { rejectIncomingCall: rejectIncomingCallMock },
}));

import {
  hasPendingOutboundCall,
  resetOutboundCallCoordinatorForTests,
  startOutboundBrowserCall,
} from './outboundCallCoordinator';

describe('outboundCallCoordinator', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resetOutboundCallCoordinatorForTests();
    rejectIncomingCallMock.mockResolvedValue({});
  });

  it('pins the call to the prepared Janus session and deduplicates the callSid', async () => {
    let resolveJoin;
    joinClientCallMock.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveJoin = resolve;
        })
    );
    const call = {
      callSid: 'call-1',
      provider: 'sipuni',
      inboxId: 42,
      toNumber: '+77010000000',
    };
    const first = startOutboundBrowserCall({
      call,
      sessionScope: { sessionKey: 'sip_profile:7', sipProfileId: 7 },
    });
    const duplicate = startOutboundBrowserCall({ call });

    expect(first).toBe(duplicate);
    expect(hasPendingOutboundCall()).toBe(true);
    expect(joinClientCallMock).toHaveBeenCalledTimes(1);
    expect(joinClientCallMock).toHaveBeenCalledWith({
      provider: 'sipuni',
      inboxId: 42,
      sessionKey: 'sip_profile:7',
      sipProfileId: 7,
      callDirection: 'outbound',
      callRef: 'call-1',
      toNumber: '+77010000000',
    });

    resolveJoin({ calling: true });
    await expect(first).resolves.toEqual({ calling: true });
    expect(hasPendingOutboundCall()).toBe(false);
  });

  it('serializes different outbound calls', async () => {
    joinClientCallMock.mockImplementation(() => new Promise(() => {}));
    startOutboundBrowserCall({ call: { callSid: 'call-1' } });

    await expect(
      startOutboundBrowserCall({ call: { callSid: 'call-2' } })
    ).rejects.toThrow('sip_outbound_call_in_progress');
    expect(joinClientCallMock).toHaveBeenCalledTimes(1);
  });

  it('persists the exact pre-SIP failure reason and runs failure cleanup', async () => {
    const error = Object.assign(new Error('sip_outbound_offer_timeout'), {
      reason: 'sip_outbound_offer_timeout',
      sipCallSent: false,
    });
    const onFailed = vi.fn();
    joinClientCallMock.mockRejectedValue(error);

    await expect(
      startOutboundBrowserCall({
        call: { callSid: 'call-1' },
        onFailed,
      })
    ).rejects.toMatchObject({ reason: 'sip_outbound_offer_timeout' });
    expect(rejectIncomingCallMock).toHaveBeenCalledWith('call-1', {
      status: 'failed',
      reason: 'sip_outbound_offer_timeout',
    });
    expect(onFailed).toHaveBeenCalledWith({
      error,
      reason: 'sip_outbound_offer_timeout',
    });
  });

  it('does not redial automatically after an ambiguous post-SIP failure', async () => {
    joinClientCallMock.mockRejectedValue(
      Object.assign(new Error('network_lost'), { sipCallSent: true })
    );

    await expect(
      startOutboundBrowserCall({ call: { callSid: 'call-1' } })
    ).rejects.toMatchObject({ reason: 'sip_outbound_start_failed' });
    expect(joinClientCallMock).toHaveBeenCalledTimes(1);
    expect(rejectIncomingCallMock).toHaveBeenCalledWith('call-1', {
      status: 'failed',
      reason: 'sip_outbound_start_failed',
    });
  });
});
