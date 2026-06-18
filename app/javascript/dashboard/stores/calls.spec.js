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
      provider: 'fonoster',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        browserJoinSupported: null,
        callDirection: 'inbound',
        callSid: 'call-123',
        conversationId: 8,
        inboxId: 44,
        isActive: false,
        provider: 'fonoster',
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
    store.markBrowserJoinUnsupported('call-789', 'fonoster');

    store.addCall({
      callSid: 'call-789',
      inboxId: 99,
    });

    expect(store.calls[0]).toEqual(
      expect.objectContaining({
        browserJoinSupported: false,
        inboxId: 99,
        isActive: true,
        provider: 'fonoster',
      })
    );
  });

  it('stores the outside-browser operator claim details for display', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'claimed-call-1',
      callDirection: 'inbound',
      provider: 'fonoster',
    });
    store.markBrowserJoinUnsupported('claimed-call-1', 'fonoster', {
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
      provider: 'fonoster',
    });
    store.markBrowserJoined('call-browser-joined', 'fonoster');

    expect(store.calls).toEqual([
      expect.objectContaining({
        browserJoined: true,
        callSid: 'call-browser-joined',
        isActive: false,
        provider: 'fonoster',
      }),
    ]);
    expect(store.activeCall).toBeNull();
  });

  it('replaces a stale Fonoster call for the same conversation instead of stacking widgets', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'old-call-ref',
      provider: 'fonoster',
      conversationId: 612,
      callDirection: 'outbound',
    });
    store.setCallActive('old-call-ref');

    store.addCall({
      callSid: 'new-call-ref',
      provider: 'fonoster',
      conversationId: 612,
      callDirection: 'outbound',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'new-call-ref',
        conversationId: 612,
        isActive: false,
        provider: 'fonoster',
      }),
    ]);
    await vi.waitFor(() => {
      expect(endClientCallMock).toHaveBeenCalledWith('fonoster');
    });
  });

  it('deduplicates Fonoster inbound branches by logical call key without replacing the actionable call ref', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'fonoster-inbound:shared-key',
      fromNumber: '+77066318623',
      toNumber: '+77072890808',
    });

    store.addCall({
      callSid: 'operator-501-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'fonoster-inbound:shared-key',
      fromNumber: '+77066318623',
      toNumber: '+77072890808',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        logicalCallKey: 'fonoster-inbound:shared-key',
        provider: 'fonoster',
      }),
    ]);
  });

  it('removes a deduped Fonoster inbound card when a sibling branch terminates', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:shared-key',
    });
    store.addCall({
      callSid: 'operator-501-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:shared-key',
    });

    store.handleCallStatusChanged({
      callSid: 'operator-501-ref',
      status: 'completed',
      provider: 'fonoster',
      callDirection: 'inbound',
      logicalCallKey: 'fonoster-inbound:shared-key',
    });

    expect(store.calls).toEqual([]);
  });

  it('keeps an active Fonoster inbound card when a sibling branch terminates', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:shared-key',
    });
    store.setCallActive('operator-505-ref');

    store.handleCallStatusChanged({
      callSid: 'operator-501-ref',
      status: 'completed',
      provider: 'fonoster',
      callDirection: 'inbound',
      logicalCallKey: 'fonoster-inbound:shared-key',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-505-ref',
        isActive: true,
        logicalCallKey: 'fonoster-inbound:shared-key',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('keeps separate Fonoster inbound calls when logical call keys differ', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'first-real-call',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'fonoster-inbound:first',
    });
    store.addCall({
      callSid: 'second-real-call',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      inboxId: 158,
      logicalCallKey: 'fonoster-inbound:second',
    });

    expect(store.calls).toHaveLength(2);
    expect(store.calls.map(call => call.callSid)).toEqual([
      'first-real-call',
      'second-real-call',
    ]);
  });

  it('clears sibling Fonoster inbound branches when one branch becomes active', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      logicalCallKey: 'fonoster-inbound:shared-key',
    });
    store.addCall({
      callSid: 'other-call',
      provider: 'fonoster',
      callDirection: 'inbound',
      logicalCallKey: 'fonoster-inbound:other-key',
    });
    store.calls.push({
      callSid: 'late-sibling-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      logicalCallKey: 'fonoster-inbound:shared-key',
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

  it('keeps Fonoster inbound calls separate in the same conversation when logical keys differ', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:first-leg',
    });
    store.addCall({
      callSid: 'operator-505-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:second-leg',
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
        logicalCallKey: 'fonoster-inbound:second-leg',
      }),
    ]);
  });

  it('removes related Fonoster inbound widgets when another operator claims the call', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:shared-key',
    });

    await store.handleCallClaimed(
      {
        call_sid: 'operator-505-ref',
        provider: 'fonoster',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'fonoster-inbound:shared-key',
        related_call_sids: ['operator-504-ref', 'operator-505-ref'],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('ends the browser client only when a claimed Fonoster call was active in this browser', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:shared-key',
    });
    store.setCallActive('operator-504-ref');

    await store.handleCallClaimed(
      {
        call_sid: 'operator-505-ref',
        provider: 'fonoster',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'fonoster-inbound:shared-key',
        related_call_sids: ['operator-504-ref', 'operator-505-ref'],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([]);
    expect(endClientCallMock).toHaveBeenCalledWith('fonoster');
  });

  it('does not remove a different Fonoster inbound call with another logical key in the same conversation', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:first-call',
    });

    await store.handleCallClaimed(
      {
        call_sid: 'operator-505-ref',
        provider: 'fonoster',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'fonoster-inbound:second-call',
        related_call_sids: ['operator-505-ref'],
        claimed_by_user_id: 9,
      },
      7
    );

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'operator-504-ref',
        logicalCallKey: 'fonoster-inbound:first-call',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('keeps the current operator active call when the claim event belongs to them', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'operator-504-ref',
      provider: 'fonoster',
      callDirection: 'inbound',
      conversationId: 612,
      logicalCallKey: 'fonoster-inbound:shared-key',
    });
    store.setCallActive('operator-504-ref');

    await store.handleCallClaimed(
      {
        call_sid: 'operator-504-ref',
        provider: 'fonoster',
        call_direction: 'inbound',
        conversation_id: 612,
        logical_call_key: 'fonoster-inbound:shared-key',
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

  it('does not remove an active Fonoster call by conversation when a different terminal call ref arrives', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'current-call-ref',
      provider: 'fonoster',
      conversationId: 612,
    });
    store.setCallActive('current-call-ref');

    store.handleCallStatusChanged({
      callSid: 'old-terminal-ref',
      status: 'completed',
      conversationId: 612,
      provider: 'fonoster',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'current-call-ref',
        conversationId: 612,
        isActive: true,
        provider: 'fonoster',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('removes a Fonoster call by conversation only when terminal event has no call ref', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'call-without-terminal-ref',
      provider: 'fonoster',
      conversationId: 612,
    });
    store.setCallActive('call-without-terminal-ref');

    store.handleCallStatusChanged({
      status: 'completed',
      conversationId: 612,
      provider: 'fonoster',
    });

    expect(store.calls).toEqual([]);
    await vi.waitFor(() => {
      expect(endClientCallMock).toHaveBeenCalledWith('fonoster');
    });
  });

  it('dismisses a non-active ringing widget when another operator moves the call in progress', () => {
    const store = useCallsStore();

    store.addCall({ callSid: 'shared-call-1', provider: 'fonoster' });
    store.handleCallStatusChanged({
      callSid: 'shared-call-1',
      status: 'in_progress',
    });

    expect(store.calls).toEqual([]);
  });

  it('marks an outbound Fonoster call active when the backend reports in progress', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'outbound-call-1',
      provider: 'fonoster',
      callDirection: 'outbound',
    });
    store.handleCallStatusChanged({
      callSid: 'outbound-call-1',
      status: 'in_progress',
      provider: 'fonoster',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'outbound-call-1',
        callDirection: 'outbound',
        isActive: true,
        provider: 'fonoster',
      }),
    ]);
  });

  it('creates an active outbound Fonoster call when in progress arrives before local ringing state', () => {
    const store = useCallsStore();

    store.handleCallStatusChanged({
      callSid: 'outbound-call-2',
      status: 'in_progress',
      conversationId: 44,
      inboxId: 88,
      provider: 'fonoster',
      callDirection: 'outbound',
    });

    expect(store.calls).toEqual([
      expect.objectContaining({
        callSid: 'outbound-call-2',
        callDirection: 'outbound',
        conversationId: 44,
        inboxId: 88,
        isActive: true,
        provider: 'fonoster',
      }),
    ]);
  });

  it('updates stage metadata for an existing outbound Fonoster call', () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'outbound-stage-1',
      provider: 'fonoster',
      callDirection: 'outbound',
      status: 'created',
    });

    store.handleCallStatusChanged({
      callSid: 'outbound-stage-1',
      status: 'ringing',
      provider: 'fonoster',
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
      provider: 'fonoster',
      callDirection: 'outbound',
      status: 'ringing',
      callEvent: 'dial_status',
      callLeg: 'callee',
      rawStatus: 'RINGING',
    });

    store.handleCallStatusChanged({
      callSid: 'outbound-stage-stale',
      status: 'in_progress',
      provider: 'fonoster',
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
