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
    ['TASK_COMMAND_REQUIRED', 'CRM.ERRORS.TASK_COMMAND_REQUIRED'],
    ['DEAL_TRANSITION_NOT_UNDOABLE', 'CRM.ERRORS.DEAL_TRANSITION_NOT_UNDOABLE'],
  ])('localizes %s', (code, translationKey) => {
    const t = vi.fn(key => `translated:${key}`);

    expect(formatCrmErrorMessage({ code, message: 'fallback' }, t)).toBe(
      `translated:${translationKey}`
    );
    expect(t).toHaveBeenCalledWith(translationKey);
  });

  it('always returns a string for a native request error', () => {
    const t = vi.fn(key => `translated:${key}`);

    expect(formatCrmErrorMessage(new Error('Reload failed'), t)).toBe(
      'Reload failed'
    );
  });

  it('prefers the CRM response code over Axios transport metadata', () => {
    const t = vi.fn(key => `translated:${key}`);
    const error = {
      code: 'ERR_BAD_REQUEST',
      message: 'Request failed with status code 409',
      response: {
        data: { code: 'STALE_RECORD' },
        status: 409,
      },
    };

    expect(formatCrmErrorMessage(error, t)).toBe(
      'translated:CRM.ERRORS.STALE_RECORD'
    );
  });
});
