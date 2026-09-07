import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ query: {}, params: { accountId: 1 } }),
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));
vi.mock('dashboard/api/crm/tasks', () => ({
  default: Object.fromEntries(
    [
      'get',
      'show',
      'timeline',
      'create',
      'update',
      'saveForm',
      'assign',
      'reschedule',
      'changeStatus',
    ].map(key => [key, vi.fn()])
  ),
}));
vi.mock('dashboard/api/crm/deals', () => ({ default: { get: vi.fn() } }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key =>
    ref(
      {
        getCurrentAccountId: 1,
        getCurrentUser: { id: 1 },
        'agents/getAgents': [{ id: 1, name: 'Test agent' }],
      }[key]
    ),
  useStore: () => ({ dispatch: vi.fn() }),
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    taskStatuses: [{ id: 1, code: 'todo', category: 'open', default: true }],
    taskTypes: [
      { id: 10, code: 'task', name: 'Task', active: true, default: true },
    ],
    taskFieldDefinitions: [],
    loadTaskStatuses: vi.fn(),
    loadTaskTypes: vi.fn(),
    loadFieldDefinitions: vi.fn(),
  }),
}));

import CrmTasksAPI from 'dashboard/api/crm/tasks';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import CrmDealTasksPanel from 'dashboard/components-next/CRM/CrmDealTasksPanel.vue';
import CrmTasksPage from './pages/CrmTasksPage.vue';

const initialTask = {
  id: 7,
  accountId: 1,
  dealId: 4,
  lockVersion: 1,
  activityType: 'task',
  taskTypeId: 10,
  statusId: 1,
  title: 'Original',
  description: 'Description',
  assigneeId: 1,
  allDay: false,
  dueAt: null,
  dueOn: null,
  startAt: null,
  customAttributes: { nested: { value: 'original' } },
  externalRef: 'provider-ref',
};
const response = payload => ({ data: { payload } });
const deferred = () => {
  let resolve;
  const promise = new Promise(done => {
    resolve = done;
  });
  return { promise, resolve };
};
const publish = task =>
  emitter.emit(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, { account_id: 1, task });
const wrappers = [];
const mountEditor = async kind => {
  const wrapper = shallowMount(
    kind === 'panel' ? CrmDealTasksPanel : CrmTasksPage,
    {
      props:
        kind === 'panel'
          ? {
              deal: { id: 4, title: 'Deal' },
              canManageTasks: true,
              statuses: [
                { id: 1, code: 'todo', category: 'open', default: true },
              ],
              taskTypes: [{ id: 10, code: 'task', active: true }],
            }
          : {},
      global: {
        mocks: { $t: key => key },
        stubs: {
          Dialog: {
            name: 'Dialog',
            template: '<div />',
            methods: { open() {}, close() {} },
          },
        },
      },
    }
  );
  wrappers.push(wrapper);
  await flushPromises();
  return { wrapper, state: wrapper.vm.$.setupState };
};
const open = (kind, state) =>
  kind === 'panel'
    ? state.openTaskDialog(state.tasks[0])
    : state.openEditDrawer(state.tasks[0]);

beforeEach(() => {
  vi.clearAllMocks();
  localStorage.clear();
  CrmTasksAPI.get
    .mockReset()
    .mockResolvedValue(response([structuredClone(initialTask)]));
  CrmTasksAPI.timeline.mockReset().mockResolvedValue(response([]));
  CrmTasksAPI.update
    .mockReset()
    .mockResolvedValue(response({ ...initialTask, lockVersion: 2 }));
  CrmTasksAPI.saveForm
    .mockReset()
    .mockResolvedValue(response({ ...initialTask, lockVersion: 2 }));
  CrmTasksAPI.assign
    .mockReset()
    .mockResolvedValue(
      response({ ...initialTask, lockVersion: 2, assigneeId: 3 })
    );
  CrmDealsAPI.get.mockReset().mockResolvedValue(response([]));
});
afterEach(() => {
  wrappers.splice(0).forEach(wrapper => wrapper.unmount());
});

describe.each(['page', 'panel'])('%s task concurrency', kind => {
  it('normalizes the raw Cable envelope without losing custom-attribute keys', async () => {
    const { state } = await mountEditor(kind);
    publish({
      id: 7,
      account_id: 1,
      deal_id: 4,
      lock_version: 3,
      status_id: 1,
      title: 'Wire task',
      custom_attributes: { external_key: 'preserved' },
    });
    expect(state.tasks[0]).toMatchObject({
      id: 7,
      lockVersion: 3,
      title: 'Wire task',
      customAttributes: { external_key: 'preserved' },
    });
  });
  it('rejects older Cable after HTTP and keeps the highest version across GETs', async () => {
    const { state } = await mountEditor(kind);
    await state.runTaskMutation(() =>
      Promise.resolve(
        response({ ...initialTask, lockVersion: 12, title: 'HTTP 12' })
      )
    );
    publish({ ...initialTask, lockVersion: 11, title: 'Cable 11' });
    expect(state.tasks[0]).toMatchObject({
      lockVersion: 12,
      title: 'HTTP 12',
    });
    CrmTasksAPI.get.mockResolvedValueOnce(
      response([{ ...initialTask, lockVersion: 10, title: 'GET 10' }])
    );
    await state.loadTasks();
    publish({ ...initialTask, lockVersion: 11, title: 'Cable 11 again' });
    expect(state.tasks[0]).toMatchObject({
      lockVersion: 12,
      title: 'HTTP 12',
    });
  });

  it('keeps an HTTP mutation that arrives during a GET which omits the record', async () => {
    const { state } = await mountEditor(kind);
    const pending = deferred();
    CrmTasksAPI.get.mockReturnValueOnce(pending.promise);
    const loading = state.loadTasks();
    await state.runTaskMutation(() =>
      Promise.resolve(response({ ...initialTask, lockVersion: 12 }))
    );
    pending.resolve(response([]));
    await loading;
    expect(state.tasks[0].lockVersion).toBe(12);
  });

  it('does not resurrect an archived task from an older list response', async () => {
    const { state } = await mountEditor(kind);
    publish({
      ...initialTask,
      lockVersion: 3,
      archivedAt: '2026-09-05T10:00:00Z',
    });
    expect(state.tasks).toEqual([]);
    await state.loadTasks();
    expect(state.tasks).toEqual([]);
  });

  it('keeps the draft in a second editor and blocks stale writes before HTTP', async () => {
    const first = await mountEditor(kind);
    const second = await mountEditor(kind);
    await open(kind, first.state);
    await open(kind, second.state);
    second.state.form.title = 'My draft';
    publish({
      ...initialTask,
      lockVersion: 2,
      assigneeId: 2,
      title: 'Another editor',
    });
    await second.state.saveTask();
    expect(second.state.form.title).toBe('My draft');
    expect(second.state.taskEditSnapshot.task.lockVersion).toBe(1);
    expect(second.state.selectedTask.lockVersion).toBe(2);
    expect(CrmTasksAPI.update).not.toHaveBeenCalled();
    expect(CrmTasksAPI.assign).not.toHaveBeenCalled();
    expect(CrmTasksAPI.reschedule).not.toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalled();
  });

  it('sends only title with the original lock and preserves unowned external_ref', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Changed title';
    await state.saveTask();
    expect(CrmTasksAPI.saveForm).toHaveBeenCalledExactlyOnceWith(7, {
      title: 'Changed title',
      lock_version: 1,
      idempotency_key: expect.any(String),
    });
    expect(CrmTasksAPI.assign).not.toHaveBeenCalled();
    expect(CrmTasksAPI.reschedule).not.toHaveBeenCalled();
  });

  it('saves assignment-only edits as one atomic form command', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.assigneeId = 3;
    await state.saveTask();
    expect(CrmTasksAPI.update).not.toHaveBeenCalled();
    expect(CrmTasksAPI.saveForm).toHaveBeenCalledWith(
      7,
      expect.objectContaining({ assignee_id: 3, lock_version: 1 })
    );
    expect(CrmTasksAPI.reschedule).not.toHaveBeenCalled();
  });

  it('preserves the draft on a server-side conflict', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Keep this draft';
    CrmTasksAPI.saveForm.mockRejectedValueOnce({
      response: { data: { code: 'STALE_RECORD' } },
    });
    await state.saveTask();
    expect(state.form.title).toBe('Keep this draft');
    expect(state.taskEditSnapshot.task.lockVersion).toBe(1);
  });

  it('saves details and assignment together without overwriting a newer Cable state', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'My title';
    state.form.assigneeId = 3;
    const pending = deferred();
    CrmTasksAPI.saveForm.mockReturnValueOnce(pending.promise);
    const saving = state.saveTask();
    publish({ ...initialTask, lockVersion: 3, assigneeId: 4 });
    pending.resolve(
      response({ ...initialTask, lockVersion: 2, title: 'My title' })
    );
    await saving;
    expect(CrmTasksAPI.saveForm).toHaveBeenCalledExactlyOnceWith(7, {
      title: 'My title',
      assignee_id: 3,
      lock_version: 1,
      idempotency_key: expect.any(String),
    });
    expect(CrmTasksAPI.update).not.toHaveBeenCalled();
    expect(CrmTasksAPI.assign).not.toHaveBeenCalled();
    expect(state.tasks.find(task => task.id === 7)).toMatchObject({
      lockVersion: 3,
      assigneeId: 4,
    });
  });

  it('reuses the form command key when retrying the same draft after a network failure', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Retry me';
    CrmTasksAPI.saveForm.mockRejectedValueOnce(new Error('Network error'));
    await state.saveTask();
    const first = CrmTasksAPI.saveForm.mock.calls[0][1];
    await state.saveTask();
    expect(CrmTasksAPI.saveForm.mock.calls[1][1]).toEqual(first);
    expect(CrmTasksAPI.assign).not.toHaveBeenCalled();
    expect(CrmTasksAPI.reschedule).not.toHaveBeenCalled();
  });

  it('sends details, assignment and schedule in one request and blocks double submit', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Atomic';
    state.form.assigneeId = 3;
    state.form.dueAt = '2026-10-01T12:00';
    const pending = deferred();
    CrmTasksAPI.saveForm.mockReturnValueOnce(pending.promise);
    const first = state.saveTask();
    await state.saveTask();
    expect(CrmTasksAPI.saveForm).toHaveBeenCalledExactlyOnceWith(
      7,
      expect.objectContaining({
        title: 'Atomic',
        assignee_id: 3,
        due_at: '2026-10-01T12:00',
        lock_version: 1,
      })
    );
    pending.resolve(response({ ...initialTask, lockVersion: 2 }));
    await first;
    expect(CrmTasksAPI.update).not.toHaveBeenCalled();
    expect(CrmTasksAPI.assign).not.toHaveBeenCalled();
    expect(CrmTasksAPI.reschedule).not.toHaveBeenCalled();
    expect(CrmTasksAPI.changeStatus).not.toHaveBeenCalled();
  });
});

describe('page async drawer scope', () => {
  it('does not show old history or clear the new task loading state', async () => {
    const { state } = await mountEditor('page');
    const previous = deferred();
    const current = deferred();
    CrmTasksAPI.timeline
      .mockReturnValueOnce(previous.promise)
      .mockReturnValueOnce(current.promise);
    const first = state.openEditDrawer(initialTask);
    await flushPromises();
    const second = state.openEditDrawer({ ...initialTask, id: 8 });
    await flushPromises();

    previous.resolve(response([{ id: 'old-task-history' }]));
    await first;
    expect(state.timelineItems).toEqual([]);
    expect(state.ui.isTimelineLoading).toBe(true);
    current.resolve(response([{ id: 'current-task-history' }]));
    await second;
    expect(state.timelineItems).toEqual([{ id: 'current-task-history' }]);
    expect(state.ui.isTimelineLoading).toBe(false);
  });

  it('invalidates history even when returning to the same account and task', async () => {
    const { state } = await mountEditor('page');
    const previous = deferred();
    CrmTasksAPI.timeline.mockReturnValueOnce(previous.promise);
    const first = state.openEditDrawer(initialTask);
    await flushPromises();
    state.accountId = 2;
    await flushPromises();
    state.accountId = 1;
    await flushPromises();
    await state.openEditDrawer(initialTask);

    previous.resolve(response([{ id: 'obsolete-history' }]));
    await first;
    expect(state.timelineItems).toEqual([]);
    expect(state.ui.isTimelineLoading).toBe(false);
  });

  it('ignores old account deal options and create-prefill continuations', async () => {
    const { state } = await mountEditor('page');
    const previous = deferred();
    CrmDealsAPI.get.mockReturnValueOnce(previous.promise);
    const first = state.openCreateDrawer({ title: 'Account A draft' });
    state.accountId = 2;
    await flushPromises();
    CrmDealsAPI.get.mockResolvedValueOnce(
      response([{ id: 22, title: 'Account B deal' }])
    );
    await state.openCreateDrawer({ title: 'Account B draft' });

    previous.resolve(response([{ id: 11, title: 'Account A deal' }]));
    await first;
    expect(state.dealOptions).toEqual([{ value: 22, label: 'Account B deal' }]);
    expect(state.form.title).toBe('Account B draft');
  });

  it('does not publish pending drawer data after unmount', async () => {
    const { wrapper, state } = await mountEditor('page');
    const options = deferred();
    const timeline = deferred();
    CrmTasksAPI.timeline.mockReturnValueOnce(timeline.promise);
    const opening = state.openEditDrawer(initialTask);
    await flushPromises();
    CrmDealsAPI.get.mockReturnValueOnce(options.promise);
    const loading = state.loadDealOptions();
    wrapper.unmount();
    wrappers.splice(wrappers.indexOf(wrapper), 1);

    options.resolve(response([{ id: 11, title: 'Obsolete deal' }]));
    timeline.resolve(response([{ id: 'obsolete-history' }]));
    await Promise.all([opening, loading]);
    expect(state.timelineItems).toEqual([]);
    expect(state.dealOptions).toEqual([]);
  });
});

it('round-trips the cancelled preference through storage and page remount', async () => {
  const first = await mountEditor('page');
  first.state.filters.taskState = 'cancelled';
  first.state.persistTasksPreferences();
  await flushPromises();
  first.wrapper.unmount();
  wrappers.splice(wrappers.indexOf(first.wrapper), 1);
  const second = await mountEditor('page');
  expect(second.state.filters.taskState).toBe('cancelled');
});

it('keeps the inline title draft on a concurrent task update', async () => {
  const { state } = await mountEditor('page');
  state.startEditingTaskTitle(state.tasks[0]);
  state.taskTitleDraft = 'Inline draft';
  publish({ ...initialTask, lockVersion: 2, title: 'Other title' });
  await state.saveTaskTitle(state.tasks[0]);
  expect(CrmTasksAPI.update).not.toHaveBeenCalled();
  expect(state.taskTitleDraft).toBe('Inline draft');
});

it('does not apply a mutation response from the previous account', async () => {
  const { state } = await mountEditor('page');
  const pending = deferred();
  const updating = state.runTaskMutation(() => pending.promise);
  const rejected = expect(updating).rejects.toThrow('STALE_RECORD');
  CrmTasksAPI.get.mockResolvedValueOnce(response([]));
  state.accountId = 2;
  await flushPromises();
  pending.resolve(response({ ...initialTask, lockVersion: 2 }));
  await rejected;
  expect(state.tasks).toEqual([]);
});

it('drops a late list response after the deal scope is cleared', async () => {
  const { wrapper, state } = await mountEditor('panel');
  const pending = deferred();
  CrmTasksAPI.get.mockReturnValueOnce(pending.promise);
  const loading = state.loadTasks();
  await wrapper.setProps({ deal: null });
  pending.resolve(response([initialTask]));
  await loading;
  expect(state.tasks).toEqual([]);
  expect(state.selectedTask).toBeNull();
});
