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
  savePipelineMock,
  saveTaskStatusMock,
  updateStageMock,
} = vi.hoisted(() => ({
  currentAccount: { id: '1' },
  checkStageDeletionMock: vi.fn(),
  createStageMock: vi.fn(),
  deleteStageMock: vi.fn(),
  getFieldDefinitionsMock: vi.fn(),
  getPipelinesMock: vi.fn(),
  getTaskStatusesMock: vi.fn(),
  savePipelineMock: vi.fn(),
  saveTaskStatusMock: vi.fn(),
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

vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: vi.fn(() => 'Request failed'),
}));

describe('useCrmReferencesStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    currentAccount.id = '1';
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
