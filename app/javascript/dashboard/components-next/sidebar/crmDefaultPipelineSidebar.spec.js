import { describe, expect, it } from 'vitest';

import { resolveDefaultPipelineWithStages } from './crmDefaultPipelineSidebar';

describe('crmDefaultPipelineSidebar', () => {
  it('returns no pipeline and no stages when no active pipelines exist', () => {
    expect(resolveDefaultPipelineWithStages([])).toEqual({
      pipeline: null,
      stages: [],
    });
    expect(
      resolveDefaultPipelineWithStages([{ id: 1, active: false, stages: [] }])
    ).toEqual({ pipeline: null, stages: [] });
  });

  it('returns active stages from the default active pipeline by position', () => {
    const { pipeline, stages } = resolveDefaultPipelineWithStages([
      {
        id: 2,
        active: true,
        default: false,
        position: 1,
        stages: [{ id: 21, name: 'Other', active: true, position: 1 }],
      },
      {
        id: 1,
        active: true,
        default: true,
        position: 2,
        stages: [
          { id: 13, name: 'Hidden', active: false, position: 1 },
          { id: 12, name: 'Won', active: true, position: 3 },
          { id: 11, name: 'New', active: true, position: 2 },
        ],
      },
    ]);

    expect(pipeline.id).toBe(1);
    expect(stages.map(stage => stage.name)).toEqual(['New', 'Won']);
  });

  it('does not expose non-default active pipelines for the dialog sidebar', () => {
    const { pipeline, stages } = resolveDefaultPipelineWithStages([
      {
        id: 3,
        active: false,
        default: true,
        position: 1,
        stages: [{ id: 31, active: true, position: 1 }],
      },
      {
        id: 2,
        active: true,
        position: 2,
        stages: [
          { id: 22, active: true, position: 2 },
          { id: 21, active: false, position: 1 },
        ],
      },
      {
        id: 1,
        active: true,
        default: true,
        position: 1,
        stages: [{ id: 11, active: true, position: 1 }],
      },
    ]);

    expect(pipeline.id).toBe(1);
    expect(stages.map(stage => stage.id)).toEqual([11]);
  });

  it('falls back to the first active pipeline when no default pipeline exists', () => {
    const { pipeline, stages } = resolveDefaultPipelineWithStages([
      { id: 3, active: false, default: true, position: 1, stages: [] },
      {
        id: 4,
        active: true,
        default: false,
        position: 2,
        stages: [{ id: 41, active: true, position: 1 }],
      },
    ]);

    expect(pipeline.id).toBe(4);
    expect(stages.map(stage => stage.id)).toEqual([41]);
  });

  it('always returns the default pipeline regardless of conversation status context', () => {
    const { pipeline, stages } = resolveDefaultPipelineWithStages([
      {
        id: 1,
        active: true,
        default: true,
        position: 1,
        stages: [{ id: 11, active: true, position: 1 }],
      },
      {
        id: 2,
        active: true,
        default: false,
        position: 2,
        stages: [{ id: 21, active: true, position: 1 }],
      },
    ]);

    expect(pipeline.id).toBe(1);
    expect(stages.map(stage => stage.id)).toEqual([11]);
  });
});
