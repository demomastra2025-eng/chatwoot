import { describe, expect, it } from 'vitest';

import { MAIN_AGENT_IN_USE, parseMainAgentInUseError } from './agentErrors';

const axiosError = (data, status = 422) => ({ response: { status, data } });

describe('parseMainAgentInUseError', () => {
  it('reads a top-level code with inbox ids and a message', () => {
    const error = axiosError({
      code: MAIN_AGENT_IN_USE,
      inbox_ids: [5, '8'],
      message: 'Агент главный в каналах',
    });

    expect(parseMainAgentInUseError(error)).toEqual({
      inboxIds: [5, 8],
      message: 'Агент главный в каналах',
    });
  });

  it('accepts the code under `error` or `error_code`', () => {
    expect(
      parseMainAgentInUseError(
        axiosError({ error: MAIN_AGENT_IN_USE, inbox_ids: [3] })
      )
    ).toEqual({ inboxIds: [3], message: '' });

    expect(
      parseMainAgentInUseError(
        axiosError({ error_code: MAIN_AGENT_IN_USE, inbox_ids: [4] })
      )
    ).toEqual({ inboxIds: [4], message: '' });
  });

  it('reads the code and the inbox ids from an errors list', () => {
    const error = axiosError({
      errors: [
        { code: 'OTHER', inbox_id: 1, message: 'Другая ошибка' },
        { code: MAIN_AGENT_IN_USE, inbox_ids: [5, 6], message: 'Занят' },
        { code: MAIN_AGENT_IN_USE, inbox_id: 6 },
        { code: MAIN_AGENT_IN_USE, inbox_id: 9 },
      ],
    });

    expect(parseMainAgentInUseError(error)).toEqual({
      inboxIds: [5, 6, 9],
      message: 'Занят',
    });
  });

  it('collects inbox ids from every listed error under a top-level code', () => {
    const error = axiosError({
      code: MAIN_AGENT_IN_USE,
      errors: [{ inbox_id: 2 }, { inbox_ids: [7] }],
    });

    expect(parseMainAgentInUseError(error).inboxIds).toEqual([2, 7]);
  });

  it('accepts a plain payload with a `data` key and drops invalid ids', () => {
    const error = {
      data: { code: MAIN_AGENT_IN_USE, inbox_ids: [null, 'x', 0, 11] },
    };

    expect(parseMainAgentInUseError(error)).toEqual({
      inboxIds: [11],
      message: '',
    });
  });

  it('returns null for other errors', () => {
    expect(parseMainAgentInUseError(null)).toBeNull();
    expect(parseMainAgentInUseError(new Error('Network Error'))).toBeNull();
    expect(
      parseMainAgentInUseError(axiosError({ message: 'Invalid name' }))
    ).toBeNull();
    expect(
      parseMainAgentInUseError(
        axiosError({ errors: [{ code: 'MAIN_AGENT_REQUIRED', inbox_id: 5 }] })
      )
    ).toBeNull();
    expect(parseMainAgentInUseError(axiosError('Server error'))).toBeNull();
  });
});
