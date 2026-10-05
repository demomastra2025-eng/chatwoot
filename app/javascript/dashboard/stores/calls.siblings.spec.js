import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { hasPendingIncomingCallMock } = vi.hoisted(() => ({
  hasPendingIncomingCallMock: vi.fn(),
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    endClientCall: vi.fn(),
    hasPendingIncomingCall: hasPendingIncomingCallMock,
    rejectIncomingCall: vi.fn(),
  },
}));

import {
  SIBLING_LEG_WINDOW_MS,
  STALE_INCOMING_CALL_TTL_MS,
  useCallsStore,
} from './calls';

// Every operator browser of a Beeline channel reports its own leg of one
// physical call; the legs share one logical call key once the server groups
// them, and a card must never outlive its call.
const incoming = (overrides = {}) => ({
  callSid: 'beeline:janus:101:call-id-a',
  provider: 'beeline',
  callDirection: 'inbound',
  status: 'ringing',
  accountId: 1,
  inboxId: 5,
  fromNumber: '+70000000001',
  toNumber: '+70000000099',
  ...overrides,
});

const ownLeg = (overrides = {}) =>
  incoming({
    sipProfileId: 101,
    janusSessionKey: 'sip_profile:101',
    ...overrides,
  });

describe('useCallsStore sibling legs of one physical call', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-05T07:30:00Z'));
    setActivePinia(createPinia());
    hasPendingIncomingCallMock.mockReset();
    hasPendingIncomingCallMock.mockReturnValue(false);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('one logical call key', () => {
    const keyed = (callSid, extra = {}) =>
      ownLeg({ callSid, logicalCallKey: 'janus-inbound:one-call', ...extra });

    it('removes every ringing card of the call when another operator claims it', async () => {
      const store = useCallsStore();
      store.addCall(keyed('beeline:janus:101:call-id-a'));
      store.addCall(
        keyed('beeline:janus:102:call-id-b', {
          sipProfileId: 102,
          janusSessionKey: 'sip_profile:102',
        })
      );

      await store.handleCallClaimed(
        {
          call_sid: 'beeline:janus:103:call-id-c',
          provider: 'beeline',
          call_direction: 'inbound',
          account_id: 1,
          inbox_id: 5,
          logical_call_key: 'janus-inbound:one-call',
          related_call_sids: [
            'beeline:janus:101:call-id-a',
            'beeline:janus:102:call-id-b',
            'beeline:janus:103:call-id-c',
          ],
          claimed_by_user_id: 9,
        },
        7
      );

      expect(store.calls).toEqual([]);
    });

    it('removes every ringing card of the call when one leg ends', () => {
      const store = useCallsStore();
      store.addCall(keyed('beeline:janus:101:call-id-a'));
      store.addCall(
        keyed('beeline:janus:102:call-id-b', {
          sipProfileId: 102,
          janusSessionKey: 'sip_profile:102',
        })
      );

      store.handleCallStatusChanged({
        callSid: 'beeline:janus:103:call-id-c',
        status: 'no_answer',
        provider: 'beeline',
        callDirection: 'inbound',
        accountId: 1,
        inboxId: 5,
        logicalCallKey: 'janus-inbound:one-call',
        logicalCallTerminal: true,
        currentUserId: 7,
      });

      expect(store.calls).toEqual([]);
    });

    it.each(['ringing', 'connecting'])(
      'keeps the %s card of the call the employee answers when another leg of it ends',
      status => {
        const store = useCallsStore();
        store.addCall(
          keyed('beeline:janus:103:call-id-c', {
            status,
            sipProfileId: 103,
            janusSessionKey: 'sip_profile:103',
          })
        );

        [
          { sipProfileId: 102 },
          { sipProfileId: 103 },
          { sipProfileId: undefined },
        ].forEach(scope => {
          store.handleCallStatusChanged({
            callSid: 'beeline:janus:102:call-id-b',
            status: 'no_answer',
            provider: 'beeline',
            callDirection: 'inbound',
            accountId: 1,
            inboxId: 5,
            logicalCallKey: 'janus-inbound:one-call',
            logicalCallTerminal: false,
            currentUserId: 7,
            ...scope,
          });
        });

        expect(store.calls.map(call => call.callSid)).toEqual([
          'beeline:janus:103:call-id-c',
        ]);
      }
    );

    it('removes the card of the leg that ended while the others are still open', () => {
      const store = useCallsStore();
      store.addCall(keyed('beeline:janus:101:call-id-a'));

      store.handleCallStatusChanged({
        callSid: 'beeline:janus:101:call-id-a',
        status: 'no_answer',
        provider: 'beeline',
        callDirection: 'inbound',
        accountId: 1,
        inboxId: 5,
        logicalCallKey: 'janus-inbound:one-call',
        logicalCallTerminal: false,
        currentUserId: 7,
      });

      expect(store.calls).toEqual([]);
    });

    it('keeps the card of a different call of the same client', () => {
      const store = useCallsStore();
      store.addCall(keyed('beeline:janus:101:call-id-a'));
      store.addCall(
        keyed('beeline:janus:101:call-id-next', {
          logicalCallKey: 'janus-inbound:next-call',
        })
      );

      expect(store.calls).toHaveLength(2);
    });
  });

  describe('no logical call key', () => {
    it('shows one card for the same caller on the same channel within the window', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());

      vi.advanceTimersByTime(3000);
      store.addCall(
        ownLeg({
          callSid: 'beeline:janus:102:call-id-b',
          sipProfileId: 102,
          janusSessionKey: 'sip_profile:102',
        })
      );

      expect(store.calls.map(call => call.callSid)).toEqual([
        'beeline:janus:101:call-id-a',
      ]);
    });

    it('keeps the leg that has a SIP session of this browser behind it', () => {
      const store = useCallsStore();
      store.addCall(incoming({ callSid: 'beeline:janus:102:call-id-b' }));

      vi.advanceTimersByTime(1000);
      store.addCall(ownLeg());

      expect(store.calls).toHaveLength(1);
      expect(store.calls[0]).toMatchObject({
        callSid: 'beeline:janus:101:call-id-a',
        sipProfileId: 101,
      });
    });

    it('shows the next call of the same caller once the window is over', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());

      vi.advanceTimersByTime(SIBLING_LEG_WINDOW_MS + 1000);
      store.addCall(
        ownLeg({
          callSid: 'beeline:janus:101:call-id-next',
          janusSessionKey: 'sip_profile:101-next',
        })
      );

      expect(store.calls).toHaveLength(2);
    });

    it('keeps another caller on the same channel separate', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());
      store.addCall(
        ownLeg({
          callSid: 'beeline:janus:101:call-id-other',
          fromNumber: '+70000000002',
          janusSessionKey: 'sip_profile:101-other',
        })
      );

      expect(store.calls).toHaveLength(2);
    });
  });

  describe('stale ringing cards', () => {
    it('keeps a card the server spoke about recently', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());

      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS - 1000);
      store.expireStaleIncomingCalls();

      expect(store.calls).toHaveLength(1);
    });

    it('removes a card that heard nothing for 150 seconds and has no live SIP session', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());

      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS + 1000);
      const removed = store.expireStaleIncomingCalls();

      expect(removed.map(call => call.callSid)).toEqual([
        'beeline:janus:101:call-id-a',
      ]);
      expect(store.calls).toEqual([]);
    });

    it('does not bring the removed card back when a late event arrives', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());
      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS + 1000);
      store.expireStaleIncomingCalls();

      store.addCall(ownLeg());

      expect(store.calls).toEqual([]);
    });

    it('never removes the ringing leg of this browser while its SIP session is live', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());
      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS + 1000);

      store.expireStaleIncomingCalls({ isLocalSessionLive: () => true });

      expect(store.calls).toHaveLength(1);
    });

    it('restarts the clock with every event about the call', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());
      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS - 10_000);
      store.addCall(ownLeg());
      vi.advanceTimersByTime(60_000);

      store.expireStaleIncomingCalls();

      expect(store.calls).toHaveLength(1);
    });

    it('never removes an answered call', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());
      store.setCallActive('beeline:janus:101:call-id-a', 'beeline', ownLeg());
      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS * 4);

      store.expireStaleIncomingCalls();

      expect(store.calls).toHaveLength(1);
    });

    it('never removes an outbound call', () => {
      const store = useCallsStore();
      store.addCall(
        ownLeg({ callSid: 'beeline:local:out-1', callDirection: 'outbound' })
      );
      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS * 2);

      store.expireStaleIncomingCalls();

      expect(store.calls).toHaveLength(1);
    });

    it('removes only the cards that are stale', () => {
      const store = useCallsStore();
      store.addCall(ownLeg());
      vi.advanceTimersByTime(STALE_INCOMING_CALL_TTL_MS - 5000);
      store.addCall(
        ownLeg({
          callSid: 'beeline:janus:101:call-id-next',
          fromNumber: '+70000000002',
          janusSessionKey: 'sip_profile:101-next',
        })
      );
      vi.advanceTimersByTime(10_000);

      store.expireStaleIncomingCalls();

      expect(store.calls.map(call => call.callSid)).toEqual([
        'beeline:janus:101:call-id-next',
      ]);
    });
  });
});
