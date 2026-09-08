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

const formatLocalDate = date => {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
};

export const taskDueDate = task => {
  if (task?.allDay && task?.dueOn) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(task.dueOn);
    if (!match) return null;

    const [, year, month, day] = match;
    const date = new Date(Number(year), Number(month) - 1, Number(day));
    if (
      Number.isNaN(date.getTime()) ||
      date.getFullYear() !== Number(year) ||
      date.getMonth() !== Number(month) - 1 ||
      date.getDate() !== Number(day)
    ) {
      return null;
    }

    return date;
  }

  const date = task?.dueAt ? new Date(task.dueAt) : null;
  return date && !Number.isNaN(date.getTime()) ? date : null;
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

export const taskDeadlineForBucket = (bucket, now = new Date()) => {
  if (bucket === 'unscheduled') {
    return { allDay: false, dueAt: null, dueOn: null, startAt: null };
  }

  const today = startOfLocalDay(now);
  const dayOffsets = {
    overdue: -1,
    today: 0,
    tomorrow: 1,
    nextWeek: 2,
    thisMonth: 8,
  };
  const targetDate =
    bucket === 'future'
      ? addMonths(today, 1)
      : addDays(today, dayOffsets[bucket] ?? 0);
  return {
    allDay: true,
    dueAt: null,
    dueOn: formatLocalDate(targetDate),
    startAt: null,
  };
};

export const taskTimeBucket = (task, now = new Date()) => {
  if (task?.archivedAt || task?.completedAt || task?.cancelledAt) return null;

  const dueDate = taskDueDate(task);
  if (!dueDate) return 'unscheduled';

  const today = startOfLocalDay(now);
  const tomorrow = addDays(today, 1);
  const dayAfterTomorrow = addDays(today, 2);
  const nextWeekBoundary = addDays(today, 8);
  const nextMonthBoundary = addMonths(today, 1);

  if (dueDate < (task.allDay ? today : now)) return 'overdue';
  if (dueDate < tomorrow) return 'today';
  if (dueDate < dayAfterTomorrow) return 'tomorrow';
  if (dueDate < nextWeekBoundary) return 'nextWeek';
  if (dueDate < nextMonthBoundary) return 'thisMonth';

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
      const leftDueAt = taskDueDate(left)?.getTime() ?? Infinity;
      const rightDueAt = taskDueDate(right)?.getTime() ?? Infinity;
      return leftDueAt - rightDueAt || Number(left.id) - Number(right.id);
    });
  });

  return groups;
};
