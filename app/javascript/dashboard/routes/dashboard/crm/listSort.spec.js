import { describe, expect, it } from 'vitest';

import { sortListRecords } from './listSort';

describe('sortListRecords', () => {
  const records = [
    { id: 3, amountMinor: 100, dueAt: '2026-03-03T10:00:00Z' },
    { id: 1, amountMinor: null, dueAt: null },
    { id: 2, amountMinor: 500, dueAt: '2026-03-01T10:00:00Z' },
  ];

  it('returns original records when sort state is empty', () => {
    expect(
      sortListRecords(records, { direction: '', key: '' }, record => record.id)
    ).toBe(records);
  });

  it('sorts ascending by numeric values', () => {
    const result = sortListRecords(
      records,
      { direction: 'asc', key: 'id' },
      (record, key) => record[key]
    );

    expect(result.map(record => record.id)).toEqual([1, 2, 3]);
  });

  it('sorts descending by numeric values', () => {
    const result = sortListRecords(
      records,
      { direction: 'desc', key: 'amountMinor' },
      (record, key) => record[key]
    );

    expect(result.map(record => record.id)).toEqual([2, 3, 1]);
  });

  it('keeps null values at the end', () => {
    const result = sortListRecords(
      records,
      { direction: 'asc', key: 'dueAt' },
      (record, key) => record[key] && new Date(record[key]).getTime()
    );

    expect(result.map(record => record.id)).toEqual([2, 3, 1]);
  });
});
