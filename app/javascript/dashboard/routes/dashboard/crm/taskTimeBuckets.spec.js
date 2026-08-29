import { describe, expect, it } from 'vitest';

import {
  TASK_TIME_BUCKETS,
  groupTasksByTime,
  taskTimeBucket,
} from './taskTimeBuckets';

const now = new Date(2026, 7, 26, 12, 0, 0); // Wednesday
const at = (day, hour = 12) => new Date(2026, 7, day, hour, 0, 0).toISOString();

describe('taskTimeBucket', () => {
  it.each([
    [{ dueAt: at(25) }, 'overdue'],
    [{ dueAt: at(26, 9) }, 'overdue'],
    [{ dueAt: at(26, 23) }, 'today'],
    [{ dueAt: at(27) }, 'tomorrow'],
    [{ dueAt: at(28) }, 'thisWeek'],
    [{ dueAt: at(31) }, 'nextWeek'],
    [{ dueAt: new Date(2026, 8, 7).toISOString() }, 'later'],
    [{ dueAt: null }, 'unscheduled'],
  ])('assigns %o to %s', (task, expectedBucket) => {
    expect(taskTimeBucket(task, now)).toBe(expectedBucket);
  });

  it('does not put completed or archived tasks on the planning board', () => {
    expect(
      taskTimeBucket({ completedAt: at(26), dueAt: at(26) }, now)
    ).toBeNull();
    expect(
      taskTimeBucket({ archivedAt: at(26), dueAt: at(26) }, now)
    ).toBeNull();
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
});
