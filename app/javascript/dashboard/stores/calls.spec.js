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

  it('removes a stale active Fonoster call by conversation when terminal ref changed', async () => {
    const store = useCallsStore();

    store.addCall({
      callSid: 'old-call-ref',
      provider: 'fonoster',
      conversationId: 612,
    });
    store.setCallActive('old-call-ref');

    store.handleCallStatusChanged({
      callSid: 'new-terminal-ref',
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
});
