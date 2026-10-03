import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { useCrmReferencesStore } from './references';

const {
  createStageMock,
  deleteStageMock,
  getFieldDefinitionsMock,
  getPipelinesMock,
  getTaskStatusesMock,
  saveStageDraftMock,
  checkStageDeletionMock,
  savePipelineMock,
  saveTaskStatusMock,
  updateStageMock,
} = vi.hoisted(() => ({
  createStageMock: vi.fn(),
  deleteStageMock: vi.fn(),
  getFieldDefinitionsMock: vi.fn(),
  getPipelinesMock: vi.fn(),
  getTaskStatusesMock: vi.fn(),
  saveStageDraftMock: vi.fn(),
  checkStageDeletionMock: vi.fn(),
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
    saveStageDraft: saveStageDraftMock,
    checkStageDeletion: checkStageDeletionMock,
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

  it('saves a stage draft as one pipeline update and keeps stage settings', async () => {
    const store = useCrmReferencesStore();
    store.pipelines = [{ id: 7, name: 'Sales', stages: [] }];
    const draft = {
      deleted_stage_ids: [],
      stages: [
        { id: 2, name: 'Qualified', transition_reason_required: true },
        { id: 1, name: 'New', default: true },
      ],
      terminal_stages: [{ id: 3, name: 'Won', closing_reason_options: [] }],
    };
    const pipeline = {
      id: 7,
      name: 'Sales',
      stages: [
        {
          id: 2,
          name: 'Qualified',
          outcome: 'open',
          position: 0,
          transitionReasonRequired: true,
          transitionReasonOptions: ['Qualified'],
        },
        { id: 1, name: 'New', outcome: 'open', position: 1, default: true },
        { id: 3, name: 'Won', outcome: 'won', position: 3 },
      ],
    };
    saveStageDraftMock.mockResolvedValue({ data: { payload: pipeline } });

    await store.saveStageDraft(7, draft);

    expect(saveStageDraftMock).toHaveBeenCalledWith(7, draft);
    expect(store.pipelines[0].stages[0]).toMatchObject({
      id: 2,
      transitionReasonRequired: true,
      transitionReasonOptions: ['Qualified'],
    });
    expect(store.pipelines[0].stages[1]).toMatchObject({
      id: 1,
      default: true,
    });
  });

  it('normalizes the stage deletion preflight response', async () => {
    const store = useCrmReferencesStore();
    checkStageDeletionMock.mockResolvedValue({
      data: {
        payload: {
          stage_id: 12,
          can_delete: false,
          deal_count: 3,
          block_reason: 'STAGE_HAS_DEALS',
        },
      },
    });

    await expect(store.checkStageDeletion(12)).resolves.toEqual({
      stageId: 12,
      canDelete: false,
      dealCount: 3,
      blockReason: 'STAGE_HAS_DEALS',
    });
    expect(checkStageDeletionMock).toHaveBeenCalledWith(12);
  });
});
