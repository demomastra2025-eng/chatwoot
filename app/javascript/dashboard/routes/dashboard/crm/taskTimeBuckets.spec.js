import { describe, expect, it } from 'vitest';

import {
  TASK_TIME_BUCKETS,
  formatTaskDueDate,
  groupTasksByTime,
  taskDeadlineForBucket,
  taskTimeBucket,
  visibleTaskTimeBuckets,
} from './taskTimeBuckets';

const now = new Date(2026, 7, 26, 12, 0, 0); // Wednesday
const at = (day, hour = 12) => new Date(2026, 7, day, hour, 0, 0).toISOString();

describe('taskTimeBucket', () => {
  it.each([
    [{ dueAt: at(25) }, 'overdue'],
    [{ dueAt: at(26, 9) }, 'overdue'],
    [{ dueAt: at(26, 23) }, 'today'],
    [{ dueAt: at(27) }, 'tomorrow'],
    [{ dueAt: at(28) }, 'nextWeek'],
    [{ dueAt: at(31) }, 'nextWeek'],
    [{ dueAt: new Date(2026, 8, 7).toISOString() }, 'thisMonth'],
    [{ dueAt: new Date(2026, 10, 1).toISOString() }, 'future'],
    [{ dueAt: null }, 'unscheduled'],
  ])('assigns %o to %s', (task, expectedBucket) => {
    expect(taskTimeBucket(task, now)).toBe(expectedBucket);
  });

  it('rejects impossible date-only deadlines instead of rolling them forward', () => {
    expect(taskTimeBucket({ allDay: true, dueOn: '2026-02-31' })).toBe(
      'unscheduled'
    );
  });

  it('does not put terminal or archived tasks on the planning board', () => {
    expect(
      taskTimeBucket({ completedAt: at(26), dueAt: at(26) }, now)
    ).toBeNull();
    expect(
      taskTimeBucket({ archivedAt: at(26), dueAt: at(26) }, now)
    ).toBeNull();
    expect(
      taskTimeBucket({ cancelledAt: at(26), dueAt: at(26) }, now)
    ).toBeNull();
  });

  it('keeps a date-only all-day task in today after noon has passed', () => {
    expect(
      taskTimeBucket(
        { allDay: true, dueOn: '2026-08-26' },
        new Date(2026, 7, 26, 18, 0, 0)
      )
    ).toBe('today');
  });
});

describe('formatTaskDueDate', () => {
  it('keeps all-day dueOn date-only while retaining time for timed tasks', () => {
    expect(formatTaskDueDate({ allDay: true, dueOn: '2026-09-23' })).toBe(
      'Sep 23, 2026'
    );
    expect(
      formatTaskDueDate({ dueAt: new Date(2026, 8, 23, 13, 30).toISOString() })
    ).toBe('Sep 23, 2026 13:30');
  });
});

describe('taskDeadlineForBucket', () => {
  it.each([
    ['today', 26],
    ['tomorrow', 27],
    ['nextWeek', 28],
  ])('builds an all-day deadline for %s', (bucket, expectedDay) => {
    const deadline = taskDeadlineForBucket(bucket, now);

    expect(deadline).toEqual({
      allDay: true,
      dueAt: null,
      dueOn: `2026-08-${expectedDay}`,
      startAt: null,
    });
  });

  it('clears the deadline when moved to unscheduled', () => {
    expect(taskDeadlineForBucket('unscheduled', now)).toEqual({
      allDay: false,
      dueAt: null,
      dueOn: null,
      startAt: null,
    });
  });

  it('uses the workspace date instead of the browser date', () => {
    expect(taskDeadlineForBucket('today', '2026-09-20').dueOn).toBe(
      '2026-09-20'
    );
    expect(taskDeadlineForBucket('tomorrow', '2026-09-20').dueOn).toBe(
      '2026-09-21'
    );
  });

  it('clamps a future workspace deadline to the last day of the next month', () => {
    expect(taskDeadlineForBucket('future', '2026-01-31').dueOn).toBe(
      '2026-02-28'
    );
  });
});

describe('groupTasksByTime', () => {
  it('keeps the fixed time groups and sorts tasks by due date', () => {
    const groups = groupTasksByTime(
      [
        { id: 2, dueAt: at(26, 18) },
        { id: 1, dueAt: at(26, 13) },
      ],
      now
    );

    expect(Object.keys(groups)).toEqual(TASK_TIME_BUCKETS);
    expect(groups.today.map(task => task.id)).toEqual([1, 2]);
  });

  it('keeps the authoritative server bucket across browser timezone boundaries', () => {
    const groups = groupTasksByTime(
      [{ boardTimeBucket: 'today', dueAt: at(27), id: 1 }],
      now
    );

    expect(groups.today.map(task => task.id)).toEqual([1]);
    expect(groups.tomorrow).toEqual([]);
  });
});

describe('visibleTaskTimeBuckets', () => {
  it('keeps only today and tomorrow visible when optional groups are empty', () => {
    const groups = groupTasksByTime([], now);

    expect(visibleTaskTimeBuckets(groups)).toEqual(['today', 'tomorrow']);
  });

  it('adds only non-empty optional groups in chronological board order', () => {
    const groups = groupTasksByTime(
      [
        { id: 1, dueAt: at(25) },
        { id: 2, dueAt: at(31) },
        { id: 3, dueAt: new Date(2026, 8, 7).toISOString() },
        { id: 4, dueAt: new Date(2026, 10, 1).toISOString() },
        { id: 5, dueAt: null },
      ],
      now
    );

    expect(visibleTaskTimeBuckets(groups)).toEqual([
      'overdue',
      'today',
      'tomorrow',
      'nextWeek',
      'thisMonth',
      'future',
      'unscheduled',
    ]);
  });
});
