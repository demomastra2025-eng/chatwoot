import { describe, expect, it } from 'vitest';
import {
  activeExternalAssistants,
  knowledgeAccessPayload,
  knowledgeAssistantIds,
} from './assistantAccess';

describe('assistant access', () => {
  it('excludes inactive, internal and self as handoff or main agent choices', () => {
    expect(
      activeExternalAssistants(
        [
          { id: 1, active: true },
          { id: 2, active: false },
          { id: 3, usage_mode: 'internal_assistant' },
          { id: 4, active: true },
        ],
        1
      )
    ).toEqual([{ id: 4, active: true }]);
  });

  it('writes one shared material for several selected agents without a legacy owner', () => {
    expect(
      knowledgeAccessPayload('personal', [2, '4', 2, 0, 'invalid'])
    ).toEqual({
      visibility: 'personal',
      assistant_id: null,
      allowed_assistant_ids: [2, 4],
    });
    expect(knowledgeAccessPayload('general', [2, 4])).toEqual({
      visibility: 'general',
      assistant_id: null,
      allowed_assistant_ids: [],
    });
  });

  it('reads effective grants and falls back to an existing single owner', () => {
    expect(
      knowledgeAssistantIds({
        allowed_assistant_ids: [2, 4],
        assistant: { id: 9 },
      })
    ).toEqual([2, 4]);
    expect(knowledgeAssistantIds({ assistant: { id: 9 } })).toEqual([9]);
  });
});
