import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { useCrmReferencesStore } from './references';

const {
  createStageMock,
  deleteStageMock,
  getFieldDefinitionsMock,
  getPipelinesMock,
  getTaskStatusesMock,
  savePipelineMock,
  saveTaskStatusMock,
  updateStageMock,
} = vi.hoisted(() => ({
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
  });
});
