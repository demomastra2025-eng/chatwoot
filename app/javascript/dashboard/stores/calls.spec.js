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
