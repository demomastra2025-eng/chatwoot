import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

const { referencesStore, runtime, taskFieldDefinitions } = vi.hoisted(() => ({
  referencesStore: {
    loadFieldDefinitions: vi.fn(),
    loadTaskStatuses: vi.fn(),
    loadTaskTypes: vi.fn(),
    taskFieldDefinitions: [],
    taskStatuses: [
      { id: 1, code: 'todo', category: 'open', default: true },
      { id: 2, code: 'done', category: 'done' },
    ],
    taskTypes: [
      { id: 10, code: 'task', name: 'Task', active: true, default: true },
    ],
  },
  runtime: {
    accountId: null,
    dispatch: vi.fn(),
    routeQuery: {},
    routerReplace: vi.fn(),
  },
  taskFieldDefinitions: [],
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ locale: { value: 'en' }, t: key => key }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ query: runtime.routeQuery, params: { accountId: 1 } }),
  useRouter: () => ({ push: vi.fn(), replace: runtime.routerReplace }),
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
      'complete',
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
  useMapGetter: key => {
    const values = {
      getCurrentAccountId: runtime.accountId,
      getCurrentUser: ref({ id: 1 }),
      'agents/getAgents': ref([{ id: 1, name: 'Test agent' }]),
    };
    return values[key] || ref(null);
  },
  useStore: () => ({ dispatch: runtime.dispatch }),
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => referencesStore,
}));

import CrmTasksAPI from 'dashboard/api/crm/tasks';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import CrmDealTasksPanel from 'dashboard/components-next/CRM/CrmDealTasksPanel.vue';
import CrmTaskCompletionDialog from 'dashboard/components-next/CRM/CrmTaskCompletionDialog.vue';
import CrmTasksPage from './pages/CrmTasksPage.vue';

const initialTask = {
  id: 7,
  accountId: 1,
  contextKind: 'sales',
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
const response = payload => {
  const count = Array.isArray(payload)
    ? payload.length
    : Number(Boolean(payload));
  return {
    data: {
      meta: {
        as_of: '2026-09-19T10:00:00.000000Z',
        count,
        has_more: false,
        page: 1,
        per_page: 25,
      },
      payload,
    },
  };
};
const deferred = () => {
  let reject;
  let resolve;
  const promise = new Promise((done, fail) => {
    reject = fail;
    resolve = done;
  });
  return { promise, reject, resolve };
};
const publishTaskId = async taskId => {
  emitter.emit(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, {
    account_id: 1,
    task_id: taskId,
  });
  await flushPromises();
};
const publish = async task => {
  CrmTasksAPI.show.mockResolvedValue(response(task));
  await publishTaskId(task.id);
};
const wrappers = [];
const mountEditor = async (kind, extraProps = {}) => {
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
              ...extraProps,
            }
          : extraProps,
      global: {
        mocks: { $t: key => key },
        stubs: {
          CrmTaskCompletionDialog: {
            name: 'CrmTaskCompletionDialog',
            emits: ['close', 'confirm'],
            template: '<div />',
            methods: { open() {}, close() {} },
          },
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
  runtime.accountId ||= ref(1);
  runtime.accountId.value = 1;
  Object.keys(runtime.routeQuery).forEach(
    key => delete runtime.routeQuery[key]
  );
  runtime.routerReplace.mockReset().mockResolvedValue(undefined);
  runtime.dispatch.mockReset().mockResolvedValue(undefined);
  taskFieldDefinitions.splice(0);
  referencesStore.taskFieldDefinitions = taskFieldDefinitions;
  referencesStore.loadFieldDefinitions.mockResolvedValue([]);
  referencesStore.loadTaskStatuses.mockResolvedValue(
    referencesStore.taskStatuses
  );
  referencesStore.loadTaskTypes.mockResolvedValue(referencesStore.taskTypes);
  CrmTasksAPI.get
    .mockReset()
    .mockResolvedValue(response([structuredClone(initialTask)]));
  CrmTasksAPI.timeline.mockReset().mockResolvedValue(response([]));
  CrmTasksAPI.show
    .mockReset()
    .mockResolvedValue(response(structuredClone(initialTask)));
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
  CrmTasksAPI.complete.mockReset().mockResolvedValue(
    response({
      ...initialTask,
      lockVersion: 2,
      completedAt: '2026-09-09T12:00:00Z',
    })
  );
  CrmDealsAPI.get.mockReset().mockResolvedValue(response([]));
});
afterEach(() => {
  wrappers.splice(0).forEach(wrapper => wrapper.unmount());
});

it('renders a filtered-empty task list without a create action', async () => {
  const { state, wrapper } = await mountEditor('page');
  state.currentPresentation = 'list';
  state.listQuickFilters.q = 'missing task';
  state.tasks = [];
  await flushPromises();

  const emptyState = wrapper.findComponent({ name: 'SchedulingEmptyState' });
  expect(emptyState.props('description')).toBe('CRM.TASKS.LIST.EMPTY_FILTERED');
  expect(emptyState.props('actionLabel')).toBe('');
});

it('retries the complete task page bootstrap after references fail', async () => {
  referencesStore.loadTaskStatuses.mockRejectedValueOnce(
    new Error('statuses unavailable')
  );

  const { state, wrapper } = await mountEditor('page');

  expect(state.ui.isLoading).toBe(false);
  expect(state.ui.error).toBe('statuses unavailable');
  expect(wrapper.findComponent({ name: 'SchedulingErrorState' }).exists()).toBe(
    true
  );
  expect(CrmTasksAPI.get).not.toHaveBeenCalled();

  runtime.dispatch.mockClear();
  wrapper.findComponent({ name: 'SchedulingErrorState' }).vm.$emit('retry');
  await flushPromises();

  expect(referencesStore.loadTaskStatuses).toHaveBeenCalledTimes(2);
  expect(runtime.dispatch).toHaveBeenCalledWith('agents/get', {
    throwOnError: true,
  });
  expect(CrmTasksAPI.get).toHaveBeenCalled();
  expect(state.ui.error).toBeNull();
  expect(state.tasks.map(task => task.id)).toEqual([initialTask.id]);
});

it('ignores an obsolete task bootstrap failure after retry succeeds', async () => {
  const { state } = await mountEditor('page');
  const obsolete = deferred();
  referencesStore.loadTaskStatuses
    .mockReturnValueOnce(obsolete.promise)
    .mockResolvedValueOnce(referencesStore.taskStatuses);

  const firstRetry = state.initializeTasksPage();
  await flushPromises();
  await state.initializeTasksPage();
  obsolete.reject(new Error('obsolete bootstrap failed'));
  await firstRetry;

  expect(state.ui.isLoading).toBe(false);
  expect(state.ui.error).toBeNull();
  expect(state.tasks.map(task => task.id)).toEqual([initialTask.id]);
});

it('keeps task loading owned by a newer list request', async () => {
  const { state } = await mountEditor('page');
  state.currentPresentation = 'list';
  const bootstrapList = deferred();
  const currentList = deferred();
  CrmTasksAPI.get
    .mockReset()
    .mockReturnValueOnce(bootstrapList.promise)
    .mockReturnValueOnce(currentList.promise);

  const bootstrap = state.initializeTasksPage();
  await flushPromises();
  const current = state.loadTasks();
  bootstrapList.resolve(response([{ ...initialTask, id: 11 }]));
  await bootstrap;

  expect(state.ui.isLoading).toBe(true);
  currentList.resolve(response([{ ...initialTask, id: 22 }]));
  await current;
  expect(state.ui.isLoading).toBe(false);
  expect(state.tasks.map(task => task.id)).toEqual([22]);
});

it('only opens the newest route-query task when lookups finish in reverse', async () => {
  const { state } = await mountEditor('page');
  const obsolete = deferred();
  const current = deferred();
  CrmTasksAPI.show
    .mockReset()
    .mockReturnValueOnce(obsolete.promise)
    .mockReturnValueOnce(current.promise);

  runtime.routeQuery.taskId = '11';
  const firstAction = state.handleTaskUiActionQuery();
  runtime.routeQuery.taskId = '22';
  const secondAction = state.handleTaskUiActionQuery();
  current.resolve(response({ ...initialTask, id: 22 }));
  await secondAction;
  obsolete.resolve(response({ ...initialTask, id: 11 }));
  await firstAction;

  expect(state.selectedTask.id).toBe(22);
  expect(runtime.routerReplace).toHaveBeenCalledTimes(1);
});

it('does not publish a pending route-query task after an account switch', async () => {
  const { state, wrapper } = await mountEditor('page');
  const obsolete = deferred();
  const accountBootstrap = deferred();
  CrmTasksAPI.show.mockReset().mockReturnValueOnce(obsolete.promise);
  referencesStore.loadTaskStatuses.mockReturnValueOnce(
    accountBootstrap.promise
  );

  runtime.routeQuery.taskId = '11';
  const action = state.handleTaskUiActionQuery();
  runtime.accountId.value = 2;
  await flushPromises();
  obsolete.resolve(response({ ...initialTask, id: 11 }));
  await action;

  expect(state.selectedTask).toBeNull();
  expect(state.drawerOpen).toBe(false);
  expect(runtime.routerReplace).not.toHaveBeenCalled();
  wrapper.unmount();
  accountBootstrap.resolve(referencesStore.taskStatuses);
});

it('does not publish a pending route-query task after unmount', async () => {
  const { state, wrapper } = await mountEditor('page');
  const obsolete = deferred();
  CrmTasksAPI.show.mockReset().mockReturnValueOnce(obsolete.promise);

  runtime.routeQuery.taskId = '11';
  const action = state.handleTaskUiActionQuery();
  wrapper.unmount();
  obsolete.resolve(response({ ...initialTask, id: 11 }));
  await action;

  expect(state.selectedTask).toBeNull();
  expect(runtime.routerReplace).not.toHaveBeenCalled();
});

describe.each(['page', 'panel'])('%s task concurrency', kind => {
  it('uses bounded server pagination for the page list and complete paging in the deal panel', async () => {
    const { state } = await mountEditor(kind);
    if (kind === 'page') state.currentPresentation = 'list';
    CrmTasksAPI.get.mockReset();
    CrmTasksAPI.get
      .mockResolvedValueOnce({
        data: {
          payload: [structuredClone(initialTask)],
          meta: { count: 2, has_more: true, page: 1, per_page: 25 },
        },
      })
      .mockResolvedValueOnce({
        data: {
          payload: [{ ...initialTask, id: 8, title: 'Second page' }],
          meta: { has_more: false },
        },
      });

    await state.loadTasks();

    if (kind === 'page') {
      expect(state.tasks.map(task => task.id)).toEqual([7]);
      expect(state.tasksMeta).toMatchObject({ count: 2, page: 1, perPage: 25 });
      expect(CrmTasksAPI.get).toHaveBeenCalledTimes(1);
      expect(CrmTasksAPI.get).toHaveBeenCalledWith(
        expect.objectContaining({
          page: 1,
          per_page: 25,
          task_state: 'active',
        })
      );
    } else {
      expect(state.tasks.map(task => task.id)).toEqual([7, 8]);
      expect(CrmTasksAPI.get).toHaveBeenNthCalledWith(
        1,
        expect.objectContaining({ page: 1, per_page: 500 })
      );
      expect(CrmTasksAPI.get).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({ page: 2, per_page: 500 })
      );
    }
  });

  if (kind === 'page') {
    it('loads one bounded page per board time bucket and appends only the requested bucket', async () => {
      const { state } = await mountEditor(kind);
      state.currentPresentation = 'board';
      const dueAt = new Date();
      dueAt.setHours(12, 0, 0, 0);
      CrmTasksAPI.get.mockReset().mockImplementation(params => {
        const isToday = params.time_bucket === 'today';
        const payload = isToday
          ? [
              {
                ...initialTask,
                dueAt: dueAt.toISOString(),
                id: params.page === 2 ? 8 : 7,
              },
            ]
          : [];
        return Promise.resolve({
          data: {
            payload,
            meta: {
              as_of: '2026-09-19T10:00:00.000000Z',
              count: isToday ? 2 : 0,
              has_more: isToday && params.page === 1,
              page: params.page,
              per_page: 25,
            },
          },
        });
      });

      await state.loadTasks();

      expect(CrmTasksAPI.get).toHaveBeenCalledTimes(7);
      expect(
        CrmTasksAPI.get.mock.calls.map(([params]) => params.time_bucket)
      ).toEqual(
        expect.arrayContaining([
          'overdue',
          'today',
          'tomorrow',
          'nextWeek',
          'thisMonth',
          'future',
          'unscheduled',
        ])
      );
      expect(
        CrmTasksAPI.get.mock.calls.every(
          ([params]) => params.page === 1 && params.per_page === 25
        )
      ).toBe(true);
      expect(
        CrmTasksAPI.get.mock.calls
          .slice(1)
          .every(([params]) => params.as_of === '2026-09-19T10:00:00.000000Z')
      ).toBe(true);

      await state.loadMoreBoardBucket('today');

      expect(CrmTasksAPI.get).toHaveBeenLastCalledWith(
        expect.objectContaining({
          as_of: '2026-09-19T10:00:00.000000Z',
          page: 2,
          per_page: 25,
          time_bucket: 'today',
        })
      );
      expect(state.tasks.map(task => task.id)).toEqual([7, 8]);
    });

    it('loads and incrementally extends only the visible calendar range', async () => {
      const { state } = await mountEditor(kind);
      state.currentPresentation = 'calendar';
      state.filters.dateRange = {
        from: '2026-09-08T00:00:00Z',
        to: '2026-09-12T00:00:00Z',
      };
      CrmTasksAPI.get.mockReset();
      CrmTasksAPI.get
        .mockResolvedValueOnce({
          data: {
            payload: [
              {
                ...structuredClone(initialTask),
                dueAt: '2026-09-10T11:00:00Z',
                startAt: '2026-09-10T10:00:00Z',
              },
            ],
            meta: { count: 2, has_more: true, page: 1, per_page: 100 },
          },
        })
        .mockResolvedValueOnce({
          data: {
            payload: [
              {
                ...initialTask,
                dueAt: '2026-09-11T11:00:00Z',
                id: 8,
                startAt: '2026-09-11T10:00:00Z',
              },
            ],
            meta: { count: 2, has_more: false, page: 2, per_page: 100 },
          },
        });

      await state.loadTasks();

      expect(CrmTasksAPI.get).toHaveBeenCalledTimes(1);
      expect(CrmTasksAPI.get).toHaveBeenCalledWith(
        expect.objectContaining({
          calendar_from: expect.any(String),
          calendar_from_date: expect.any(String),
          calendar_to: expect.any(String),
          calendar_to_date: expect.any(String),
          due_from: '2026-09-08T00:00:00Z',
          due_to: '2026-09-12T00:00:00Z',
          page: 1,
          per_page: 100,
        })
      );

      await state.loadMoreCalendarTasks();

      expect(CrmTasksAPI.get).toHaveBeenLastCalledWith(
        expect.objectContaining({ page: 2, per_page: 100 })
      );
      expect(state.tasks.map(task => task.id)).toEqual([7, 8]);
      expect(state.tasksMeta.hasMore).toBe(false);
    });

    it('keeps the selected task state in bounded calendar requests', async () => {
      const { state } = await mountEditor(kind);
      state.currentPresentation = 'calendar';
      state.filters.taskState = 'completed';
      CrmTasksAPI.get.mockReset().mockResolvedValueOnce({
        data: {
          payload: [
            {
              ...structuredClone(initialTask),
              completedAt: '2026-09-19T09:00:00Z',
            },
          ],
          meta: { count: 1, has_more: false, page: 1, per_page: 100 },
        },
      });

      await state.loadTasks();

      expect(CrmTasksAPI.get).toHaveBeenCalledWith(
        expect.objectContaining({ task_state: 'completed' })
      );
      expect(state.tasks.map(task => task.id)).toEqual([initialTask.id]);
    });

    it('drops a late calendar page after the presentation reloads', async () => {
      const { state } = await mountEditor(kind);
      state.currentPresentation = 'calendar';
      CrmTasksAPI.get.mockReset().mockResolvedValueOnce({
        data: {
          payload: [structuredClone(initialTask)],
          meta: { count: 2, has_more: true, page: 1, per_page: 100 },
        },
      });
      await state.loadTasks();

      const pendingPage = deferred();
      CrmTasksAPI.get.mockReturnValueOnce(pendingPage.promise);
      const loadingMore = state.loadMoreCalendarTasks();
      state.currentPresentation = 'list';
      CrmTasksAPI.get.mockResolvedValue({
        data: {
          payload: [],
          meta: { count: 0, has_more: false, page: 1, per_page: 25 },
        },
      });
      await state.loadTasks();
      pendingPage.resolve({
        data: {
          payload: [{ ...initialTask, id: 8 }],
          meta: { count: 2, has_more: false, page: 2, per_page: 100 },
        },
      });
      await loadingMore;

      expect(state.tasks).toEqual([]);
    });

    it('does not let a stale board load overwrite newer calendar metadata', async () => {
      const { state } = await mountEditor(kind);
      const pendingBuckets = deferred();
      CrmTasksAPI.get.mockReset();
      CrmTasksAPI.get
        .mockResolvedValueOnce(response([structuredClone(initialTask)]))
        .mockReturnValue(pendingBuckets.promise);

      const boardLoad = state.loadTasks();
      await flushPromises();
      expect(CrmTasksAPI.get).toHaveBeenCalledTimes(7);

      state.currentPresentation = 'calendar';
      CrmTasksAPI.get.mockResolvedValueOnce({
        data: {
          payload: [structuredClone(initialTask)],
          meta: { count: 150, has_more: true, page: 1, per_page: 100 },
        },
      });
      await state.loadTasks();

      pendingBuckets.resolve(response([]));
      await boardLoad;

      expect(state.tasksMeta).toMatchObject({
        count: 150,
        hasMore: true,
        page: 1,
        perPage: 100,
      });
    });

    it('uses the server workspace date when a board drag changes the deadline', async () => {
      const { state } = await mountEditor(kind);
      state.boardAsOf = '2026-09-20T01:00:00.000000+14:00';
      CrmTasksAPI.reschedule.mockResolvedValueOnce(
        response({
          ...initialTask,
          allDay: true,
          dueOn: '2026-09-20',
          lockVersion: 2,
        })
      );

      await state.updateTaskDeadlineFromBoard({
        bucket: 'today',
        task: state.tasks[0],
      });

      expect(CrmTasksAPI.reschedule).toHaveBeenCalledWith(
        initialTask.id,
        expect.objectContaining({ all_day: true, due_on: '2026-09-20' })
      );
    });

    it('ignores another deadline intent while the same task mutation is pending', async () => {
      const { state } = await mountEditor(kind);
      const pendingReschedule = deferred();
      CrmTasksAPI.reschedule.mockReturnValueOnce(pendingReschedule.promise);

      const moving = state.updateTaskDeadlineFromBoard({
        bucket: 'today',
        task: state.tasks[0],
      });
      await flushPromises();
      await state.updateTaskDeadlineFromBoard({
        bucket: 'tomorrow',
        task: state.tasks[0],
      });

      expect(CrmTasksAPI.reschedule).toHaveBeenCalledTimes(1);
      expect(state.pendingTaskDeadlineIds.has(initialTask.id)).toBe(true);

      pendingReschedule.resolve(
        response({ ...initialTask, lockVersion: 2, dueOn: '2026-09-20' })
      );
      await moving;

      expect(state.pendingTaskDeadlineIds.has(initialTask.id)).toBe(false);
    });

    it('uses active unarchived filters when board restores terminal preferences', async () => {
      const { state } = await mountEditor(kind);
      state.filters.taskState = 'completed';
      state.filters.archived = true;
      CrmTasksAPI.get.mockReset().mockResolvedValue(
        response([
          {
            ...structuredClone(initialTask),
            completedAt: null,
          },
        ])
      );

      await state.loadTasks();

      expect(
        CrmTasksAPI.get.mock.calls.every(
          ([params]) =>
            params.task_state === 'active' && params.archived === false
        )
      ).toBe(true);
      expect(state.tasks.map(task => task.id)).toEqual([initialTask.id]);
    });

    it('rolls back a failed board move even when the recovery reload fails', async () => {
      const { state } = await mountEditor(kind);
      const previousTask = { ...state.tasks[0] };
      CrmTasksAPI.reschedule.mockRejectedValueOnce({
        response: { data: { code: 'STALE_RECORD' }, status: 409 },
      });
      CrmTasksAPI.get.mockReset().mockRejectedValue(new Error('reload failed'));

      await state.updateTaskDeadlineFromBoard({
        bucket: 'tomorrow',
        task: state.tasks[0],
      });

      expect(state.tasks[0]).toMatchObject({
        allDay: previousTask.allDay,
        boardTimeBucket: previousTask.boardTimeBucket,
        dueAt: previousTask.dueAt,
        dueOn: previousTask.dueOn,
        lockVersion: previousTask.lockVersion,
        startAt: previousTask.startAt,
      });
    });

    it('does not restore stale board state after newer realtime and failed reload', async () => {
      const { state } = await mountEditor(kind);
      const pendingMutation = deferred();
      CrmTasksAPI.reschedule.mockReturnValueOnce(pendingMutation.promise);

      const moving = state.updateTaskDeadlineFromBoard({
        bucket: 'tomorrow',
        task: state.tasks[0],
      });
      await flushPromises();

      state.applyTaskRealtimeState({
        ...structuredClone(initialTask),
        dueAt: '2026-09-22T11:00:00Z',
        lockVersion: 2,
        startAt: '2026-09-22T10:00:00Z',
      });
      CrmTasksAPI.get.mockReset().mockRejectedValue(new Error('reload failed'));
      pendingMutation.reject({
        response: { data: { code: 'STALE_RECORD' }, status: 409 },
      });
      await moving;

      expect(state.tasks).toEqual([]);
    });
  }

  it('normalizes the scoped refresh response without losing custom-attribute keys', async () => {
    const { state } = await mountEditor(kind);
    await publish({
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
    await publish({ ...initialTask, lockVersion: 11, title: 'Cable 11' });
    expect(state.tasks[0]).toMatchObject({
      lockVersion: 12,
      title: 'HTTP 12',
    });
    CrmTasksAPI.get.mockResolvedValueOnce(
      response([{ ...initialTask, lockVersion: 10, title: 'GET 10' }])
    );
    await state.loadTasks();
    await publish({ ...initialTask, lockVersion: 11, title: 'Cable 11 again' });
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
    await publish({
      ...initialTask,
      lockVersion: 3,
      archivedAt: '2026-09-05T10:00:00Z',
    });
    expect(state.tasks).toEqual([]);
    await state.loadTasks();
    expect(state.tasks).toEqual([]);
  });

  it('removes a task that is no longer visible after an opaque Cable refresh', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    CrmTasksAPI.show.mockRejectedValueOnce({ response: { status: 404 } });
    CrmTasksAPI.get.mockClear().mockResolvedValue(response([]));

    await publishTaskId(initialTask.id);

    expect(state.tasks).toEqual([]);
    expect(state.selectedTask).toBeNull();
    if (kind === 'page') {
      expect(CrmTasksAPI.get).toHaveBeenCalledTimes(7);
      expect(state.boardBucketMeta.today.count).toBe(0);
    }
  });

  it('does not publish a stale list or leave loading active after realtime access loss', async () => {
    const { state } = await mountEditor(kind);
    const pending = deferred();
    CrmTasksAPI.get.mockReturnValueOnce(pending.promise);
    const loading = state.loadTasks();
    CrmTasksAPI.show.mockRejectedValueOnce({ response: { status: 404 } });
    CrmTasksAPI.get.mockResolvedValue(response([]));

    await publishTaskId(initialTask.id);
    expect(state.ui.isLoading).toBe(false);
    pending.resolve(response([initialTask]));
    await loading;

    expect(state.tasks).toEqual([]);
    expect(state.ui.isLoading).toBe(false);
  });

  it('ignores realtime events from another account', async () => {
    const { state } = await mountEditor(kind);

    emitter.emit(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, {
      account_id: 2,
      task_id: initialTask.id,
    });
    await flushPromises();

    expect(CrmTasksAPI.show).not.toHaveBeenCalled();
    expect(state.tasks[0].title).toBe('Original');
  });

  it('keeps list loading bounded when realtime completes during the request', async () => {
    const { state } = await mountEditor(kind);
    const pending = deferred();
    CrmTasksAPI.get.mockReturnValueOnce(pending.promise);
    const loading = state.loadTasks();

    await publish({ ...initialTask, lockVersion: 2, title: 'Realtime' });
    expect(state.ui.isLoading).toBe(true);
    pending.resolve(response([{ ...initialTask, lockVersion: 1 }]));
    await loading;

    expect(state.ui.isLoading).toBe(false);
    expect(state.tasks[0]).toMatchObject({ lockVersion: 2, title: 'Realtime' });
  });

  it('drops a realtime continuation after unmount', async () => {
    const { wrapper, state } = await mountEditor(kind);
    const pending = deferred();
    const listRequestsBeforeEvent = CrmTasksAPI.get.mock.calls.length;
    CrmTasksAPI.show.mockReturnValueOnce(pending.promise);
    emitter.emit(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, {
      account_id: 1,
      task_id: initialTask.id,
    });
    await flushPromises();

    wrapper.unmount();
    wrappers.splice(wrappers.indexOf(wrapper), 1);
    pending.resolve(
      response({ ...initialTask, lockVersion: 3, title: 'After unmount' })
    );
    await flushPromises();

    expect(state.tasks[0].title).toBe('Original');
    expect(CrmTasksAPI.get).toHaveBeenCalledTimes(listRequestsBeforeEvent);
  });

  it('rebases a stale draft and retries without overwriting unrelated changes', async () => {
    const first = await mountEditor(kind);
    const second = await mountEditor(kind);
    await open(kind, first.state);
    await open(kind, second.state);
    second.state.form.title = 'My draft';
    await publish({
      ...initialTask,
      lockVersion: 2,
      assigneeId: 2,
      title: 'Another editor',
    });
    await second.state.saveTask();
    expect(second.state.form.title).toBe('My draft');
    expect(second.state.taskEditSnapshot.task).toMatchObject({
      assigneeId: 1,
      lockVersion: 2,
      title: 'Original',
    });
    expect(second.state.selectedTask.lockVersion).toBe(2);
    expect(second.state.taskConflict).toMatchObject({
      active: true,
      hasAuthoritative: true,
      reloadFailed: false,
    });
    expect(CrmTasksAPI.update).not.toHaveBeenCalled();
    expect(CrmTasksAPI.assign).not.toHaveBeenCalled();
    expect(CrmTasksAPI.reschedule).not.toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalled();

    await second.state.saveTask();

    expect(CrmTasksAPI.saveForm).toHaveBeenCalledExactlyOnceWith(7, {
      title: 'My draft',
      lock_version: 2,
      idempotency_key: expect.any(String),
    });
  });

  it('keeps the stale draft when the authoritative reload fails', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Unsaved draft';
    state.selectedTask = { ...state.selectedTask, lockVersion: 2 };
    CrmTasksAPI.show.mockRejectedValueOnce(new Error('reload failed'));

    await state.saveTask();

    expect(state.form.title).toBe('Unsaved draft');
    expect(state.taskEditSnapshot.task.lockVersion).toBe(1);
    expect(state.taskConflict).toMatchObject({
      active: true,
      hasAuthoritative: false,
      reloadFailed: true,
    });
    expect(CrmTasksAPI.saveForm).not.toHaveBeenCalled();
  });

  it('ignores a conflict reload that finishes after the editor closes', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Unsaved draft';
    state.selectedTask = { ...state.selectedTask, lockVersion: 2 };
    const reload = deferred();
    CrmTasksAPI.show.mockReturnValueOnce(reload.promise);
    useAlert.mockClear();

    const saving = state.saveTask();
    await flushPromises();
    expect(state.taskConflict.isReloading).toBe(true);

    if (kind === 'panel') state.closeTaskDialog();
    else state.closeDrawer();
    state.selectedTask = { ...initialTask, id: 8, title: 'Reopened task' };
    reload.resolve(response({ ...initialTask, lockVersion: 2 }));
    await saving;

    expect(state.selectedTask).toMatchObject({ id: 8, title: 'Reopened task' });
    expect(state.taskEditSnapshot).toBeNull();
    expect(state.taskConflict).toMatchObject({
      active: false,
      hasAuthoritative: false,
      isReloading: false,
    });
    expect(useAlert).not.toHaveBeenCalled();
  });

  it('invalidates a pending conflict reload when the editor unmounts', async () => {
    const { state, wrapper } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Unsaved draft';
    state.selectedTask = { ...state.selectedTask, lockVersion: 2 };
    const reload = deferred();
    CrmTasksAPI.show.mockReturnValueOnce(reload.promise);
    useAlert.mockClear();

    const saving = state.saveTask();
    await flushPromises();
    wrapper.unmount();
    wrappers.splice(wrappers.indexOf(wrapper), 1);
    reload.resolve(response({ ...initialTask, lockVersion: 2 }));
    await saving;

    expect(state.taskConflict).toMatchObject({
      active: false,
      hasAuthoritative: false,
      isReloading: false,
    });
    expect(useAlert).not.toHaveBeenCalled();
  });

  it('ignores a late stale mutation after reopening another task', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Unsaved draft';
    const mutation = deferred();
    CrmTasksAPI.saveForm.mockReturnValueOnce(mutation.promise);
    CrmTasksAPI.show.mockClear();
    useAlert.mockClear();

    const saving = state.saveTask();
    await flushPromises();
    if (kind === 'panel') state.closeTaskDialog();
    else state.closeDrawer();
    state.selectedTask = { ...initialTask, id: 8, title: 'Reopened task' };
    mutation.reject({
      response: { data: { code: 'STALE_RECORD' }, status: 409 },
    });
    await saving;

    expect(CrmTasksAPI.show).not.toHaveBeenCalled();
    expect(state.selectedTask).toMatchObject({ id: 8, title: 'Reopened task' });
    expect(state.taskConflict.active).toBe(false);
    expect(state.ui.isSaving).toBe(false);
    expect(useAlert).not.toHaveBeenCalled();
  });

  it('ignores a late successful mutation after reopening the same task', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'First draft';
    const mutation = deferred();
    CrmTasksAPI.saveForm.mockReturnValueOnce(mutation.promise);
    useAlert.mockClear();

    const saving = state.saveTask();
    await flushPromises();
    if (kind === 'panel') state.closeTaskDialog();
    else state.closeDrawer();
    state.selectedTask = { ...initialTask, title: 'Reopened draft' };
    state.form.title = 'Reopened draft';
    mutation.resolve(
      response({ ...initialTask, lockVersion: 2, title: 'Late success' })
    );
    await saving;

    expect(state.selectedTask.title).toBe('Reopened draft');
    expect(state.form.title).toBe('Reopened draft');
    expect(state.taskConflict.active).toBe(false);
    expect(state.ui.isSaving).toBe(false);
    expect(useAlert).not.toHaveBeenCalled();
  });

  it('ignores a late stale mutation after unmount', async () => {
    const { state, wrapper } = await mountEditor(kind);
    await open(kind, state);
    state.form.title = 'Unsaved draft';
    const mutation = deferred();
    CrmTasksAPI.saveForm.mockReturnValueOnce(mutation.promise);
    CrmTasksAPI.show.mockClear();
    useAlert.mockClear();

    const saving = state.saveTask();
    await flushPromises();
    wrapper.unmount();
    wrappers.splice(wrappers.indexOf(wrapper), 1);
    mutation.reject({
      response: { data: { code: 'STALE_RECORD' }, status: 409 },
    });
    await saving;

    expect(CrmTasksAPI.show).not.toHaveBeenCalled();
    expect(state.taskConflict.active).toBe(false);
    expect(state.ui.isSaving).toBe(false);
    expect(useAlert).not.toHaveBeenCalled();
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

  it('omits an unselected outcome instead of sending a synthetic ID', async () => {
    const { state } = await mountEditor(kind);
    await open(kind, state);

    if (kind === 'panel') {
      await state.saveTaskResult({
        task: state.tasks[0],
        note: '',
        taskOutcomeId: '',
      });
    } else {
      await state.saveTaskCompletion({
        task: state.tasks[0],
        note: '',
        taskOutcomeId: '',
      });
    }

    expect(CrmTasksAPI.complete).toHaveBeenCalledWith(
      7,
      expect.not.objectContaining({ task_outcome_id: expect.anything() })
    );
  });

  it('ignores a late task completion after the result dialog closes', async () => {
    const extraProps =
      kind === 'panel'
        ? {
            statuses: [
              { id: 1, code: 'todo', category: 'open', default: true },
              { id: 2, code: 'done', category: 'done' },
            ],
          }
        : {};
    const { state, wrapper } = await mountEditor(kind, extraProps);
    const pending = deferred();
    if (kind === 'panel') {
      state.openTaskResultDialog(state.tasks[0]);
    } else {
      state.openTaskCompletionDialog(state.tasks[0]);
    }
    CrmTasksAPI.complete.mockReturnValueOnce(pending.promise);
    useAlert.mockClear();

    const payload = {
      task: state.tasks[0],
      note: 'Done',
      taskOutcomeId: '',
    };
    const saving =
      kind === 'panel'
        ? state.saveTaskResult(payload)
        : state.saveTaskCompletion(payload);
    await flushPromises();
    if (kind === 'panel') {
      state.invalidateTaskResultDialog();
    } else {
      state.invalidateTaskCompletionDialog();
    }
    pending.resolve(
      response({
        ...initialTask,
        lockVersion: 2,
        completedAt: '2026-09-09T12:00:00Z',
      })
    );
    await saving;

    expect(state.tasks[0].completedAt).toBeUndefined();
    expect(wrapper.emitted('updated')).toBeUndefined();
    expect(state.ui.isSaving).toBe(false);
    expect(useAlert).not.toHaveBeenCalled();
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
    await publish({ ...initialTask, lockVersion: 3, assigneeId: 4 });
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
    expect(state.form.title).toBe('My title');
    expect(state.selectedTask).toMatchObject({ lockVersion: 3, assigneeId: 4 });
    expect(state.taskConflict).toMatchObject({
      active: true,
      hasAuthoritative: true,
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
  it('does not invent a noon deadline when switching an all-day task to timed mode', async () => {
    const { state } = await mountEditor('page');
    await open('page', state);
    state.form.allDay = true;
    state.form.dueAt = '2026-10-01';

    state.updateAllDay(false);

    expect(state.form.allDay).toBe(false);
    expect(state.form.dueAt).toBe('');
  });

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

  it('shows a retryable history error and clears it after a successful retry', async () => {
    const { state } = await mountEditor('page');
    CrmTasksAPI.timeline.mockRejectedValueOnce(
      new Error('task history unavailable')
    );

    await state.openEditDrawer(initialTask);

    expect(state.timelineItems).toEqual([]);
    expect(state.ui.timelineError).toBe('task history unavailable');
    expect(state.ui.isTimelineLoading).toBe(false);

    CrmTasksAPI.timeline.mockResolvedValueOnce(
      response([{ id: 'restored-task-history' }])
    );
    await state.loadTimeline(initialTask.id);

    expect(state.ui.timelineError).toBeNull();
    expect(state.timelineItems).toEqual([{ id: 'restored-task-history' }]);
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

it('propagates completion dialog close events to its parent', async () => {
  const wrapper = shallowMount(CrmTaskCompletionDialog, {
    props: { taskTypes: [] },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Dialog: {
          name: 'Dialog',
          emits: ['close', 'confirm'],
          template: '<div />',
        },
      },
    },
  });
  wrappers.push(wrapper);

  wrapper.findComponent({ name: 'Dialog' }).vm.$emit('close');
  await flushPromises();

  expect(wrapper.emitted('close')).toHaveLength(1);
});

it('requests the selected list page with server search and stable sort params', async () => {
  const { state } = await mountEditor('page');
  state.currentPresentation = 'list';
  state.listQuickFilters.q = 'needle';
  state.listSort = { direction: 'desc', key: 'title' };
  CrmTasksAPI.get.mockReset().mockResolvedValue({
    data: {
      payload: [{ ...initialTask, id: 8, title: 'Needle' }],
      meta: { count: 26, has_more: false, page: 2, per_page: 25 },
    },
  });

  await state.handleListPageChange(2);

  expect(CrmTasksAPI.get).toHaveBeenCalledExactlyOnceWith(
    expect.objectContaining({
      page: 2,
      per_page: 25,
      q: 'needle',
      sort_by: 'title',
      sort_direction: 'desc',
      task_state: 'active',
    })
  );
  expect(state.tasks.map(task => task.id)).toEqual([8]);
  expect(state.tasksMeta).toMatchObject({ count: 26, page: 2, perPage: 25 });
});

it('sends the localized checked value as a typed custom-field search flag', async () => {
  const { state } = await mountEditor('page');
  state.currentPresentation = 'list';
  state.listQuickFilters.q = 'CHOICE_TOGGLE.YES';
  CrmTasksAPI.get.mockReset().mockResolvedValue({
    data: {
      payload: [],
      meta: { count: 0, has_more: false, page: 1, per_page: 25 },
    },
  });

  await state.loadTasks();

  expect(CrmTasksAPI.get).toHaveBeenCalledWith(
    expect.objectContaining({
      q: 'CHOICE_TOGGLE.YES',
      q_checked: true,
    })
  );
});

it('resets a non-empty quick search with one authoritative request', async () => {
  const { state } = await mountEditor('page');
  state.currentPresentation = 'list';
  vi.useFakeTimers();

  try {
    state.listQuickFilters.q = 'needle';
    await flushPromises();
    CrmTasksAPI.get.mockReset().mockResolvedValue({
      data: {
        payload: [],
        meta: { count: 0, has_more: false, page: 1, per_page: 25 },
      },
    });

    await state.resetFilters();
    await vi.advanceTimersByTimeAsync(350);

    expect(CrmTasksAPI.get).toHaveBeenCalledTimes(1);
    expect(CrmTasksAPI.get).toHaveBeenCalledWith(
      expect.objectContaining({ page: 1, per_page: 25 })
    );
  } finally {
    vi.useRealTimers();
  }
});

it('refetches the last valid list page when the current page becomes empty', async () => {
  const { state } = await mountEditor('page');
  state.currentPresentation = 'list';
  state.listCurrentPage = 2;
  CrmTasksAPI.get
    .mockReset()
    .mockResolvedValueOnce({
      data: {
        payload: [],
        meta: { count: 25, has_more: false, page: 2, per_page: 25 },
      },
    })
    .mockResolvedValueOnce({
      data: {
        payload: [structuredClone(initialTask)],
        meta: { count: 25, has_more: false, page: 1, per_page: 25 },
      },
    });

  await state.loadTasks();

  expect(state.listCurrentPage).toBe(1);
  expect(CrmTasksAPI.get).toHaveBeenNthCalledWith(
    1,
    expect.objectContaining({ page: 2, per_page: 25 })
  );
  expect(CrmTasksAPI.get).toHaveBeenNthCalledWith(
    2,
    expect.objectContaining({ page: 1, per_page: 25 })
  );
  expect(state.tasks.map(task => task.id)).toEqual([7]);
});

it('cancels pending reloads and restores preferences before loading a different account', async () => {
  localStorage.setItem(
    'crm-tasks-page-preferences',
    JSON.stringify({
      1: { currentPresentation: 'list' },
      2: {
        currentPresentation: 'list',
        listQuickFilters: { q: 'new account search' },
        listSort: { direction: 'desc', key: 'title' },
      },
    })
  );
  const { state } = await mountEditor('page');
  state.currentPresentation = 'list';
  state.listCurrentPage = 3;
  vi.useFakeTimers();

  state.listQuickFilters.q = 'old account pending search';
  await flushPromises();
  CrmTasksAPI.get.mockReset().mockResolvedValue({
    data: {
      payload: [structuredClone(initialTask)],
      meta: { count: 1, has_more: false, page: 1, per_page: 25 },
    },
  });

  try {
    state.accountId = 2;
    await flushPromises();
    await vi.advanceTimersByTimeAsync(350);

    expect(state.listCurrentPage).toBe(1);
    expect(state.listQuickFilters.q).toBe('new account search');
    expect(state.listSort).toEqual({ direction: 'desc', key: 'title' });
    expect(CrmTasksAPI.get).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({
        page: 1,
        per_page: 25,
        q: 'new account search',
        sort_by: 'title',
        sort_direction: 'desc',
      })
    );
  } finally {
    vi.useRealTimers();
  }
});

it('reclassifies a sales task as standalone personal in one form save', async () => {
  const { state } = await mountEditor('page');
  await open('page', state);
  state.form.contextKind = 'personal';
  state.form.dealId = '';

  await state.saveTask();

  expect(CrmTasksAPI.saveForm).toHaveBeenCalledExactlyOnceWith(7, {
    context_kind: 'personal',
    deal_id: null,
    lock_version: 1,
    idempotency_key: expect.any(String),
  });
});

it.each(['page', 'panel'])(
  '%s edit reconciles custom fields against the persisted context',
  async kind => {
    const definitions = [
      { key: 'shared_note', defaultValue: 'shared default', rules: {} },
      {
        key: 'sales_note',
        defaultValue: 'sales default',
        rules: { contexts: ['deal_task'] },
      },
      {
        key: 'personal_note',
        defaultValue: 'personal default',
        rules: { contexts: ['standalone_task'] },
      },
    ];
    taskFieldDefinitions.push(...definitions);
    CrmTasksAPI.get.mockResolvedValue(
      response([
        {
          ...initialTask,
          customAttributes: {
            shared_note: 'keep me',
            personal_note: 'remove me',
          },
        },
      ])
    );

    const { state } = await mountEditor(
      kind,
      kind === 'panel' ? { taskFieldDefinitions: definitions } : {}
    );
    await open(kind, state);

    expect(state.form.customAttributes).toEqual({
      shared_note: 'keep me',
      sales_note: 'sales default',
    });
  }
);

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
  await publish({ ...initialTask, lockVersion: 2, title: 'Other title' });
  await state.saveTaskTitle(state.tasks[0]);
  expect(CrmTasksAPI.update).not.toHaveBeenCalled();
  expect(state.taskTitleDraft).toBe('Inline draft');
});

it('does not apply a mutation response from the previous account', async () => {
  const { state } = await mountEditor('page');
  const pending = deferred();
  const updating = state.runTaskMutation(() => pending.promise);
  const rejected = expect(updating).rejects.toThrow('STALE_RECORD');
  CrmTasksAPI.get.mockResolvedValue(response([]));
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
