import { describe, expect, it } from 'vitest';

import {
  canConfirmTaskCompletion,
  taskMatchesStateFilter,
} from './taskCompletion';

describe('task completion', () => {
  it('requires either result text or explicit confirmation', () => {
    expect(
      canConfirmTaskCompletion({
        confirmedWithoutNote: false,
        note: '   ',
        outcomeId: 1,
      })
    ).toBe(false);
    expect(
      canConfirmTaskCompletion({
        confirmedWithoutNote: false,
        note: 'Done',
        outcomeId: 1,
      })
    ).toBe(true);
    expect(
      canConfirmTaskCompletion({
        confirmedWithoutNote: true,
        note: '',
        outcomeId: 1,
      })
    ).toBe(true);
  });

  it('requires a configured outcome and a note when the outcome requires one', () => {
    expect(
      canConfirmTaskCompletion({
        confirmedWithoutNote: true,
        note: '',
        outcomeId: null,
      })
    ).toBe(false);
    expect(
      canConfirmTaskCompletion({
        confirmedWithoutNote: true,
        note: '',
        outcomeId: 1,
        requiresNote: true,
      })
    ).toBe(false);
    expect(
      canConfirmTaskCompletion({
        confirmedWithoutNote: false,
        note: 'Customer declined',
        outcomeId: 1,
        requiresNote: true,
      })
    ).toBe(true);
  });

  it('shows active tasks by default and allows completed tasks to be filtered', () => {
    const activeTask = { completedAt: null };
    const completedTask = { completedAt: '2026-08-29T10:00:00Z' };
    const cancelledTask = { cancelledAt: '2026-08-29T10:00:00Z' };

    expect(taskMatchesStateFilter(activeTask, 'active')).toBe(true);
    expect(taskMatchesStateFilter(completedTask, 'active')).toBe(false);
    expect(taskMatchesStateFilter(completedTask, 'completed')).toBe(true);
    expect(taskMatchesStateFilter(activeTask, 'completed')).toBe(false);
    expect(taskMatchesStateFilter(cancelledTask, 'active')).toBe(false);
    expect(taskMatchesStateFilter(cancelledTask, 'cancelled')).toBe(true);
    expect(taskMatchesStateFilter(activeTask, 'all')).toBe(true);
    expect(taskMatchesStateFilter(completedTask, 'all')).toBe(true);
  });
});
