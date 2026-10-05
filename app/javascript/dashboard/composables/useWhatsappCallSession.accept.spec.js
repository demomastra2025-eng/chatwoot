import { describe, expect, it } from 'vitest';

import { isCallTakenByAnotherAgentError } from './useWhatsappCallSession';

const serverError = (status, error) => ({
  response: { status, data: { error } },
});

describe('isCallTakenByAnotherAgentError', () => {
  it('recognises the refusal the server gives the agent who lost the race', () => {
    expect(
      isCallTakenByAnotherAgentError(
        serverError(422, 'Call already accepted by another agent')
      )
    ).toBe(true);
  });

  it('does not take other failures for a lost race', () => {
    expect(
      isCallTakenByAnotherAgentError(serverError(422, 'sdp_answer is required'))
    ).toBe(false);
    expect(
      isCallTakenByAnotherAgentError(serverError(500, 'Failed to accept call'))
    ).toBe(false);
    expect(isCallTakenByAnotherAgentError(new Error('boom'))).toBe(false);
    expect(isCallTakenByAnotherAgentError(undefined)).toBe(false);
  });
});
