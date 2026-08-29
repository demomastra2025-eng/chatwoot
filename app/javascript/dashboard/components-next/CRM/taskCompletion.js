const COMPLETED_OUTCOME_BY_ACTIVITY_TYPE = {
  call: 'answered',
  meeting: 'held',
  message: 'sent',
  task: 'completed',
  touch: 'completed',
};

export const canConfirmTaskCompletion = ({ confirmedWithoutNote, note }) =>
  Boolean(String(note || '').trim() || confirmedWithoutNote);

export const completionOutcomeForTask = task =>
  (task?.completedAt && task?.outcome) ||
  COMPLETED_OUTCOME_BY_ACTIVITY_TYPE[task?.activityType || 'task'] ||
  'completed';

export const taskMatchesStateFilter = (task, state) => {
  if (state === 'all') return true;

  const isCompleted = Boolean(task?.completedAt);
  return state === 'completed' ? isCompleted : !isCompleted;
};
