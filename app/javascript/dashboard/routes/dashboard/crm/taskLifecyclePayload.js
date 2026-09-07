const normalizedId = value => {
  if (value === '' || value === null || value === undefined) return null;
  return Number(value);
};

const normalizedText = value => value || '';
const normalizedDateTimeInput = value => (value ? value.slice(0, 16) : '');

const taskLockVersion = task => normalizedId(task?.lockVersion);

export const newerTaskSnapshot = (candidate, current) => {
  if (!current || Number(candidate.id) !== Number(current.id)) return candidate;
  const currentVersion = taskLockVersion(current);
  const candidateVersion = taskLockVersion(candidate);
  if (
    currentVersion !== null &&
    (candidateVersion === null || candidateVersion < currentVersion)
  ) {
    return current;
  }
  return candidate;
};

// Keep accepted HTTP/Cable/list versions independently of an in-flight GET.
// Removed/filtered records stay here until the owning account/deal is reset.
export const rememberTaskSnapshot = (snapshots, task, sequence = 0) => {
  const id = Number(task.id);
  const previous = snapshots.get(id);
  const newest = newerTaskSnapshot(task, previous?.task);
  if (newest === task) {
    snapshots.set(id, {
      task,
      sequence: Math.max(sequence, previous?.sequence || 0),
    });
  }
  return newest;
};

export const cloneTaskDraft = value => JSON.parse(JSON.stringify(value));

export const assertTaskEditCurrent = (baseline, current) => {
  if (
    baseline &&
    Number(baseline.id) === Number(current?.id) &&
    taskLockVersion(baseline) === taskLockVersion(current)
  ) {
    return;
  }
  const error = new Error('STALE_RECORD');
  error.response = { data: { code: 'STALE_RECORD' } };
  throw error;
};

const commandFields = new Set([
  'all_day',
  'assignee_id',
  'due_at',
  'due_on',
  'idempotency_key',
  'lock_version',
  'schedule_timezone',
  'start_at',
  'status_id',
]);

export const changedTaskDetails = (baseline, requested) =>
  Object.fromEntries(
    Object.entries(requested).filter(
      ([key, value]) =>
        !commandFields.has(key) &&
        JSON.stringify(value) !== JSON.stringify(baseline[key])
    )
  );

export const preferNewerRealtimeTask = (
  responseTask,
  realtimeUpdate,
  realtimeSequenceAtStart
) => {
  if (
    taskLockVersion(responseTask) !== null ||
    taskLockVersion(realtimeUpdate?.task) !== null
  ) {
    return newerTaskSnapshot(responseTask, realtimeUpdate?.task);
  }
  return realtimeUpdate?.sequence > realtimeSequenceAtStart
    ? realtimeUpdate.task
    : responseTask;
};

export const taskAssignmentChanged = (task, assigneeId) =>
  normalizedId(task?.assigneeId) !== normalizedId(assigneeId);

export const taskScheduleChanged = (task, form) => {
  if (Boolean(task?.allDay) !== Boolean(form.allDay)) return true;

  const currentDue = task?.allDay
    ? normalizedText(task.dueOn)
    : normalizedDateTimeInput(task?.dueAt);
  if (currentDue !== normalizedText(form.dueAt)) return true;

  const currentStart = task?.allDay
    ? ''
    : normalizedDateTimeInput(task?.startAt);
  return currentStart !== (form.allDay ? '' : normalizedText(form.startAt));
};

export const taskDetailsChanged = (task, form, taskTypeId) => {
  const current = {
    activityType: normalizedText(task?.activityType || 'task'),
    contextKind: normalizedText(task?.contextKind),
    customAttributes: task?.customAttributes || {},
    dealId: normalizedId(task?.dealId),
    description: normalizedText(task?.description),
    externalRef: normalizedText(task?.externalRef),
    originatingConversationId: normalizedId(task?.originatingConversationId),
    taskTypeId: normalizedId(task?.taskTypeId),
    title: normalizedText(task?.title),
  };
  const requested = {
    activityType: normalizedText(form.activityType || 'task'),
    contextKind: normalizedText(form.contextKind),
    customAttributes: form.customAttributes || {},
    dealId: normalizedId(form.dealId),
    description: normalizedText(form.description),
    externalRef: normalizedText(form.externalRef),
    originatingConversationId: normalizedId(form.originatingConversationId),
    taskTypeId: normalizedId(taskTypeId),
    title: normalizedText(form.title).trim(),
  };

  return JSON.stringify(current) !== JSON.stringify(requested);
};

const taskScheduleAttributes = form => ({
  all_day: Boolean(form.allDay),
  due_at: form.allDay ? null : form.dueAt || null,
  due_on: form.allDay ? form.dueAt || null : null,
  start_at: form.allDay ? null : form.startAt || null,
});

export const buildTaskReschedulePayload = (form, lockVersion) => ({
  ...taskScheduleAttributes(form),
  idempotency_key: crypto.randomUUID(),
  lock_version: lockVersion,
});

// Keep the key across an ambiguous network failure, but never reuse it for
// a different draft. The server checks the receipt before the stale version.
export const buildTaskFormSavePayload = ({
  snapshot,
  currentTask,
  requested,
  form,
  includeStatus = false,
  preserveAllDay = false,
}) => {
  const task = snapshot?.task;
  if (!task) assertTaskEditCurrent(null, currentTask);
  const changes = changedTaskDetails(snapshot.payload, requested);
  if (taskAssignmentChanged(task, form.assigneeId)) {
    changes.assignee_id = normalizedId(form.assigneeId);
  }
  if (!(preserveAllDay && task.allDay) && taskScheduleChanged(task, form)) {
    Object.assign(changes, taskScheduleAttributes(form));
  }
  if (requested.schedule_timezone !== snapshot.payload.schedule_timezone) {
    changes.schedule_timezone = requested.schedule_timezone;
  }
  if (
    includeStatus &&
    normalizedId(form.statusId) !== normalizedId(task.statusId)
  ) {
    changes.status_id = normalizedId(form.statusId);
  }
  const payload = { ...changes, lock_version: task.lockVersion };
  const signature = JSON.stringify(payload);
  if (snapshot.formSave?.signature !== signature) {
    assertTaskEditCurrent(task, currentTask);
    snapshot.formSave = { signature, key: crypto.randomUUID() };
  }
  return { ...payload, idempotency_key: snapshot.formSave.key };
};
