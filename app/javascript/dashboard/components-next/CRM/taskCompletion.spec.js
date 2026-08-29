import { describe, expect, it } from 'vitest';

import {
  canConfirmTaskCompletion,
  completionOutcomeForTask,
  taskMatchesStateFilter,
} from './taskCompletion';

describe('task completion', () => {
  it('requires either result text or explicit confirmation', () => {
    expect(
      canConfirmTaskCompletion({ confirmedWithoutNote: false, note: '   ' })
    ).toBe(false);
    expect(
      canConfirmTaskCompletion({ confirmedWithoutNote: false, note: 'Done' })
    ).toBe(true);
    expect(
      canConfirmTaskCompletion({ confirmedWithoutNote: true, note: '' })
    ).toBe(true);
  });

  it.each([
    ['call', 'answered'],
    ['meeting', 'held'],
    ['message', 'sent'],
    ['task', 'completed'],
    ['touch', 'completed'],
  ])(
    'uses a valid completion outcome for %s tasks',
    (activityType, outcome) => {
      expect(completionOutcomeForTask({ activityType })).toBe(outcome);
    }
  );

  it('preserves the outcome when editing an already completed task', () => {
    expect(
      completionOutcomeForTask({
        activityType: 'call',
        completedAt: '2026-08-29T10:00:00Z',
        outcome: 'no_answer',
      })
    ).toBe('no_answer');
  });

  it('shows active tasks by default and allows completed tasks to be filtered', () => {
    const activeTask = { completedAt: null };
    const completedTask = { completedAt: '2026-08-29T10:00:00Z' };

    expect(taskMatchesStateFilter(activeTask, 'active')).toBe(true);
    expect(taskMatchesStateFilter(completedTask, 'active')).toBe(false);
    expect(taskMatchesStateFilter(completedTask, 'completed')).toBe(true);
    expect(taskMatchesStateFilter(activeTask, 'completed')).toBe(false);
    expect(taskMatchesStateFilter(activeTask, 'all')).toBe(true);
    expect(taskMatchesStateFilter(completedTask, 'all')).toBe(true);
  });
});
