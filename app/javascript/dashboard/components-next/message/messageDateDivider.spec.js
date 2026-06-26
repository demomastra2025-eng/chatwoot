import { describe, expect, it } from 'vitest';

import { formatMessageDateDivider, messageDateKey } from './messageDateDivider';

const t = key =>
  ({
    'CONVERSATION.DATE_DIVIDER.TODAY': 'Today',
    'CONVERSATION.DATE_DIVIDER.YESTERDAY': 'Yesterday',
  })[key] || key;

const atLocalNoon = (year, month, day) => new Date(year, month - 1, day, 12);

describe('messageDateDivider', () => {
  it('normalizes message timestamps to a local date key', () => {
    const date = atLocalNoon(2026, 6, 26);
    const timestamp = Math.floor(date.getTime() / 1000);

    expect(messageDateKey(timestamp)).toBe('2026-06-26');
  });

  it('uses Today and Yesterday labels for recent messages', () => {
    const now = atLocalNoon(2026, 6, 26);

    expect(formatMessageDateDivider(atLocalNoon(2026, 6, 26), { t, now })).toBe(
      'Today'
    );
    expect(formatMessageDateDivider(atLocalNoon(2026, 6, 25), { t, now })).toBe(
      'Yesterday'
    );
  });

  it('uses the weekday name inside the last week', () => {
    const now = atLocalNoon(2026, 6, 26);

    expect(
      formatMessageDateDivider(atLocalNoon(2026, 6, 24), {
        t,
        locale: 'en',
        now,
      })
    ).toBe('Wednesday');
  });

  it('uses a date for older messages and adds the year outside the current year', () => {
    const now = atLocalNoon(2026, 6, 26);

    expect(
      formatMessageDateDivider(atLocalNoon(2026, 5, 10), {
        t,
        locale: 'en',
        now,
      })
    ).toBe('May 10');
    expect(
      formatMessageDateDivider(atLocalNoon(2025, 12, 25), {
        t,
        locale: 'en',
        now,
      })
    ).toContain('2025');
  });

  it('accepts a vue-i18n locale ref', () => {
    expect(
      formatMessageDateDivider(atLocalNoon(2026, 6, 24), {
        t,
        locale: { value: 'en' },
        now: atLocalNoon(2026, 6, 26),
      })
    ).toBe('Wednesday');
  });
});
