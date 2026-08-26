import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  clearScheduledMessageDraft,
  consumeScheduledMessageDraft,
  setScheduledMessageDraft,
} from './useScheduledMessageDraft';

const context = {
  accountId: 1,
  conversationId: 12,
  remindableId: 12,
  remindableType: 'Conversation',
};

describe('useScheduledMessageDraft', () => {
  beforeEach(() => {
    clearScheduledMessageDraft();
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-08-26T12:00:00Z'));
  });

  afterEach(() => {
    clearScheduledMessageDraft();
    vi.useRealTimers();
  });

  it('consumes a matching draft only once', () => {
    setScheduledMessageDraft({ ...context, body: 'Later' });

    expect(consumeScheduledMessageDraft(context)).toMatchObject({
      ...context,
      body: 'Later',
    });
    expect(consumeScheduledMessageDraft(context)).toBeNull();
  });

  it('invalidates a draft when another context attempts to consume it', () => {
    setScheduledMessageDraft({ ...context, body: 'Private draft' });

    expect(
      consumeScheduledMessageDraft({ ...context, conversationId: 99 })
    ).toBeNull();
    expect(consumeScheduledMessageDraft(context)).toBeNull();
  });

  it('invalidates an expired draft', () => {
    setScheduledMessageDraft({ ...context, body: 'Expired draft' });
    vi.advanceTimersByTime(2 * 60 * 1000 + 1);

    expect(consumeScheduledMessageDraft(context)).toBeNull();
  });

  it('does not expose a draft to another account with matching entity ids', () => {
    setScheduledMessageDraft({ ...context, body: 'Account-private draft' });

    expect(
      consumeScheduledMessageDraft({ ...context, accountId: 2 })
    ).toBeNull();
  });
});
