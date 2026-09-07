import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { useCrmReferencesStore } from './references';

const {
  currentAccount,
  checkStageDeletionMock,
  createStageMock,
  deleteStageMock,
  getFieldDefinitionsMock,
  getPipelinesMock,
  getTaskStatusesMock,
  getTaskTypesMock,
  saveTaskOutcomeMock,
  savePipelineMock,
  saveTaskStatusMock,
  saveTaskTypeMock,
  updateStageMock,
} = vi.hoisted(() => ({
  currentAccount: { id: '1' },
  checkStageDeletionMock: vi.fn(),
  createStageMock: vi.fn(),
  deleteStageMock: vi.fn(),
  getFieldDefinitionsMock: vi.fn(),
  getPipelinesMock: vi.fn(),
  getTaskStatusesMock: vi.fn(),
  getTaskTypesMock: vi.fn(),
  saveTaskOutcomeMock: vi.fn(),
  savePipelineMock: vi.fn(),
  saveTaskStatusMock: vi.fn(),
  saveTaskTypeMock: vi.fn(),
  updateStageMock: vi.fn(),
}));

vi.mock('dashboard/api/crm/fieldDefinitions', () => ({
  default: {
    get: getFieldDefinitionsMock,
  },
}));

vi.mock('dashboard/api/crm/pipelines', () => ({
  default: {
    get accountIdFromRoute() {
      return currentAccount.id;
    },
    checkStageDeletion: checkStageDeletionMock,
    create: savePipelineMock,
    createStage: createStageMock,
    delete: vi.fn(),
    deletePipeline: vi.fn(),
    deleteStage: deleteStageMock,
    get: getPipelinesMock,
    update: savePipelineMock,
    updateStage: updateStageMock,
  },
}));

vi.mock('dashboard/api/crm/taskStatuses', () => ({
  default: {
    create: saveTaskStatusMock,
    deleteTaskStatus: vi.fn(),
    get: getTaskStatusesMock,
    update: saveTaskStatusMock,
  },
}));

vi.mock('dashboard/api/crm/taskTypes', () => ({
  default: {
    get accountIdFromRoute() {
      return currentAccount.id;
    },
    create: saveTaskTypeMock,
    get: getTaskTypesMock,
    update: saveTaskTypeMock,
  },
}));

vi.mock('dashboard/api/crm/taskOutcomes', () => ({
  default: {
    create: saveTaskOutcomeMock,
    update: saveTaskOutcomeMock,
  },
}));

vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: vi.fn(() => 'Request failed'),
}));

describe('useCrmReferencesStore', () => {
  const deferred = () => {
    let resolve;
    let reject;
    const promise = new Promise((yes, no) => {
      resolve = yes;
      reject = no;
    });
    return { promise, resolve, reject };
  };

  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    currentAccount.id = '1';
  });

  it('loads task types with nested outcomes and updates an outcome in place', async () => {
    const store = useCrmReferencesStore();
    getTaskTypesMock.mockResolvedValue({
      data: {
        payload: [
          {
            id: 7,
            code: 'call',
            outcomes: [{ id: 11, code: 'answered', name: 'Answered' }],
          },
        ],
      },
    });
    saveTaskOutcomeMock.mockResolvedValue({
      data: {
        payload: {
          id: 11,
          task_type_id: 7,
          code: 'answered',
          name: 'Reached',
        },
      },
    });

    await store.loadTaskTypes();
    await store.saveTaskOutcome({ id: 11, taskTypeId: 7, name: 'Reached' });

    expect(store.taskTypes[0].outcomes).toEqual([
      expect.objectContaining({ id: 11, name: 'Reached', taskTypeId: 7 }),
    ]);
  });

  it('deduplicates full catalog reads and overlays a confirmed type on an older GET', async () => {
    const store = useCrmReferencesStore();
    const get = deferred();
    getTaskTypesMock.mockReturnValueOnce(get.promise);
    const first = store.loadTaskTypes();
    const second = store.loadTaskTypes({ include_inactive: true });
    await Promise.resolve();
    expect(getTaskTypesMock).toHaveBeenCalledTimes(1);
    saveTaskTypeMock.mockResolvedValueOnce({
      data: { payload: { id: 7, name: 'After' } },
    });
    await store.saveTaskType({ id: 7, name: 'After' });
    get.resolve({
      data: {
        payload: [
          { id: 7, name: 'Before' },
          { id: 8, active: false },
        ],
      },
    });
    await Promise.all([first, second]);
    expect(store.taskTypes).toEqual([
      expect.objectContaining({ id: 7, name: 'After' }),
      expect.objectContaining({ id: 8, active: false }),
    ]);
    expect(store.ui.isLoadingTaskTypes).toBe(false);
    getTaskTypesMock.mockResolvedValueOnce({ data: { payload: [] } });
    await store.loadTaskTypes();
    expect(getTaskTypesMock).toHaveBeenCalledTimes(2);
  });

  it('merges an outcome saved while its parent type is still loading', async () => {
    const store = useCrmReferencesStore();
    const get = deferred();
    getTaskTypesMock.mockReturnValueOnce(get.promise);
    const loading = store.loadTaskTypes();
    saveTaskOutcomeMock.mockResolvedValueOnce({
      data: {
        payload: {
          id: 11,
          task_type_id: 7,
          name: 'Updated',
          active: false,
        },
      },
    });
    await store.saveTaskOutcome({ id: 11, name: 'Updated' });
    get.resolve({
      data: {
        payload: [{ id: 7, outcomes: [{ id: 11, name: 'Old', active: true }] }],
      },
    });
    await loading;
    expect(store.taskTypes[0].outcomes[0]).toMatchObject({
      id: 11,
      name: 'Updated',
      active: false,
    });
  });

  it('does not replace a successful mutation with an obsolete GET error', async () => {
    const store = useCrmReferencesStore();
    const get = deferred();
    getTaskTypesMock.mockReturnValueOnce(get.promise);
    const loading = store.loadTaskTypes();
    saveTaskTypeMock.mockResolvedValueOnce({
      data: { payload: { id: 7, name: 'Saved' } },
    });
    await store.saveTaskType({ id: 7, name: 'Saved' });
    get.reject(new Error('old request failed'));
    await expect(loading).resolves.toEqual(store.taskTypes);
    expect(store.ui.taskCatalogError).toBeNull();
    expect(store.ui.isLoadingTaskTypes).toBe(false);
  });

  it('ignores reads from an earlier account visit, including A to B to A', async () => {
    const store = useCrmReferencesStore();
    const oldA = deferred();
    const b = deferred();
    const newA = deferred();
    getTaskTypesMock
      .mockReturnValueOnce(oldA.promise)
      .mockReturnValueOnce(b.promise)
      .mockReturnValueOnce(newA.promise);
    const oldLoading = store.loadTaskTypes();
    await Promise.resolve();
    currentAccount.id = '2';
    const bLoading = store.loadTaskTypes();
    await Promise.resolve();
    currentAccount.id = '1';
    const newLoading = store.loadTaskTypes();
    await Promise.resolve();
    oldA.resolve({ data: { payload: [{ id: 1, name: 'Stale A' }] } });
    b.reject(new Error('B failed'));
    await Promise.all([oldLoading, bLoading]);
    expect(store.taskTypes).toEqual([]);
    expect(store.ui.isLoadingTaskTypes).toBe(true);
    expect(store.ui.taskCatalogError).toBeNull();
    newA.resolve({ data: { payload: [{ id: 3, name: 'Current A' }] } });
    await newLoading;
    expect(store.taskTypes[0].name).toBe('Current A');
  });

  it('does not send queued mutations to another account after navigation', async () => {
    const store = useCrmReferencesStore();
    const mutation = deferred();
    saveTaskTypeMock.mockReturnValueOnce(mutation.promise);
    const first = store.saveTaskType({ id: 7, name: 'A' });
    const queued = store.saveTaskType({ id: 8, name: 'Also A' });
    await Promise.resolve();
    expect(store.ui.isSavingTaskCatalog).toBe(true);
    currentAccount.id = '2';
    getTaskTypesMock.mockResolvedValueOnce({
      data: { payload: [{ id: 20, name: 'B' }] },
    });
    await store.loadTaskTypes();
    mutation.resolve({ data: { payload: { id: 7, name: 'A' } } });
    await expect(first).resolves.toBeNull();
    await expect(queued).resolves.toBeNull();
    expect(saveTaskTypeMock).toHaveBeenCalledTimes(1);
    expect(store.taskTypes[0].name).toBe('B');
    expect(store.ui.isSavingTaskCatalog).toBe(false);
  });

  it('keeps won and lost stages last when a new open stage is inserted before them', async () => {
    const store = useCrmReferencesStore();
    store.pipelines = [
      {
        id: 7,
        name: 'Sales',
        stages: [
          { id: 1, code: 'new', name: 'New', outcome: 'open', position: 1 },
          {
            id: 2,
            code: 'qualified',
            name: 'Qualified',
            outcome: 'open',
            position: 2,
          },
          { id: 3, code: 'won', name: 'Won', outcome: 'won', position: 3 },
          { id: 4, code: 'lost', name: 'Lost', outcome: 'lost', position: 4 },
        ],
      },
    ];
    createStageMock.mockResolvedValue({
      data: {
        payload: {
          id: 5,
          code: 'follow_up',
          name: 'Follow-up',
          outcome: 'open',
          pipeline_id: 7,
          position: 3,
        },
      },
    });

    await store.saveStage({ name: 'Follow-up', pipelineId: 7 });

    expect(store.pipelines[0].stages.map(stage => stage.code)).toEqual([
      'new',
      'qualified',
      'follow_up',
      'won',
      'lost',
    ]);
    expect(store.pipelines[0].stages.map(stage => stage.position)).toEqual([
      1, 2, 3, 4, 5,
    ]);
  });

  it('shares an in-flight pipeline request between concurrent consumers', async () => {
    const store = useCrmReferencesStore();
    let resolveRequest;
    getPipelinesMock.mockReturnValue(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );

    const firstLoad = store.loadPipelines();
    const secondLoad = store.loadPipelines();

    expect(getPipelinesMock).toHaveBeenCalledTimes(1);
    expect(store.ui.isLoadingPipelines).toBe(true);

    resolveRequest({ data: { payload: [{ id: 7, name: 'Sales' }] } });
    await expect(Promise.all([firstLoad, secondLoad])).resolves.toEqual([
      [{ id: 7, name: 'Sales' }],
      [{ id: 7, name: 'Sales' }],
    ]);
    expect(store.ui.isLoadingPipelines).toBe(false);
  });

  it('does not publish a response after the active account changes', async () => {
    const store = useCrmReferencesStore();
    let resolveFirstRequest;
    getPipelinesMock.mockReturnValueOnce(
      new Promise(resolve => {
        resolveFirstRequest = resolve;
      })
    );

    const firstLoad = store.loadPipelines();
    currentAccount.id = '2';
    getPipelinesMock.mockResolvedValueOnce({
      data: { payload: [{ id: 8, name: 'Account B' }] },
    });
    await store.loadPipelines();
    resolveFirstRequest({ data: { payload: [{ id: 7, name: 'Account A' }] } });
    await firstLoad;

    expect(store.pipelines).toEqual([{ id: 8, name: 'Account B' }]);
  });

  it('does not publish an error from the previous account', async () => {
    const store = useCrmReferencesStore();
    let rejectFirstRequest;
    getPipelinesMock.mockReturnValueOnce(
      new Promise((resolve, reject) => {
        rejectFirstRequest = reject;
      })
    );

    const firstLoad = store.loadPipelines();
    const firstLoadExpectation =
      expect(firstLoad).rejects.toThrow('Account A failed');
    currentAccount.id = '2';
    getPipelinesMock.mockResolvedValueOnce({
      data: { payload: [{ id: 8, name: 'Account B' }] },
    });
    await store.loadPipelines();
    rejectFirstRequest(new Error('Account A failed'));
    await firstLoadExpectation;

    expect(store.pipelines).toEqual([{ id: 8, name: 'Account B' }]);
    expect(store.ui.error).toBeNull();
  });

  it('does not publish an error from a stale request for the current account', async () => {
    const store = useCrmReferencesStore();
    let rejectFirstRequest;
    getPipelinesMock
      .mockReturnValueOnce(
        new Promise((resolve, reject) => {
          rejectFirstRequest = reject;
        })
      )
      .mockResolvedValueOnce({
        data: { payload: [{ id: 8, name: 'Latest response' }] },
      });

    const firstLoad = store.loadPipelines();
    const firstLoadExpectation = expect(firstLoad).rejects.toThrow(
      'Stale request failed'
    );
    await store.loadPipelines({ include_inactive_stages: true });
    rejectFirstRequest(new Error('Stale request failed'));
    await firstLoadExpectation;

    expect(store.pipelines).toEqual([{ id: 8, name: 'Latest response' }]);
    expect(store.ui.error).toBeNull();
  });

  it('does not replace a full pipeline response with a later active-only response', async () => {
    const store = useCrmReferencesStore();
    let resolveFullRequest;
    let resolveActiveRequest;
    getPipelinesMock
      .mockReturnValueOnce(
        new Promise(resolve => {
          resolveFullRequest = resolve;
        })
      )
      .mockReturnValueOnce(
        new Promise(resolve => {
          resolveActiveRequest = resolve;
        })
      );

    const fullLoad = store.loadPipelines({ include_inactive_stages: true });
    const activeLoad = store.loadPipelines();
    resolveFullRequest({
      data: {
        payload: [{ id: 7, name: 'Full', stages: [{ id: 3, active: false }] }],
      },
    });
    await fullLoad;
    resolveActiveRequest({
      data: { payload: [{ id: 7, name: 'Active only', stages: [] }] },
    });
    await activeLoad;

    expect(store.pipelines[0]).toMatchObject({
      id: 7,
      name: 'Full',
      stages: [{ id: 3, active: false }],
    });
  });

  it('inserts a created stage directly between existing open stages', async () => {
    const store = useCrmReferencesStore();
    store.pipelines = [
      {
        id: 7,
        name: 'Sales',
        stages: [
          { id: 1, code: 'first', outcome: 'open', position: 1 },
          { id: 2, code: 'second', outcome: 'open', position: 2 },
        ],
      },
    ];
    createStageMock.mockResolvedValue({
      data: {
        payload: {
          id: 5,
          code: 'inserted',
          outcome: 'open',
          pipeline_id: 7,
          position: 2,
        },
      },
    });

    await store.saveStage({ name: 'Inserted', pipelineId: 7, position: 2 });

    expect(store.pipelines[0].stages.map(stage => stage.code)).toEqual([
      'first',
      'inserted',
      'second',
    ]);
    expect(store.pipelines[0].stages.map(stage => stage.position)).toEqual([
      1, 2, 3,
    ]);
  });

  it('checks stage deletion without mutating the local pipeline', async () => {
    const store = useCrmReferencesStore();
    store.pipelines = [{ id: 7, stages: [{ id: 2, name: 'Qualified' }] }];
    checkStageDeletionMock.mockResolvedValue({
      data: { payload: { deletable: true } },
    });

    await expect(store.checkStageDeletion(2)).resolves.toEqual({
      deletable: true,
    });
    expect(checkStageDeletionMock).toHaveBeenCalledWith(2);
    expect(store.pipelines[0].stages).toHaveLength(1);
  });

  it('does not replace the page with a global error when deletion is rejected', async () => {
    const store = useCrmReferencesStore();
    const error = new Error('Stage has deals');
    checkStageDeletionMock.mockRejectedValue(error);

    await expect(store.checkStageDeletion(2)).rejects.toBe(error);
    expect(store.ui.error).toBeNull();
  });
});
