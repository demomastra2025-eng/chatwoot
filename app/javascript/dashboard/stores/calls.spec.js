import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const {
  endClientCallMock,
  hasPendingIncomingCallMock,
  rejectIncomingCallMock,
} = vi.hoisted(() => ({
  endClientCallMock: vi.fn(),
  hasPendingIncomingCallMock: vi.fn(),
  rejectIncomingCallMock: vi.fn(),
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    endClientCall: endClientCallMock,
    hasPendingIncomingCall: hasPendingIncomingCallMock,
    rejectIncomingCall: rejectIncomingCallMock,
  },
}));

import { useCallsStore } from './calls';

describe('useCallsStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    endClientCallMock.mockReset();
    hasPendingIncomingCallMock.mockReset();
    hasPendingIncomingCallMock.mockReturnValue(false);
    rejectIncomingCallMock.mockReset();
  });

  it('enriches an existing call instead of discarding later details', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'call-123',
      callDirection: 'inbound',
      conversationId: 8,
    });
    store.addCall({
      callSid: 'call-123',
      inboxId: 44,
      provider: 'sipuni',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        browserJoinSupported: null,
        callDirection: 'inbound',
        callSid: 'call-123',
        conversationId: 8,
        inboxId: 44,
        isActive: false,
        provider: 'sipuni',
      }),
    ]);
  });

  it('preserves active state and browser support when enriching a call', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'call-789',
      callDirection: 'outbound',
      conversationId: 21,
    });
    store.setCallActive('call-789');
    store.markBrowserJoinUnsupported('call-789', 'sipuni');

    store.addCall({
      callSid: 'call-789',
      inboxId: 99,
    });

    expect(store.calls[0]).toEqual(
      expect.objectContaining({
        browserJoinSupported: false,
        inboxId: 99,
        isActive: true,
        provider: 'sipuni',
      })
    );
  });

  it('stores the outside-browser operator claim details for display', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'claimed-call-1',
      callDirection: 'inbound',
      provider: 'sipuni',
    });
    store.markBrowserJoinUnsupported('claimed-call-1', 'sipuni', {
      reason: 'CALL_ALREADY_CLAIMED',
      operatorClaim: { user_id: 7, user_name: 'Ayan' },
    });

    expect(store.calls[0]).toEqual(
      expect.objectContaining({
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
        operatorClaim: { user_id: 7, user_name: 'Ayan' },
      })
    );
  });

  it('marks a browser-joined outbound call without making it active', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'call-browser-joined',
      callDirection: 'outbound',
      provider: 'sipuni',
    });
    store.markBrowserJoined('call-browser-joined', 'sipuni');

    expect(store.calls).toEqual([
      expect.objectContaining({
        browserJoined: true,
        callSid: 'call-browser-joined',
        isActive: false,
        provider: 'sipuni',
      }),
    ]);
    expect(store.activeCall).toBeNull();
  });

  it('replaces a stale Janus SIP call for the same conversation instead of stacking widgets', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'old-call-ref',
      provider: 'sipuni',
      conversationId: 612,
      callDirection: 'outbound',
    });
    store.setCallActive('old-call-ref');

    store.addCall({
      callSid: 'new-call-ref',
      provider: 'sipuni',
      conversationId: 612,
      callDirection: 'outbound',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'new-call-ref',
        conversationId: 612,
        isActive: false,
        provider: 'sipuni',
      }),
    ]);
    await vi.waitFor(() => {
      expect(endClientCallMock).toHaveBeenCalledWith(
        expect.objectContaining({
          callSid: 'old-call-ref',
          provider: 'sipuni',
        })
      );
    });
  });

  it('deduplicates Janus SIP inbound branches by logical call key without replacing the actionable call ref', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'sipuni-inbound:shared-key',
      fromNumber: '+77070001002',
      toNumber: '+77070001001',
    });

    store.addCall({
      callSid: 'operator-501-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'sipuni-inbound:shared-key',
      fromNumber: '+77070001002',
      toNumber: '+77070001001',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        logicalCallKey: 'sipuni-inbound:shared-key',
        provider: 'sipuni',
      }),
    ]);
  });

  it('keeps same-session native SIP calls separate when their logical keys differ', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'stale-operator-branch',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      sipProfileId: 83,
      janusSessionKey: 'sip_profile:83',
      logicalCallKey: 'janus-inbound:stale-key',
      fromNumber: 'sip:+77072817060@91.215.136.2:8217',
      toNumber: '+77017450000',
    });
    store.addCall({
      callSid: 'current-operator-branch',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      sipProfileId: 83,
      janusSessionKey: 'sip_profile:83',
      logicalCallKey: 'janus-inbound:canonical-key',
      fromNumber: '+7 (707) 281-70-60',
      toNumber: '8 701 745 00 00',
    });

    expect(store.calls.map(call => call.callSid)).toEqual([
      'stale-operator-branch',
      'current-operator-branch',
    ]);
  });

  it('keeps simultaneous sparse native SIP calls with different logical keys', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'sparse-call-one',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:sparse-one',
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
    });
    store.addCall({
      callSid: 'sparse-call-two',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:sparse-two',
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
    });

    expect(store.calls.map(call => call.callSid)).toEqual([
      'sparse-call-one',
      'sparse-call-two',
    ]);
  });

  it('keeps an unkeyed sparse call separate from a keyed call in a reused conversation', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'keyed-sparse-call',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 28745,
      logicalCallKey: 'sipuni-inbound:keyed-call',
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
    });
    store.addCall({
      callSid: 'unkeyed-sparse-call',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 28745,
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
    });

    expect(store.calls.map(call => call.callSid)).toEqual([
      'keyed-sparse-call',
      'unkeyed-sparse-call',
    ]);
  });

  it('keeps an uncorrelated providerless message event separate from the local Janus branch', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'janus-local-206',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      sipProfileId: 80,
      janusSessionKey: 'sip_profile:80',
      logicalCallKey: 'janus-inbound:canonical',
      fromNumber: 'sip:+15555551002@example.test',
      toNumber: '+15555551001',
      browserJoinSupported: true,
    });
    store.addCall({
      callSid: 'message-event-without-provider',
      accountId: 43,
      callDirection: 'inbound',
      inboxId: 194,
      conversationId: 28744,
      fromNumber: '+1 (555) 555-1002',
      toNumber: '+1 (555) 555-1001',
      status: 'ringing',
    });

    expect(store.calls).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          callSid: 'janus-local-206',
          provider: 'sipuni',
          sipProfileId: 80,
          janusSessionKey: 'sip_profile:80',
          browserJoinSupported: true,
        }),
        expect.objectContaining({
          callSid: 'message-event-without-provider',
          conversationId: 28744,
        }),
      ])
    );
    expect(store.calls).toHaveLength(2);
  });

  it('removes a providerless stale modal when the answered logical call terminates', async () => {
    const store = useCallsStore();
    store.calls.push({
      callSid: 'providerless-ghost',
      accountId: 43,
      callDirection: 'inbound',
      inboxId: 194,
      conversationId: 28744,
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
      isActive: false,
    });

    store.handleCallStatusChanged({
      callSid: 'answered-branch-206',
      status: 'completed',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      conversationId: 28744,
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
      logicalCallTerminal: true,
    });

    await vi.waitFor(() => expect(store.calls).toEqual([]));
  });

  it('keeps an active providerless call during unkeyed terminal fallback cleanup', async () => {
    const store = useCallsStore();
    store.calls.push({
      callSid: 'active-providerless-call',
      accountId: 43,
      callDirection: 'inbound',
      inboxId: 194,
      conversationId: 28746,
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
      isActive: true,
    });

    store.handleCallStatusChanged({
      callSid: 'other-unkeyed-call',
      status: 'completed',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      conversationId: 28746,
      fromNumber: '+770****7060',
      toNumber: '+770****0000',
      logicalCallTerminal: true,
    });

    await vi.waitFor(() =>
      expect(store.calls).toEqual([
        expect.objectContaining({
          callSid: 'active-providerless-call',
          isActive: true,
        }),
      ])
    );
  });

  it('keeps simultaneous native SIP calls from different clients separate', () => {
    const store = useCallsStore();
    const sharedScope = {
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      sipProfileId: 83,
      janusSessionKey: 'sip_profile:83',
      toNumber: '+77017450000',
    };

    store.addCall({
      ...sharedScope,
      callSid: 'first-client-call',
      logicalCallKey: 'janus-inbound:first-client',
      fromNumber: '+77072817060',
    });
    store.addCall({
      ...sharedScope,
      callSid: 'second-client-call',
      logicalCallKey: 'janus-inbound:second-client',
      fromNumber: '+77070000001',
    });

    expect(store.calls.map(call => call.callSid)).toEqual([
      'first-client-call',
      'second-client-call',
    ]);
  });

  it('keeps a distinct simultaneous logical call for the same client after another call terminates', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'same-client-first-call',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      logicalCallKey: 'janus-inbound:same-client-first',
      fromNumber: '+77072817060',
      toNumber: '+77017450000',
    });

    store.handleCallStatusChanged({
      callSid: 'same-client-second-call',
      status: 'completed',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      logicalCallKey: 'janus-inbound:same-client-second',
      fromNumber: '+77072817060',
      toNumber: '+77017450000',
      logicalCallTerminal: true,
    });

    await vi.waitFor(() => {
      expect(store.calls).toEqual([
        expect.objectContaining({
          callSid: 'same-client-first-call',
          logicalCallKey: 'janus-inbound:same-client-first',
        }),
      ]);
    });
  });

  it('removes a deduped Janus SIP inbound card when a sibling branch terminates', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:shared-key',
    });
    store.addCall({
      callSid: 'operator-501-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:shared-key',
    });

    store.handleCallStatusChanged({
      callSid: 'operator-501-ref',
      status: 'completed',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:shared-key',
    });

    expect(store.calls).toEqual([]);
  });

  it('removes every non-active scoped branch when the canonical native SIP call terminates', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'root-202',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 158,
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
      logicalCallKey: 'sipuni-inbound:canonical',
    });
    store.addCall({
      callSid: 'branch-204',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 158,
      sipProfileId: 82,
      janusSessionKey: 'sip_profile:82',
      logicalCallKey: 'sipuni-inbound:canonical',
    });

    store.handleCallStatusChanged({
      callSid: 'branch-204',
      status: 'no_answer',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 158,
      sipProfileId: 82,
      janusSessionKey: 'sip_profile:82',
      logicalCallKey: 'sipuni-inbound:canonical',
    });

    expect(store.calls).toEqual([]);
  });

  it('suppresses a late scoped branch after a canonical terminal event', () => {
    const store = useCallsStore();

    store.handleCallStatusChanged({
      callSid: 'root-202',
      status: 'completed',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 158,
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
      logicalCallKey: 'sipuni-inbound:canonical',
    });
    store.addCall({
      callSid: 'late-branch-206',
      status: 'ringing',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 158,
      sipProfileId: 80,
      janusSessionKey: 'sip_profile:80',
      logicalCallKey: 'sipuni-inbound:canonical',
    });

    expect(store.calls).toEqual([]);
  });

  it('keeps an active Janus SIP inbound card when a sibling branch terminates', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:shared-key',
    });
    store.setCallActive('operator-505-ref');

    store.handleCallStatusChanged({
      callSid: 'operator-501-ref',
      status: 'completed',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:shared-key',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        isActive: true,
        logicalCallKey: 'sipuni-inbound:shared-key',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('clears an active stale card when the whole logical call is terminal', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'canonical-fast-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 158,
      sipProfileId: 80,
      janusSessionKey: 'sip_profile:80',
      logicalCallKey: 'sipuni-inbound:fully-missed',
    });
    store.setCallActive('canonical-fast-ref', 'sipuni', {
      inboxId: 158,
      sipProfileId: 80,
      janusSessionKey: 'sip_profile:80',
    });

    store.handleCallStatusChanged({
      callSid: 'physical-206-ref',
      status: 'no_answer',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 158,
      sipProfileId: 80,
      janusSessionKey: 'sip_profile:80',
      logicalCallKey: 'sipuni-inbound:fully-missed',
      logicalCallTerminal: true,
    });

    await vi.waitFor(() => {
      expect(store.calls).toEqual([]);
      expect(endClientCallMock).toHaveBeenCalledWith(
        expect.objectContaining({ callSid: 'canonical-fast-ref' })
      );
    });
  });

  it('keeps separate Janus SIP inbound calls when logical call keys differ', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'first-real-call',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'sipuni-inbound:first',
    });
    store.addCall({
      callSid: 'second-real-call',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'sipuni-inbound:second',
    });

    expect(store.calls).toHaveLength(2);
    expect(store.calls.map(call => call.callSid)).toEqual([
      'first-real-call',
      'second-real-call',
    ]);
  });

  it('keeps different inbound call refs separate without logical keys even in the same conversation', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'first-call-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
    });
    store.addCall({
      callSid: 'second-call-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
    });
    store.setCallActive('first-call-ref');

    expect(store.calls.map(call => call.callSid)).toEqual([
      'first-call-ref',
      'second-call-ref',
    ]);
    expect(store.incomingCalls).toEqual([
      expect.objectContaining({ callSid: 'second-call-ref' }),
    ]);
  });

  it('clears sibling Janus SIP inbound branches when one branch becomes active', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:shared-key',
    });
    store.addCall({
      callSid: 'other-call',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:other-key',
    });
    store.calls.push({
      callSid: 'late-sibling-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:shared-key',
      isActive: false,
    });

    store.setCallActive('operator-505-ref');

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        isActive: true,
      }),
      expect.objectContaining({
        callSid: 'other-call',
        isActive: false,
      }),
    ]);
  });

  it('keeps Janus SIP inbound calls separate in the same conversation when logical keys differ', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:first-leg',
    });
    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:second-leg',
    });

    store.setCallActive('operator-504-ref');

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-504-ref',
        isActive: true,
      }),
      expect.objectContaining({
        callSid: 'operator-505-ref',
        isActive: false,
      }),
    ]);
    expect(store.incomingCalls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        logicalCallKey: 'sipuni-inbound:second-leg',
      }),
    ]);
  });

  it('declines a pending native SIP leg when another operator claims it', async () => {
    const store = useCallsStore();
    hasPendingIncomingCallMock.mockReturnValue(true);

    store.addCall({
      callSid: 'provider-call-pending-loser',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'shared-pending-call',
      janusCallRef: 'janus-pending-call',
      janusSessionKey: 'sip_profile:52',
    });

    await store.handleCallClaimed(
      {
        call_sid: 'provider-call-pending-loser',
        provider: 'sipuni',
        logical_call_key: 'shared-pending-call',
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([]);
    expect(hasPendingIncomingCallMock).toHaveBeenCalledWith(
      expect.objectContaining({
        sessionKey: 'sip_profile:52',
        janusCallRef: 'janus-pending-call',
      })
    );
    expect(rejectIncomingCallMock).toHaveBeenCalledWith(
      expect.objectContaining({ sessionKey: 'sip_profile:52' })
    );
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('dismisses a related Janus SIP inbound widget when another operator claims the call', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:shared-key',
    });

    await store.handleCallClaimed(
      {
        call_sid: 'operator-505-ref',
        provider: 'sipuni',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'sipuni-inbound:shared-key',
        related_call_sids: ['operator-504-ref', 'operator-505-ref'],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('preserves a partial-scope same-SID call outside an exact foreign claim', async () => {
    const store = useCallsStore();

    store.calls.push(
      {
        callSid: 'shared-claim-sid',
        provider: 'sipuni',
        callDirection: 'inbound',
        inboxId: 42,
        logicalCallKey: 'sipuni-inbound:claimed-call',
      },
      {
        callSid: 'shared-claim-sid',
        provider: 'sipuni',
        callDirection: 'inbound',
        inboxId: null,
        logicalCallKey: 'sipuni-inbound:unrelated-call',
        status: 'ringing',
      }
    );

    await store.handleCallClaimed(
      {
        call_sid: 'shared-claim-sid',
        provider: 'sipuni',
        call_direction: 'inbound',
        inbox_id: 42,
        logical_call_key: 'sipuni-inbound:claimed-call',
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'shared-claim-sid',
        inboxId: null,
        logicalCallKey: 'sipuni-inbound:unrelated-call',
      }),
    ]);

    store.handleCallStatusChanged({
      callSid: 'shared-claim-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:unrelated-call',
      status: 'connecting',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'shared-claim-sid',
        logicalCallKey: 'sipuni-inbound:unrelated-call',
        status: 'connecting',
      }),
    ]);
  });

  it('keeps a partial-scope same-SID call separate from a scoped observer card', async () => {
    const store = useCallsStore();

    store.calls.push(
      {
        callSid: 'shared-observer-sid',
        provider: 'sipuni',
        callDirection: 'inbound',
        inboxId: 42,
        logicalCallKey: 'sipuni-inbound:observed-call',
      },
      {
        callSid: 'shared-observer-sid',
        provider: 'sipuni',
        callDirection: 'inbound',
        inboxId: null,
        logicalCallKey: 'sipuni-inbound:unrelated-observer-call',
        status: 'ringing',
      }
    );

    await store.handleCallClaimed(
      {
        call_sid: 'shared-observer-sid',
        provider: 'sipuni',
        call_direction: 'inbound',
        inbox_id: 42,
        logical_call_key: 'sipuni-inbound:observed-call',
        claimed_by_user_id: 9,
        show_calls_handled_by_other_operators: true,
      },
      7
    );

    expect(store.calls).toHaveLength(2);
    expect(
      store.calls.find(
        call => call.logicalCallKey === 'sipuni-inbound:unrelated-observer-call'
      )
    ).toEqual(
      expect.objectContaining({
        inboxId: null,
        status: 'ringing',
      })
    );
    expect(
      store.calls.find(
        call => call.logicalCallKey === 'sipuni-inbound:observed-call'
      )
    ).toEqual(
      expect.objectContaining({
        inboxId: 42,
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
      })
    );
  });

  it('ends the browser client only when a claimed Janus SIP call was active in this browser', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:shared-key',
    });
    store.setCallActive('operator-504-ref');

    await store.handleCallClaimed(
      {
        call_sid: 'operator-505-ref',
        provider: 'sipuni',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'sipuni-inbound:shared-key',
        related_call_sids: ['operator-504-ref', 'operator-505-ref'],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([]);
    expect(endClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({
        callSid: 'operator-504-ref',
        provider: 'sipuni',
      })
    );
  });

  it('removes every stale modal for the same client after another operator claims the call', async () => {
    const store = useCallsStore();
    const sharedCall = {
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      sipProfileId: 83,
      janusSessionKey: 'sip_profile:83',
      fromNumber: '+77072817060',
      toNumber: '+77017450000',
      isActive: false,
    };
    store.calls.push(
      {
        ...sharedCall,
        callSid: 'stale-modal-a',
        logicalCallKey: 'janus-inbound:stale-a',
      },
      {
        ...sharedCall,
        callSid: 'stale-modal-b',
        logicalCallKey: 'janus-inbound:stale-b',
      }
    );

    await store.handleCallClaimed(
      {
        account_id: 43,
        call_sid: 'stale-modal-b',
        provider: 'sipuni',
        call_direction: 'inbound',
        inbox_id: 194,
        logical_call_key: 'janus-inbound:canonical',
        related_call_sids: ['stale-modal-a', 'stale-modal-b'],
        from_number: '+77072817060',
        to_number: '+77017450000',
        claimed_by_user_id: 1,
      },
      113
    );

    expect(store.calls).toEqual([]);
  }, 10000);

  it('keeps a distinct simultaneous logical call for the same client after a foreign claim', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'same-client-unclaimed-call',
      accountId: 43,
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 194,
      logicalCallKey: 'janus-inbound:same-client-unclaimed',
      fromNumber: '+77072817060',
      toNumber: '+77017450000',
    });

    await store.handleCallClaimed(
      {
        account_id: 43,
        call_sid: 'same-client-claimed-call',
        provider: 'sipuni',
        call_direction: 'inbound',
        inbox_id: 194,
        logical_call_key: 'janus-inbound:same-client-claimed',
        from_number: '+77072817060',
        to_number: '+77017450000',
        claimed_by_user_id: 1,
      },
      113
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'same-client-unclaimed-call',
        logicalCallKey: 'janus-inbound:same-client-unclaimed',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('ends an active Sipuni browser client when another operator claims the call', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'sipuni:operator-504-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      communicationThreadId: 72,
      logicalCallKey: 'sipuni-inbound:shared-key',
    });
    store.setCallActive('sipuni:operator-504-ref');

    await store.handleCallClaimed(
      {
        call_sid: 'sipuni:operator-505-ref',
        provider: 'sipuni',
        call_direction: 'inbound',
        conversation_id: 612,
        communication_thread_id: 72,
        logical_call_key: 'sipuni-inbound:shared-key',
        related_call_sids: [
          'sipuni:operator-504-ref',
          'sipuni:operator-505-ref',
        ],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([]);
    expect(endClientCallMock).toHaveBeenCalledWith(
      expect.objectContaining({
        callSid: 'sipuni:operator-504-ref',
        communicationThreadId: 72,
        provider: 'sipuni',
      })
    );
  });

  it('does not match an unrelated call when a communication thread id equals another conversation id', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'sipuni:unrelated-call',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 72,
    });

    await store.handleCallClaimed(
      {
        call_sid: 'sipuni:claimed-call',
        provider: 'sipuni',
        call_direction: 'inbound',
        conversation_id: 612,
        communication_thread_id: 72,
        related_call_sids: ['sipuni:claimed-call'],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'sipuni:unrelated-call',
        conversationId: 72,
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('does not remove a different Janus SIP inbound call with another logical key in the same conversation', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:first-call',
    });

    await store.handleCallClaimed(
      {
        call_sid: 'operator-505-ref',
        provider: 'sipuni',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'sipuni-inbound:second-call',
        related_call_sids: ['operator-505-ref'],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-504-ref',
        logicalCallKey: 'sipuni-inbound:first-call',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('keeps the current operator active call when the claim event belongs to them', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'sipuni-inbound:shared-key',
    });
    store.setCallActive('operator-504-ref');

    await store.handleCallClaimed(
      {
        call_sid: 'operator-504-ref',
        provider: 'sipuni',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'sipuni-inbound:shared-key',
        related_call_sids: ['operator-504-ref', 'operator-505-ref'],
        claimed_by_user_id: 7,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-504-ref',
        isActive: true,
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('keeps the current operator connecting call when claim arrives before media is active', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'binotel:sibling-906-ref',
      accountId: 66,
      inboxId: 190,
      provider: 'binotel',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'binotel-inbound:target-call',
      sipProfileId: 69,
      janusSessionKey: 'sip_profile:69',
      browserJoinSupported: true,
      status: 'ringing',
      isActive: false,
    });
    store.addCall({
      callSid: 'binotel:target-907-ref',
      accountId: 66,
      inboxId: 190,
      provider: 'binotel',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'binotel-inbound:target-call',
      sipProfileId: 70,
      janusSessionKey: 'sip_profile:70',
      browserJoinSupported: true,
      status: 'ringing',
      isActive: false,
    });

    await store.handleCallClaimed(
      {
        account_id: 66,
        inbox_id: 190,
        call_sid: 'binotel:target-907-ref',
        provider: 'binotel',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'binotel-inbound:target-call',
        sip_profile_id: 70,
        janus_session_key: 'sip_profile:70',
        related_call_sids: ['binotel:target-907-ref'],
        status: 'connecting',
        claimed_by_user_id: 7,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'binotel:target-907-ref',
        status: 'connecting',
        isActive: false,
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('merges a status from another SIP branch into the active owner call', () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'operator-202-ref',
      accountId: 1,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:shared-owner-call',
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
      browserJoinSupported: true,
      status: 'ringing',
    });
    store.setCallActive('operator-202-ref', 'sipuni', {
      inboxId: 4769,
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
    });

    store.handleCallStatusChanged({
      callSid: 'operator-207-ref',
      accountId: 1,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:shared-owner-call',
      sipProfileId: 81,
      janusSessionKey: 'sip_profile:81',
      status: 'in_progress',
      currentUserId: 113,
      operatorClaim: {
        user_id: 113,
        user_name: 'Жанат',
        sip_profile_id: 79,
        internal_extension: '202',
      },
      operatorInternalExtension: '202',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-202-ref',
        isActive: true,
        status: 'in_progress',
        sipProfileId: 79,
        janusSessionKey: 'sip_profile:79',
        operatorInternalExtension: '202',
        operatorClaim: expect.objectContaining({
          user_id: 113,
          internal_extension: '202',
        }),
      }),
    ]);
  });

  it('shows one informational card to other operators when the channel setting is enabled', () => {
    const store = useCallsStore();
    [79, 81].forEach(profileId => {
      store.addCall({
        callSid: `operator-branch-${profileId}`,
        accountId: 1,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        logicalCallKey: 'sipuni-inbound:observer-call',
        sipProfileId: profileId,
        janusSessionKey: `sip_profile:${profileId}`,
        browserJoinSupported: true,
        status: 'ringing',
      });
    });

    store.handleCallStatusChanged({
      callSid: 'operator-branch-81',
      accountId: 1,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni-inbound:observer-call',
      sipProfileId: 81,
      janusSessionKey: 'sip_profile:81',
      status: 'in_progress',
      currentUserId: 7,
      operatorClaim: {
        user_id: 113,
        user_name: 'Жанат',
        sip_profile_id: 79,
        internal_extension: '202',
      },
      operatorInternalExtension: '202',
      showCallsHandledByOtherOperators: true,
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-branch-81',
        status: 'in_progress',
        isActive: false,
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
        operatorInternalExtension: '202',
      }),
    ]);
  });

  it('replaces every local branch with one observer card on a foreign claim', async () => {
    const store = useCallsStore();
    [79, 81].forEach(profileId => {
      store.addCall({
        callSid: `claim-branch-${profileId}`,
        accountId: 1,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        logicalCallKey: 'sipuni-inbound:observer-claim',
        sipProfileId: profileId,
        janusSessionKey: `sip_profile:${profileId}`,
        browserJoinSupported: true,
        status: 'ringing',
      });
    });

    await store.handleCallClaimed(
      {
        call_sid: 'claim-branch-79',
        account_id: 1,
        inbox_id: 4769,
        provider: 'sipuni',
        call_direction: 'inbound',
        logical_call_key: 'sipuni-inbound:observer-claim',
        sip_profile_id: 79,
        janus_session_key: 'sip_profile:79',
        related_call_sids: ['claim-branch-79', 'claim-branch-81'],
        claimed_by_user_id: 113,
        operator_claim: {
          user_id: 113,
          user_name: 'Жанат',
          sip_profile_id: 79,
          internal_extension: '202',
        },
        show_calls_handled_by_other_operators: true,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'claim-branch-79',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
        operatorInternalExtension: '202',
      }),
    ]);
  }, 10000);

  it('keeps an active branch when a same-SID sibling ends before the logical call', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'shared-native-sid-79',
      accountId: 1,
      inboxId: 194,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'janus-inbound:same-sid-terminal',
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
      status: 'in_progress',
      isActive: true,
      operatorClaim: {
        user_id: 5,
        user_name: 'Owner 79',
        internal_extension: '202',
      },
    });
    store.setCallActive('shared-native-sid-79', 'sipuni', {
      accountId: 1,
      inboxId: 194,
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
    });

    await store.handleCallStatusChanged({
      callSid: 'shared-native-sid-79',
      accountId: 1,
      inboxId: 194,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'janus-inbound:same-sid-terminal',
      sipProfileId: 81,
      janusSessionKey: 'sip_profile:81',
      status: 'completed',
      logicalCallTerminal: false,
    });

    expect(store.calls).toHaveLength(1);
    expect(store.activeCall).toEqual(
      expect.objectContaining({
        sipProfileId: 79,
        janusSessionKey: 'sip_profile:79',
      })
    );

    await store.handleCallStatusChanged({
      callSid: 'shared-native-sid-79',
      accountId: 1,
      inboxId: 194,
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'janus-inbound:same-sid-terminal',
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
      status: 'in_progress',
      answeredAt: '2026-07-19T06:45:00Z',
      currentUserId: 5,
      operatorClaim: {
        user_id: 5,
        user_name: 'Owner 79',
        internal_extension: '202',
      },
    });

    expect(store.activeCall).toEqual(
      expect.objectContaining({
        answeredAt: '2026-07-19T06:45:00Z',
        operatorInternalExtension: '202',
      })
    );
  });

  it('does not classify a claim with missing owner identity as foreign', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'claim-owner-unknown',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'claim-owner-unknown-logical',
    });
    store.setCallActive('claim-owner-unknown');

    await store.handleCallClaimed(
      {
        call_sid: 'claim-owner-unknown',
        provider: 'sipuni',
        logical_call_key: 'claim-owner-unknown-logical',
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'claim-owner-unknown',
        isActive: true,
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('uses the tracked local claim when a lightweight claim event omits owner identity', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'tracked-local-claim',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'tracked-local-claim-logical',
      operatorClaim: { user_id: 7 },
    });
    store.setCallActive('tracked-local-claim');

    await store.handleCallClaimed(
      {
        call_sid: 'tracked-local-claim',
        provider: 'sipuni',
        logical_call_key: 'tracked-local-claim-logical',
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'tracked-local-claim',
        isActive: true,
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('uses a tracked foreign claim for a later status without claim metadata', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'tracked-foreign-claim',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'tracked-foreign-claim-logical',
      operatorClaim: { user_id: 9 },
    });

    store.handleCallStatusChanged({
      callSid: 'tracked-foreign-claim',
      status: 'in_progress',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'tracked-foreign-claim-logical',
      currentUserId: 7,
    });

    expect(store.calls).toEqual([]);
  });

  it('suppresses every related SID after a sparse foreign claim event', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'primary-claimed-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      status: 'ringing',
    });

    await store.handleCallClaimed(
      {
        callSid: 'primary-claimed-sid',
        related_call_sids: ['related-operator-sid'],
        claimedByUserId: 9,
        callDirection: 'inbound',
      },
      7
    );
    store.addCall({
      callSid: 'related-operator-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      status: 'ringing',
    });

    expect(store.calls).toEqual([]);
  });

  it('removes calls for all canonical native terminal statuses', () => {
    const store = useCallsStore();

    [
      'completed',
      'busy',
      'failed',
      'missed',
      'no_answer',
      'cancelled',
      'rejected',
    ].forEach(status => {
      store.addCall({ callSid: `call-${status}` });
      store.handleCallStatusChanged({ callSid: `call-${status}`, status });
    });

    expect(store.calls).toEqual([]);
  });

  it('keeps same-provider same-SID calls isolated across SIP sessions', () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'shared-provider-session-sid',
      provider: 'sipuni',
      janusSessionKey: 'sip_profile:51',
      sipProfileId: 51,
      inboxId: 4771,
      status: 'ringing',
    });
    store.addCall({
      callSid: 'shared-provider-session-sid',
      provider: 'sipuni',
      janusSessionKey: 'sip_profile:52',
      sipProfileId: 52,
      inboxId: 4772,
      status: 'ringing',
    });

    store.handleCallStatusChanged({
      callSid: 'shared-provider-session-sid',
      provider: 'sipuni',
      status: 'completed',
    });
    expect(store.calls).toHaveLength(2);

    store.setCallActive('shared-provider-session-sid', 'sipuni', {
      janusSessionKey: 'sip_profile:51',
    });
    expect(
      store.calls.find(call => call.janusSessionKey === 'sip_profile:51')
        .isActive
    ).toBe(true);
    expect(
      store.calls.find(call => call.janusSessionKey === 'sip_profile:52')
        .isActive
    ).toBe(false);

    store.handleCallStatusChanged({
      callSid: 'shared-provider-session-sid',
      provider: 'sipuni',
      janusSessionKey: 'sip_profile:51',
      sipProfileId: 51,
      inboxId: 4771,
      status: 'completed',
    });
    expect(store.calls).toEqual([
      expect.objectContaining({ janusSessionKey: 'sip_profile:52' }),
    ]);
  });

  it('fails closed for an unscoped status with one logical key and multiple same-SID branches', () => {
    const store = useCallsStore();
    [
      { inboxId: 4771, sipProfileId: 51 },
      { inboxId: 4772, sipProfileId: 52 },
    ].forEach(({ inboxId, sipProfileId }) => {
      store.addCall({
        callSid: 'ambiguous-logical-status-sid',
        provider: 'sipuni',
        callDirection: 'inbound',
        inboxId,
        sipProfileId,
        janusSessionKey: `sip_profile:${sipProfileId}`,
        logicalCallKey: 'ambiguous-logical-status-key',
        status: 'ringing',
      });
    });

    store.handleCallStatusChanged({
      callSid: 'ambiguous-logical-status-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'ambiguous-logical-status-key',
      status: 'in_progress',
    });

    expect(store.calls).toHaveLength(2);
    expect(store.calls.every(call => call.status === 'ringing')).toBe(true);
  });

  it('fails closed when direct addCall is ambiguous across SIP sessions', () => {
    const store = useCallsStore();
    [51, 52].forEach(profileId => {
      store.addCall({
        callSid: 'ambiguous-direct-add-sid',
        provider: 'sipuni',
        janusSessionKey: `sip_profile:${profileId}`,
        sipProfileId: profileId,
        status: 'ringing',
      });
    });

    store.addCall({
      callSid: 'ambiguous-direct-add-sid',
      provider: 'sipuni',
      status: 'in_progress',
    });

    expect(store.calls).toHaveLength(2);
    expect(store.calls.every(call => call.status === 'ringing')).toBe(true);
  });

  it('does not deduplicate outbound conversation calls across SIP sessions', () => {
    const store = useCallsStore();
    [51, 52].forEach(profileId => {
      store.addCall({
        callSid: `conversation-session-sid-${profileId}`,
        provider: 'sipuni',
        callDirection: 'outbound',
        conversationId: 612,
        janusSessionKey: `sip_profile:${profileId}`,
        sipProfileId: profileId,
      });
    });

    expect(store.calls).toHaveLength(2);
  });

  it('clears related inbound branches from every SIP session on terminal status', () => {
    const store = useCallsStore();
    [
      ['terminal-related-sid-a', 51],
      ['terminal-related-sid-b', 52],
    ].forEach(([callSid, profileId]) => {
      store.addCall({
        callSid,
        provider: 'sipuni',
        callDirection: 'inbound',
        logicalCallKey: 'terminal-related-logical-key',
        janusSessionKey: `sip_profile:${profileId}`,
        sipProfileId: profileId,
        status: 'ringing',
      });
    });

    store.handleCallStatusChanged({
      callSid: 'terminal-related-sid-a',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'terminal-related-logical-key',
      janusSessionKey: 'sip_profile:51',
      sipProfileId: 51,
      status: 'completed',
    });

    expect(store.calls).toEqual([]);
  });

  it('keeps terminal suppression isolated by SIP session', () => {
    const store = useCallsStore();
    const callA = {
      callSid: 'reused-terminal-session-sid',
      provider: 'sipuni',
      janusSessionKey: 'sip_profile:51',
      sipProfileId: 51,
      inboxId: 4771,
      status: 'completed',
    };
    const callB = {
      callSid: 'reused-terminal-session-sid',
      provider: 'sipuni',
      janusSessionKey: 'sip_profile:52',
      sipProfileId: 52,
      inboxId: 4772,
      status: 'ringing',
    };

    store.rememberTerminalCall(callA);
    expect(store.isRecentlyTerminalCall(callA)).toBe(true);
    expect(store.isRecentlyTerminalCall(callB)).toBe(false);
    expect(
      store.isRecentlyTerminalCall({
        callSid: callA.callSid,
        provider: callA.provider,
      })
    ).toBe(true);

    store.addCall(callB);
    expect(store.calls).toEqual([expect.objectContaining(callB)]);
  });

  it('activates only the scoped outbound session for a reused provider SID', () => {
    const store = useCallsStore();
    [51, 52].forEach(profileId => {
      store.addCall({
        callSid: 'reused-outbound-session-sid',
        provider: 'sipuni',
        callDirection: 'outbound',
        janusSessionKey: `sip_profile:${profileId}`,
        sipProfileId: profileId,
        inboxId: 4700 + profileId,
        status: 'ringing',
      });
    });

    store.handleCallStatusChanged({
      callSid: 'reused-outbound-session-sid',
      provider: 'sipuni',
      callDirection: 'outbound',
      janusSessionKey: 'sip_profile:51',
      sipProfileId: 51,
      inboxId: 4751,
      status: 'in_progress',
    });

    expect(
      store.calls.find(call => call.janusSessionKey === 'sip_profile:51')
        .isActive
    ).toBe(true);
    expect(
      store.calls.find(call => call.janusSessionKey === 'sip_profile:52')
        .isActive
    ).toBe(false);
  });

  it('scopes foreign claim cleanup to the claimed SIP session', async () => {
    const store = useCallsStore();
    [51, 52].forEach(profileId => {
      store.addCall({
        callSid: 'reused-claim-session-sid',
        provider: 'sipuni',
        callDirection: 'inbound',
        janusSessionKey: `sip_profile:${profileId}`,
        sipProfileId: profileId,
        inboxId: 4700 + profileId,
        status: 'ringing',
      });
    });

    await store.handleCallClaimed(
      {
        call_sid: 'reused-claim-session-sid',
        provider: 'sipuni',
        janus_session_key: 'sip_profile:51',
        sip_profile_id: 51,
        inbox_id: 4751,
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({ janusSessionKey: 'sip_profile:52' }),
    ]);
  });

  it('fails closed for an unscoped claim across reused provider SID sessions', async () => {
    const store = useCallsStore();
    [51, 52].forEach(profileId => {
      store.addCall({
        callSid: 'ambiguous-claim-session-sid',
        provider: 'sipuni',
        callDirection: 'inbound',
        janusSessionKey: `sip_profile:${profileId}`,
        sipProfileId: profileId,
        inboxId: 4700 + profileId,
      });
    });

    await store.handleCallClaimed(
      {
        call_sid: 'ambiguous-claim-session-sid',
        provider: 'sipuni',
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toHaveLength(2);
  });

  it('clears every logical branch for an unscoped related claim', async () => {
    const store = useCallsStore();
    [
      ['related-claim-sid-a', 51],
      ['related-claim-sid-b', 52],
    ].forEach(([callSid, profileId]) => {
      store.addCall({
        callSid,
        provider: 'sipuni',
        callDirection: 'inbound',
        logicalCallKey: 'related-claim-logical-key',
        janusSessionKey: `sip_profile:${profileId}`,
        sipProfileId: profileId,
      });
    });

    await store.handleCallClaimed(
      {
        call_sid: 'related-claim-sid-a',
        provider: 'sipuni',
        logical_call_key: 'related-claim-logical-key',
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([]);
  });

  it('does not clear a newer active call through a stale scoped cleanup', async () => {
    const store = useCallsStore();
    const staleCall = {
      callSid: 'shared-active-session-sid',
      provider: 'sipuni',
      janusSessionKey: 'sip_profile:51',
    };
    const currentCall = {
      callSid: 'shared-active-session-sid',
      provider: 'sipuni',
      janusSessionKey: 'sip_profile:52',
    };
    store.addCall(staleCall);
    store.setCallActive(staleCall.callSid, staleCall.provider, staleCall);
    store.addCall(currentCall);
    store.setCallActive(currentCall.callSid, currentCall.provider, currentCall);

    await expect(store.clearActiveCall(staleCall)).resolves.toBe(false);
    expect(store.activeCall).toEqual(expect.objectContaining(currentCall));
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('scopes browser join, active, and dismiss actions by provider', () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'shared-browser-action-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
    });
    store.addCall({
      callSid: 'shared-browser-action-sid',
      provider: 'binotel',
      callDirection: 'inbound',
    });

    store.markBrowserJoinUnsupported('shared-browser-action-sid', 'sipuni');
    store.markBrowserJoined('shared-browser-action-sid', 'sipuni');
    store.setCallActive('shared-browser-action-sid', 'sipuni');

    const sipuniCall = store.calls.find(call => call.provider === 'sipuni');
    const binotelCall = store.calls.find(call => call.provider === 'binotel');
    expect(sipuniCall).toMatchObject({
      browserJoinSupported: false,
      browserJoined: true,
      isActive: true,
    });
    expect(binotelCall).toMatchObject({
      isActive: false,
      browserJoinSupported: null,
    });

    store.dismissCall('shared-browser-action-sid', 'sipuni');
    expect(store.calls).toEqual([
      expect.objectContaining({ provider: 'binotel' }),
    ]);
  });

  it('keeps same-SID calls isolated across providers for status and claim events', async () => {
    const store = useCallsStore();
    store.addCall({
      callSid: 'cross-provider-live-sid',
      provider: 'binotel',
      callDirection: 'inbound',
      status: 'ringing',
    });

    store.addCall({
      callSid: 'cross-provider-live-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      status: 'ringing',
    });
    expect(store.calls).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          callSid: 'cross-provider-live-sid',
          provider: 'binotel',
        }),
        expect.objectContaining({
          callSid: 'cross-provider-live-sid',
          provider: 'sipuni',
        }),
      ])
    );

    store.handleCallStatusChanged({
      callSid: 'cross-provider-live-sid',
      callDirection: 'inbound',
      status: 'completed',
    });
    expect(store.calls).toHaveLength(2);

    store.handleCallStatusChanged({
      callSid: 'cross-provider-live-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      status: 'completed',
    });
    await store.handleCallClaimed(
      {
        callSid: 'cross-provider-live-sid',
        provider: 'sipuni',
        claimedByUserId: 9,
        callDirection: 'inbound',
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'cross-provider-live-sid',
        provider: 'binotel',
      }),
    ]);
  });

  it('does not suppress another provider that reuses the same call identifiers', () => {
    const store = useCallsStore();
    store.handleCallStatusChanged({
      callSid: 'provider-reused-call-id',
      status: 'completed',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'provider-reused-logical-key',
    });

    store.addCall({
      callSid: 'provider-reused-call-id',
      status: 'ringing',
      provider: 'binotel',
      callDirection: 'inbound',
      logicalCallKey: 'provider-reused-logical-key',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'provider-reused-call-id',
        provider: 'binotel',
      }),
    ]);
  });

  it('does not re-add a Sipuni call when a delayed non-terminal event arrives after completion', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'sipuni:1782820473.488058',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni:1782820473.488058',
    });
    store.handleCallStatusChanged({
      callSid: 'sipuni:1782820473.488058',
      status: 'completed',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'sipuni:1782820473.488058',
    });
    store.handleCallStatusChanged({
      callSid: 'sipuni:1782820473.488058',
      status: 'in_progress',
      provider: 'sipuni',
      callDirection: 'inbound',
      conversationId: 724,
      logicalCallKey: 'sipuni:1782820473.488058',
    });

    expect(store.calls).toEqual([]);
  });

  it('does not remove an active Janus SIP call by conversation when a different terminal call ref arrives', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'current-call-ref',
      provider: 'sipuni',
      conversationId: 612,
    });
    store.setCallActive('current-call-ref');

    store.handleCallStatusChanged({
      callSid: 'old-terminal-ref',
      status: 'completed',
      conversationId: 612,
      provider: 'sipuni',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'current-call-ref',
        conversationId: 612,
        isActive: true,
        provider: 'sipuni',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('removes a Janus SIP call by conversation only when terminal event has no call ref', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'call-without-terminal-ref',
      provider: 'sipuni',
      conversationId: 612,
    });
    store.setCallActive('call-without-terminal-ref');

    store.handleCallStatusChanged({
      status: 'completed',
      conversationId: 612,
      provider: 'sipuni',
    });

    expect(store.calls).toEqual([]);
    await vi.waitFor(() => {
      expect(endClientCallMock).toHaveBeenCalledWith(
        expect.objectContaining({
          callSid: 'call-without-terminal-ref',
          provider: 'sipuni',
        })
      );
    });
  });

  it('fails closed for an ambiguous terminal event with conversation scope only', () => {
    const store = useCallsStore();
    store.calls = ['conversation-call-a', 'conversation-call-b'].map(
      callSid => ({
        callSid,
        provider: 'sipuni',
        conversationId: 612,
        callDirection: 'outbound',
      })
    );

    store.handleCallStatusChanged({
      status: 'completed',
      provider: 'sipuni',
      conversationId: 612,
      callDirection: 'outbound',
    });

    expect(store.calls).toHaveLength(2);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('suppresses delayed status without claim metadata after a foreign claimed event', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'claim-before-unscoped-status',
      status: 'ringing',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'claim-before-unscoped-status-logical',
    });
    await store.handleCallClaimed(
      {
        call_sid: 'claim-before-unscoped-status',
        provider: 'sipuni',
        logical_call_key: 'claim-before-unscoped-status-logical',
        claimed_by_user_id: 9,
      },
      7
    );
    store.handleCallStatusChanged({
      callSid: 'claim-before-unscoped-status',
      status: 'in_progress',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'claim-before-unscoped-status-logical',
    });

    expect(store.calls).toEqual([]);
  });

  it('suppresses a late incoming event after another operator status wins first', () => {
    const store = useCallsStore();

    store.handleCallStatusChanged({
      callSid: 'status-before-incoming',
      status: 'in_progress',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'status-before-incoming-logical',
      operatorClaim: { user_id: 9 },
      currentUserId: 7,
    });
    store.addCall({
      callSid: 'status-before-incoming',
      status: 'ringing',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'status-before-incoming-logical',
    });

    expect(store.calls).toEqual([]);
  });

  it('does not re-add a dismissed ringing widget from a delayed claimed status event', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'shared-call-delayed-status',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'shared-logical-call',
    });
    store.handleCallStatusChanged({
      callSid: 'shared-call-delayed-status',
      status: 'in_progress',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'shared-logical-call',
      operatorClaim: { user_id: 9 },
      currentUserId: 7,
    });

    expect(store.calls).toEqual([]);
  });

  it('ends a browser-joined native leg when a delayed status belongs to another operator', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'browser-joined-delayed-status',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'browser-joined-logical-call',
      janusSessionKey: 'sip_profile:52',
    });
    store.markBrowserJoined('browser-joined-delayed-status', 'sipuni');
    store.handleCallStatusChanged({
      callSid: 'browser-joined-delayed-status',
      status: 'in_progress',
      provider: 'sipuni',
      callDirection: 'inbound',
      logicalCallKey: 'browser-joined-logical-call',
      operatorClaim: { user_id: 9 },
      currentUserId: 7,
    });

    expect(store.calls).toEqual([]);
    await vi.waitFor(() => {
      expect(endClientCallMock).toHaveBeenCalledWith(
        expect.objectContaining({ sessionKey: 'sip_profile:52' })
      );
    });
  });

  it('keeps a non-active widget visible when another operator moves the call in progress', () => {
    const store = useCallsStore();

    store.addCall({ callSid: 'shared-call-1', provider: 'sipuni' });
    store.handleCallStatusChanged({
      callSid: 'shared-call-1',
      status: 'in_progress',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'shared-call-1',
        status: 'in_progress',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_IN_PROGRESS',
      }),
    ]);
  });

  it('marks an outbound Janus SIP call active when the backend reports in progress', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'outbound-call-1',
      provider: 'sipuni',
      callDirection: 'outbound',
    });
    store.handleCallStatusChanged({
      callSid: 'outbound-call-1',
      status: 'in_progress',
      provider: 'sipuni',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'outbound-call-1',
        callDirection: 'outbound',
        isActive: true,
        provider: 'sipuni',
      }),
    ]);
  });

  it('creates an active outbound Janus SIP call when in progress arrives before local ringing state', () => {
    const store = useCallsStore();

    store.handleCallStatusChanged({
      callSid: 'outbound-call-2',
      status: 'in_progress',
      conversationId: 44,
      inboxId: 88,
      provider: 'sipuni',
      callDirection: 'outbound',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'outbound-call-2',
        callDirection: 'outbound',
        conversationId: 44,
        inboxId: 88,
        isActive: true,
        provider: 'sipuni',
      }),
    ]);
  });

  it('updates stage metadata for an existing outbound Janus SIP call', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'outbound-stage-1',
      provider: 'sipuni',
      callDirection: 'outbound',
      status: 'created',
    });

    store.handleCallStatusChanged({
      callSid: 'outbound-stage-1',
      status: 'ringing',
      provider: 'sipuni',
      callEvent: 'dial_status',
      callLeg: 'callee',
      rawStatus: 'RINGING',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'outbound-stage-1',
        callDirection: 'outbound',
        callEvent: 'dial_status',
        callLeg: 'callee',
        rawStatus: 'RINGING',
        status: 'ringing',
      }),
    ]);
  });

  it('clears stale stage metadata when a status-only update arrives', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'outbound-stage-stale',
      provider: 'sipuni',
      callDirection: 'outbound',
      status: 'ringing',
      callEvent: 'dial_status',
      callLeg: 'callee',
      rawStatus: 'RINGING',
    });

    store.handleCallStatusChanged({
      callSid: 'outbound-stage-stale',
      status: 'in_progress',
      provider: 'sipuni',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callEvent: null,
        callLeg: null,
        callSid: 'outbound-stage-stale',
        isActive: true,
        rawStatus: null,
        status: 'in_progress',
      }),
    ]);
  });
});
