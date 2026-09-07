import { describe, expect, it, vi } from 'vitest';

import { formatCrmErrorMessage } from './shared';

describe('formatCrmErrorMessage', () => {
  it.each([
    [
      'UNSORTED_STAGE_REQUIRES_FALLBACK',
      'CRM.ERRORS.UNSORTED_STAGE_REQUIRES_FALLBACK',
    ],
    [
      'DEFAULT_STAGE_REQUIRES_FALLBACK',
      'CRM.ERRORS.DEFAULT_STAGE_REQUIRES_FALLBACK',
    ],
    ['IDEMPOTENCY_KEY_REUSED', 'CRM.ERRORS.IDEMPOTENCY_KEY_REUSED'],
    ['DEAL_TRANSITION_NOT_UNDOABLE', 'CRM.ERRORS.DEAL_TRANSITION_NOT_UNDOABLE'],
  ])('localizes %s', (code, translationKey) => {
    const t = vi.fn(key => `translated:${key}`);

    expect(formatCrmErrorMessage({ code, message: 'fallback' }, t)).toBe(
      `translated:${translationKey}`
    );
    expect(t).toHaveBeenCalledWith(translationKey);
  });
});
