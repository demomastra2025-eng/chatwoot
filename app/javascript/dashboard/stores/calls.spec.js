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

  it('keeps a related inbound branch from another SIP session on terminal status', () => {
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

    expect(store.calls).toEqual([
      expect.objectContaining({ callSid: 'terminal-related-sid-b' }),
    ]);
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

  it('keeps an unscoped related claim isolated from another SIP session', async () => {
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

    expect(store.calls).toEqual([
      expect.objectContaining({ callSid: 'related-claim-sid-b' }),
    ]);
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
