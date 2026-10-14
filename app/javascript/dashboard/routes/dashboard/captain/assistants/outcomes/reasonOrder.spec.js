import { describe, expect, it } from 'vitest';
import {
  MAX_REASONS_PER_LIST,
  SYSTEM_REASON_ID,
  createCustomReason,
  insertReason,
  isSystemReason,
  isBuiltInReason,
  isReasonLocked,
  sortReasons,
} from './reasonOrder';

const reason = id => ({ id, label: id, active: true });
const ids = reasons => reasons.map(item => item.id);

describe('outcome reason ordering', () => {
  it('recognises only the other reason as the system reason', () => {
    expect(SYSTEM_REASON_ID).toBe('other');
    expect(isSystemReason(reason('other'))).toBe(true);
    expect(isSystemReason(reason('goal_achieved'))).toBe(false);
    expect(isSystemReason(null)).toBe(false);
  });

  it('keeps user reasons in their order and moves other to the end', () => {
    expect(
      ids(sortReasons([reason('other'), reason('b'), reason('a'), reason('c')]))
    ).toEqual(['b', 'a', 'c', 'other']);
    expect(
      ids(sortReasons([reason('b'), reason('other'), reason('a')]))
    ).toEqual(['b', 'a', 'other']);
  });

  it('leaves an already ordered list untouched and does not mutate the input', () => {
    const input = [reason('a'), reason('other')];
    const sorted = sortReasons(input);

    expect(ids(sorted)).toEqual(['a', 'other']);
    expect(sorted).not.toBe(input);
    expect(ids(input)).toEqual(['a', 'other']);
  });

  it('copes with empty and invalid lists', () => {
    expect(sortReasons([])).toEqual([]);
    expect(sortReasons(undefined)).toEqual([]);
    expect(sortReasons('nope')).toEqual([]);
  });

  it('inserts a new reason after the user reasons and before other', () => {
    const list = [reason('a'), reason('b'), reason('other')];
    const withNew = insertReason(list, reason('new_1'));

    expect(ids(withNew)).toEqual(['a', 'b', 'new_1', 'other']);
    expect(ids(insertReason(withNew, reason('new_2')))).toEqual([
      'a',
      'b',
      'new_1',
      'new_2',
      'other',
    ]);
    expect(ids(list)).toEqual(['a', 'b', 'other']);
  });

  it('inserts into a list that only has the system reason', () => {
    expect(ids(insertReason([reason('other')], reason('new_1')))).toEqual([
      'new_1',
      'other',
    ]);
    expect(ids(insertReason(undefined, reason('new_1')))).toEqual(['new_1']);
  });

  it('recognizes builtins independently from mandatory reasons', () => {
    [
      'goal_achieved',
      'question_resolved',
      'customer_declined',
      'no_response',
      'closed_against_instructions',
      'customer_requested_human',
      'low_confidence',
      'manual_action_required',
      'complaint_or_conflict',
      'tool_or_policy_limit',
      'faq_no_answer',
    ].forEach(id => {
      expect(isBuiltInReason(reason(id))).toBe(true);
      expect(isSystemReason(reason(id))).toBe(false);
      expect(isReasonLocked(reason(id))).toBe(false);
    });
    expect(isBuiltInReason(reason('other'))).toBe(true);
    expect(isReasonLocked(reason('other'))).toBe(true);
    expect(isBuiltInReason(reason('custom_handoff_1'))).toBe(false);
    expect(isBuiltInReason(null)).toBe(false);
    expect(isReasonLocked({ ...reason('faq_no_answer'), locked: true })).toBe(
      true
    );
    expect(isReasonLocked({ ...reason('faq_no_answer'), locked: false })).toBe(
      false
    );
  });

  it('treats a reason flagged builtin by the API as built in', () => {
    expect(isBuiltInReason({ id: 'clinic_specific', builtin: true })).toBe(
      true
    );
    expect(isBuiltInReason({ id: 'custom_handoff_1', builtin: false })).toBe(
      false
    );
    expect(isBuiltInReason({ id: 'goal_achieved', builtin: false })).toBe(true);
  });

  it('creates unique custom reasons that match the backend id pattern', () => {
    const first = createCustomReason('handoff');
    const second = createCustomReason('completion');

    expect(MAX_REASONS_PER_LIST).toBe(27);
    expect(first).toMatchObject({ label: '', enabled: true, builtin: false });
    expect(first.id).not.toBe(second.id);
    [first.id, second.id].forEach(id => {
      expect(id).toMatch(/^[a-z0-9][a-z0-9_-]{0,63}$/);
    });
    expect(isBuiltInReason(first)).toBe(false);
  });
});
