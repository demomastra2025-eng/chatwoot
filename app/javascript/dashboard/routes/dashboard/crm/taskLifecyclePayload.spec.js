import { describe, expect, it } from 'vitest';

import {
  assertTaskEditCurrent,
  buildTaskReschedulePayload,
  changedTaskDetails,
  cloneTaskDraft,
  preferNewerRealtimeTask,
  rememberTaskSnapshot,
  taskAssignmentChanged,
  taskDetailsChanged,
  taskScheduleChanged,
} from './taskLifecyclePayload';

const task = {
  activityType: 'call',
  allDay: false,
  assigneeId: 7,
  customAttributes: { source: 'web' },
  dealId: 4,
  description: 'Call back',
  dueAt: '2026-09-05T10:30:00.000Z',
  dueOn: null,
  externalRef: null,
  originatingConversationId: 9,
  startAt: '2026-09-05T10:00:00.000Z',
  taskTypeId: 2,
  title: 'Follow up',
};

const form = {
  activityType: 'call',
  allDay: false,
  assigneeId: 7,
  customAttributes: { source: 'web' },
  dealId: 4,
  description: 'Call back',
  dueAt: '2026-09-05T10:30',
  externalRef: '',
  originatingConversationId: 9,
  startAt: '2026-09-05T10:00',
  title: 'Follow up',
};

describe('task lifecycle payload helpers', () => {
  it('uses lock_version before arrival sequence in both directions', () => {
    const v12 = { id: 1, lockVersion: 12 };
    const v11 = { id: 1, lockVersion: 11 };
    expect(preferNewerRealtimeTask(v12, { task: v11, sequence: 10 }, 1)).toBe(
      v12
    );
    expect(preferNewerRealtimeTask(v11, { task: v12, sequence: 1 }, 10)).toBe(
      v12
    );
  });

  it('keeps independent per-task versions and retains removal snapshots', () => {
    const snapshots = new Map();
    const removed = { id: 1, lockVersion: 12, archivedAt: '2026-09-05' };
    rememberTaskSnapshot(snapshots, removed, 3);
    rememberTaskSnapshot(snapshots, { id: 2, lockVersion: 1 }, 4);
    expect(rememberTaskSnapshot(snapshots, { id: 1, lockVersion: 10 })).toBe(
      removed
    );
    expect(snapshots.get(1).sequence).toBe(3);
    expect(snapshots.get(2).task.lockVersion).toBe(1);
  });

  it('captures an independent draft and sends only changed detail fields', () => {
    const payload = {
      title: 'Title',
      custom_attributes: { nested: { value: 1 } },
      assignee_id: 1,
      lock_version: 2,
    };
    const baseline = cloneTaskDraft(payload);
    payload.custom_attributes.nested.value = 2;
    expect(baseline.custom_attributes.nested.value).toBe(1);
    expect(
      changedTaskDetails(baseline, {
        ...baseline,
        title: 'New',
        assignee_id: 3,
        lock_version: 9,
      })
    ).toEqual({ title: 'New' });
    expect(() =>
      assertTaskEditCurrent(
        { id: 1, lockVersion: 2 },
        { id: 1, lockVersion: 3 }
      )
    ).toThrow('STALE_RECORD');
  });

  it('does not let an older mutation response overwrite realtime state', () => {
    const responseTask = { id: 1, title: 'HTTP response' };
    const realtimeTask = { id: 1, title: 'Realtime update' };

    expect(
      preferNewerRealtimeTask(
        responseTask,
        { sequence: 4, task: realtimeTask },
        3
      )
    ).toBe(realtimeTask);
    expect(
      preferNewerRealtimeTask(
        responseTask,
        { sequence: 3, task: realtimeTask },
        3
      )
    ).toBe(responseTask);
  });

  it('detects assignment, schedule and detail changes independently', () => {
    expect(taskAssignmentChanged(task, form.assigneeId)).toBe(false);
    expect(taskScheduleChanged(task, form)).toBe(false);
    expect(taskDetailsChanged(task, form, 2)).toBe(false);

    expect(taskAssignmentChanged(task, 8)).toBe(true);
    expect(
      taskScheduleChanged(task, { ...form, dueAt: '2026-09-06T10:30' })
    ).toBe(true);
    expect(taskDetailsChanged(task, { ...form, title: 'New title' }, 2)).toBe(
      true
    );
  });

  it('builds an explicit all-day reschedule command and clears timed fields', () => {
    const payload = buildTaskReschedulePayload(
      {
        ...form,
        allDay: true,
        dueAt: '2026-09-06',
      },
      3
    );

    expect(payload).toMatchObject({
      all_day: true,
      due_at: null,
      due_on: '2026-09-06',
      lock_version: 3,
      start_at: null,
    });
    expect(payload.idempotency_key).toEqual(expect.any(String));
  });
});
