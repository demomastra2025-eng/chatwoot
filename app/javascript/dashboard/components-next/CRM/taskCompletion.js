export const canConfirmTaskCompletion = ({
  confirmedWithoutNote,
  note,
  outcomeId = null,
  requiresNote = false,
}) => {
  if (!outcomeId) return false;
  if (requiresNote) return Boolean(String(note || '').trim());

  return Boolean(String(note || '').trim() || confirmedWithoutNote);
};

export const taskMatchesStateFilter = (task, state) => {
  if (state === 'all') return true;

  const isCompleted = Boolean(task?.completedAt);
  const isCancelled = Boolean(task?.cancelledAt);
  if (state === 'completed') return isCompleted;
  if (state === 'cancelled') return isCancelled;

  return !isCompleted && !isCancelled;
};
