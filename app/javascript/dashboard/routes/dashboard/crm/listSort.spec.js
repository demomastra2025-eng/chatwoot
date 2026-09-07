import { describe, expect, it } from 'vitest';

import {
  createDealListSortValueResolver,
  createTaskListSortValueResolver,
  sortListRecords,
} from './listSort';

describe('sortListRecords', () => {
  const records = [
    { id: 3, amount: '100', dueAt: '2026-03-03T10:00:00Z' },
    { id: 1, amount: null, dueAt: null },
    { id: 2, amount: '500', dueAt: '2026-03-01T10:00:00Z' },
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
      { direction: 'desc', key: 'amount' },
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

  it('sorts alphabetic values case-insensitively', () => {
    const result = sortListRecords(
      [
        { id: 1, title: 'beta' },
        { id: 2, title: 'Alpha' },
        { id: 3, title: 'gamma' },
      ],
      { direction: 'asc', key: 'title' },
      (record, key) => record[key].toLowerCase()
    );

    expect(result.map(record => record.id)).toEqual([2, 1, 3]);
  });
});

describe('createDealListSortValueResolver', () => {
  const resolveValue = createDealListSortValueResolver({
    ownerNameById: { 10: 'Mira Owner' },
    stageNameById: { 20: 'Qualified' },
  });

  it('resolves every visible deal list column', () => {
    const deal = {
      amount: '1200',
      id: 42,
      ownerId: 10,
      stageId: 20,
      title: '  Big Deal ',
      updatedAt: '2026-03-03T10:00:00Z',
    };

    expect(resolveValue(deal, 'id')).toBe(42);
    expect(resolveValue(deal, 'title')).toBe('big deal');
    expect(resolveValue(deal, 'stage')).toBe('qualified');
    expect(resolveValue(deal, 'amount')).toBe(1200);
    expect(resolveValue(deal, 'amountMinor')).toBe(1200);
    expect(resolveValue(deal, 'owner')).toBe('mira owner');
    expect(resolveValue(deal, 'updatedAt')).toBe(
      new Date('2026-03-03T10:00:00Z').getTime()
    );
  });
});

describe('createTaskListSortValueResolver', () => {
  const resolveValue = createTaskListSortValueResolver({
    activityTypeLabelByValue: { meeting: 'Meeting' },
    assigneeNameById: { 7: 'Nina Assignee' },
    statusNameById: { 8: 'In Progress' },
  });

  it('sorts task priorities by business rank instead of translated labels', () => {
    const tasks = [
      { id: 1, priority: 'urgent' },
      { id: 2, priority: 'low' },
      { id: 3, priority: 'high' },
      { id: 4, priority: 'none' },
    ];

    const result = sortListRecords(
      tasks,
      { direction: 'asc', key: 'priority' },
      resolveValue
    );

    expect(result.map(task => task.id)).toEqual([4, 2, 3, 1]);
  });

  it('resolves every visible task list column', () => {
    const task = {
      activityType: 'meeting',
      assigneeId: 7,
      dueAt: '2026-03-04T10:00:00Z',
      id: 77,
      priority: 'high',
      statusId: 8,
      title: '  Call Client ',
    };

    expect(resolveValue(task, 'id')).toBe(77);
    expect(resolveValue(task, 'activityType')).toBe('meeting');
    expect(resolveValue(task, 'title')).toBe('call client');
    expect(resolveValue(task, 'status')).toBe('in progress');
    expect(resolveValue(task, 'priority')).toBe(3);
    expect(resolveValue(task, 'assignee')).toBe('nina assignee');
    expect(resolveValue(task, 'dueAt')).toBe(
      new Date('2026-03-04T10:00:00Z').getTime()
    );
  });

  it('sorts an all-day task by its local date-only deadline', () => {
    const resolveTaskValue = createTaskListSortValueResolver();
    const task = { allDay: true, dueAt: null, dueOn: '2026-03-04' };

    expect(resolveTaskValue(task, 'dueAt')).toBe(
      new Date(2026, 2, 4).getTime()
    );
  });
});
