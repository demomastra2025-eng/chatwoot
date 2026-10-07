import { describe, expect, it } from 'vitest';
import {
  SYSTEM_REASON_ID,
  insertReason,
  isSystemReason,
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
});
