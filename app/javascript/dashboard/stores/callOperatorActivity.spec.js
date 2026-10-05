import { beforeEach, describe, expect, it } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import {
  activityMatchesChat,
  useCallOperatorActivityStore,
} from './callOperatorActivity';

const ME = 7;
const NOW = new Date('2026-10-05T06:00:00Z').getTime();
const MINUTE = 60 * 1000;

const activity = (overrides = {}) => ({
  call_id: 'sipuni:local:one',
  conversation_id: 627,
  operator_user_id: 9,
  operator_name: 'Ayan',
  state: 'calling',
  ...overrides,
});

describe('useCallOperatorActivityStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('keeps the line of another operator calling the client of the chat', () => {
    const store = useCallOperatorActivityStore();

    store.applyActivity(activity(), ME, NOW);

    expect(store.forChat({ id: 627 }, ME, NOW)).toEqual([
      expect.objectContaining({
        callId: 'sipuni:local:one',
        operatorName: 'Ayan',
        operatorUserId: 9,
        state: 'calling',
      }),
    ]);
    expect(store.forChat({ id: 628 }, ME, NOW)).toEqual([]);
  });

  it('moves the line from calling to talking and removes it when the call ends', () => {
    const store = useCallOperatorActivityStore();

    store.applyActivity(activity(), ME, NOW);
    store.applyActivity(activity({ state: 'talking' }), ME, NOW + MINUTE);
    expect(store.forChat({ id: 627 }, ME, NOW + MINUTE)).toEqual([
      expect.objectContaining({ state: 'talking' }),
    ]);

    store.applyActivity(activity({ state: 'ended' }), ME, NOW + 2 * MINUTE);
    expect(store.forChat({ id: 627 }, ME, NOW + 2 * MINUTE)).toEqual([]);
    expect(store.entries).toEqual({});
  });

  it('shows two operators who call at almost the same time, one line each', () => {
    const store = useCallOperatorActivityStore();

    store.applyActivity(activity(), ME, NOW);
    store.applyActivity(
      activity({
        call_id: 'sipuni:local:two',
        operator_user_id: 10,
        operator_name: 'Aigerim',
      }),
      ME,
      NOW + 1000
    );

    expect(
      store.forChat({ id: 627 }, ME, NOW + 1000).map(line => line.operatorName)
    ).toEqual(['Ayan', 'Aigerim']);
  });

  it('keeps one line per operator even when two of his call sessions report', () => {
    const store = useCallOperatorActivityStore();

    store.applyActivity(activity(), ME, NOW);
    store.applyActivity(
      activity({ call_id: 'sipuni:local:leg-two', state: 'talking' }),
      ME,
      NOW + 1000
    );

    expect(store.forChat({ id: 627 }, ME, NOW + 1000)).toEqual([
      expect.objectContaining({ callId: 'sipuni:local:leg-two' }),
    ]);
  });

  it('never keeps a line for the employee own call', () => {
    const store = useCallOperatorActivityStore();

    store.applyActivity(activity({ operator_user_id: ME }), ME, NOW);
    store.applyActivity(activity({ operator_user_id: String(ME) }), ME, NOW);

    expect(store.entries).toEqual({});
  });

  it('ignores an event without a call id or with an unknown state', () => {
    const store = useCallOperatorActivityStore();

    store.applyActivity(activity({ call_id: undefined }), ME, NOW);
    store.applyActivity(activity({ state: 'strange' }), ME, NOW);

    expect(store.entries).toEqual({});
  });

  it('never leaves a stuck "is calling" line: it expires after a few minutes', () => {
    const store = useCallOperatorActivityStore();
    store.applyActivity(activity(), ME, NOW);

    expect(store.forChat({ id: 627 }, ME, NOW + 2 * MINUTE)).toHaveLength(1);
    expect(store.forChat({ id: 627 }, ME, NOW + 4 * MINUTE)).toEqual([]);

    store.pruneStale(NOW + 4 * MINUTE);
    expect(store.entries).toEqual({});
  });

  it('keeps a talking line of a long call but drops one that outlived the longest call', () => {
    const store = useCallOperatorActivityStore();
    store.applyActivity(activity({ state: 'talking' }), ME, NOW);

    expect(store.forChat({ id: 627 }, ME, NOW + 120 * MINUTE)).toHaveLength(1);
    expect(store.forChat({ id: 627 }, ME, NOW + 251 * MINUTE)).toEqual([]);
  });

  it('starts over with what the server says when a chat is opened or the connection returns', () => {
    const store = useCallOperatorActivityStore();
    store.applyActivity(
      activity({ call_id: 'stale', operator_name: 'Stale' }),
      ME,
      NOW
    );
    store.applyActivity(
      activity({ call_id: 'other-chat', conversation_id: 700 }),
      ME,
      NOW
    );

    store.syncChat(
      { id: 627 },
      [
        activity({
          call_id: 'fresh',
          operator_name: 'Fresh',
          state: 'talking',
        }),
      ],
      ME,
      NOW + MINUTE
    );

    expect(Object.keys(store.entries).sort()).toEqual(['fresh', 'other-chat']);
    expect(store.forChat({ id: 627 }, ME, NOW + MINUTE)).toEqual([
      expect.objectContaining({ operatorName: 'Fresh', state: 'talking' }),
    ]);
  });

  it('forgets everything on clear', () => {
    const store = useCallOperatorActivityStore();
    store.applyActivity(activity(), ME, NOW);

    store.clear();

    expect(store.entries).toEqual({});
  });
});

describe('activityMatchesChat', () => {
  const entry = {
    conversationId: 627,
    communicationThreadId: 72,
  };

  it('matches the conversation of the chat', () => {
    expect(activityMatchesChat(entry, { id: 627 })).toBe(true);
    expect(activityMatchesChat(entry, { id: '627' })).toBe(true);
    expect(activityMatchesChat(entry, { id: 628 })).toBe(false);
  });

  it('matches a conversation that belongs to the same communication thread', () => {
    expect(
      activityMatchesChat(entry, { id: 700, communication_thread_id: 72 })
    ).toBe(true);
    expect(
      activityMatchesChat(entry, { id: 700, communication_thread_id: 73 })
    ).toBe(false);
  });

  it('matches the thread view by thread or by one of its conversations', () => {
    expect(
      activityMatchesChat(entry, { id: 72, is_communication_thread: true })
    ).toBe(true);
    expect(
      activityMatchesChat(
        { conversationId: 627 },
        {
          id: 5,
          is_communication_thread: true,
          channels: [{ conversation_id: 627 }],
        }
      )
    ).toBe(true);
    expect(
      activityMatchesChat(
        { conversationId: 627 },
        { id: 627, is_communication_thread: true }
      )
    ).toBe(false);
  });

  it('matches nothing without a chat', () => {
    expect(activityMatchesChat(entry, null)).toBe(false);
  });
});
