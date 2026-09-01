const startOfLocalDay = value => {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;

  date.setHours(0, 0, 0, 0);
  return date;
};

const addDays = (date, days) => {
  const next = new Date(date);
  next.setDate(next.getDate() + days);
  return next;
};

const addMonths = (date, months) => {
  const next = new Date(date);
  next.setMonth(next.getMonth() + months);
  return next;
};

export const TASK_TIME_BUCKETS = [
  'overdue',
  'today',
  'tomorrow',
  'nextWeek',
  'thisMonth',
  'future',
  'unscheduled',
];

const DEFAULT_VISIBLE_TASK_TIME_BUCKETS = ['today', 'tomorrow'];

export const visibleTaskTimeBuckets = groups =>
  TASK_TIME_BUCKETS.filter(
    bucket =>
      DEFAULT_VISIBLE_TASK_TIME_BUCKETS.includes(bucket) ||
      Boolean(groups?.[bucket]?.length)
  );

export const taskTimeBucket = (task, now = new Date()) => {
  if (task?.archivedAt || task?.completedAt) return null;

  const dueAt = task?.dueAt ? new Date(task.dueAt) : null;
  if (!dueAt || Number.isNaN(dueAt.getTime())) return 'unscheduled';

  const today = startOfLocalDay(now);
  const tomorrow = addDays(today, 1);
  const dayAfterTomorrow = addDays(today, 2);
  const nextWeekBoundary = addDays(today, 8);
  const nextMonthBoundary = addMonths(today, 1);

  if (dueAt < now) return 'overdue';
  if (dueAt < tomorrow) return 'today';
  if (dueAt < dayAfterTomorrow) return 'tomorrow';
  if (dueAt < nextWeekBoundary) return 'nextWeek';
  if (dueAt < nextMonthBoundary) return 'thisMonth';

  return 'future';
};

export const groupTasksByTime = (tasks, now = new Date()) => {
  const groups = Object.fromEntries(
    TASK_TIME_BUCKETS.map(bucket => [bucket, []])
  );

  (tasks || []).forEach(task => {
    const bucket = taskTimeBucket(task, now);
    if (bucket) groups[bucket].push(task);
  });

  Object.values(groups).forEach(items => {
    items.sort((left, right) => {
      const leftDueAt = left.dueAt ? new Date(left.dueAt).getTime() : Infinity;
      const rightDueAt = right.dueAt
        ? new Date(right.dueAt).getTime()
        : Infinity;
      return leftDueAt - rightDueAt || Number(left.id) - Number(right.id);
    });
  });

  return groups;
};
