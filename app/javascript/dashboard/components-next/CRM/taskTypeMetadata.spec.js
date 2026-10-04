import { describe, expect, it, vi } from 'vitest';
import { buildTaskTypeResolver } from './taskTypeMetadata';

const t = key => key;

describe('task type metadata', () => {
  it('uses the full catalogue, including renamed inactive types, before stale task summaries', () => {
    const resolve = buildTaskTypeResolver(
      [
        {
          id: 7,
          code: 'call',
          name: 'Renamed',
          icon: 'i-lucide-star',
          active: false,
        },
      ],
      t
    );
    const task = {
      taskTypeId: 7,
      activityType: 'call',
      taskType: { id: 7, name: 'Old', icon: 'i-lucide-phone' },
    };
    expect(resolve(task)).toEqual({ label: 'Renamed', icon: 'i-lucide-star' });
    expect(resolve(task)).toBe(resolve({ activityType: 'call' }));
  });

  it('falls back to a historical summary, then to translated legacy metadata', () => {
    const resolve = buildTaskTypeResolver([], t);
    expect(
      resolve({ taskType: { name: 'Historical', icon: 'i-lucide-mail' } })
    ).toEqual({ label: 'Historical', icon: 'i-lucide-mail' });
    expect(resolve({ activityType: 'call' })).toEqual({
      label: 'CRM.TASKS.ACTIVITY_TYPE.call',
      icon: 'i-lucide-phone',
    });
    expect(resolve({})).toEqual({
      label: 'CRM.TASKS.ACTIVITY_TYPE.task',
      icon: 'i-lucide-list-todo',
    });
    expect(resolve({ activityType: 'custom' }).label).toBe('custom');
  });

  it('does not accept arbitrary CSS classes from historical metadata', () => {
    const resolve = buildTaskTypeResolver([], t);
    expect(
      resolve({ taskType: { name: 'Bad icon', icon: 'fixed hidden' } }).icon
    ).toBe('i-lucide-list-todo');
  });

  it('indexes once rather than scanning the catalogue per task', () => {
    const types = [{ id: 7, code: 'task', name: 'Indexed' }];
    const scan = vi.spyOn(types, 'forEach');
    const resolve = buildTaskTypeResolver(types, t);
    Array.from({ length: 1000 }, () => resolve({ taskTypeId: 7 }));
    expect(scan).toHaveBeenCalledTimes(1);
  });
});
