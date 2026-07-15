import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { endClientCallMock } = vi.hoisted(() => ({
  endClientCallMock: vi.fn(),
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    endClientCall: endClientCallMock,
  },
}));

import { useCallsStore } from './calls';

describe('useCallsStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    endClientCallMock.mockReset();
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

  it('keeps a related Janus SIP inbound widget visible when another operator claims the call', async () => {
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

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        status: 'in_progress',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
      }),
    ]);
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

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        status: 'in_progress',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
      }),
    ]);
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

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'sipuni:operator-505-ref',
        communicationThreadId: 72,
        status: 'in_progress',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
      }),
    ]);
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
      expect.objectContaining({
        callSid: 'sipuni:claimed-call',
        conversationId: 612,
        communicationThreadId: 72,
        status: 'in_progress',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
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
      expect.objectContaining({
        callSid: 'operator-505-ref',
        logicalCallKey: 'sipuni-inbound:second-call',
        status: 'in_progress',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
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
