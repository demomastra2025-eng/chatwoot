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
});
