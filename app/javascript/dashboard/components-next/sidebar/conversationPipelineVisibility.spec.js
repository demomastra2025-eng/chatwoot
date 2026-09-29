import { describe, expect, it } from 'vitest';

import {
  CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY,
  buildConversationPipelineVisibilityDraft,
  isValidConversationPipelineSelection,
  resolveActiveConversationPipelines,
  resolveVisibleConversationPipelines,
  serializeConversationPipelineVisibility,
} from './conversationPipelineVisibility';

const pipelines = [
  {
    id: 2,
    name: 'Second',
    active: true,
    default: false,
    position: 2,
    stages: [
      { id: 22, name: 'Won', active: true, position: 2 },
      { id: 21, name: 'New', active: true, position: 1 },
    ],
  },
  {
    id: 1,
    name: 'Main',
    active: true,
    default: true,
    position: 1,
    stages: [
      { id: 12, name: 'Qualified', active: true, position: 2 },
      { id: 11, name: 'New', active: true, position: 1 },
      { id: 13, name: 'Archived', active: false, position: 3 },
    ],
  },
  {
    id: 3,
    name: 'Inactive',
    active: false,
    default: false,
    position: 3,
    stages: [{ id: 31, name: 'New', active: true, position: 1 }],
  },
];

describe('conversationPipelineVisibility', () => {
  it('sorts active pipelines and stages while removing inactive records', () => {
    const resolved = resolveActiveConversationPipelines(pipelines);

    expect(resolved.map(pipeline => pipeline.id)).toEqual([1, 2]);
    expect(resolved[0].stages.map(stage => stage.id)).toEqual([11, 12]);
  });

  it('preserves the legacy default-pipeline sidebar until settings are configured', () => {
    const draft = buildConversationPipelineVisibilityDraft({}, pipelines);
    const visible = resolveVisibleConversationPipelines(pipelines, {});

    expect(draft['1'].enabled).toBe(true);
    expect(draft['2'].enabled).toBe(false);
    expect(visible.map(pipeline => pipeline.id)).toEqual([1]);
    expect(visible[0].stages.map(stage => stage.id)).toEqual([11, 12]);
  });

  it('shows only the main pipeline and its selected stages after configuration', () => {
    const settings = {
      [CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY]: {
        configured: true,
        pipelines: [
          { id: 1, enabled: false, hidden_stage_ids: [] },
          { id: 2, enabled: true, hidden_stage_ids: [22] },
        ],
      },
    };

    const visible = resolveVisibleConversationPipelines(pipelines, settings);

    expect(visible.map(pipeline => pipeline.id)).toEqual([2]);
    expect(visible[0].stages.map(stage => stage.id)).toEqual([21]);
  });

  it('serializes only one main pipeline and its hidden-stage selections', () => {
    const draft = buildConversationPipelineVisibilityDraft({}, pipelines);
    draft['1'].stages['12'] = false;
    draft['2'].enabled = true;

    expect(serializeConversationPipelineVisibility(draft, pipelines)).toEqual({
      configured: true,
      pipelines: [
        { id: 1, enabled: true, hidden_stage_ids: [12] },
        { id: 2, enabled: false, hidden_stage_ids: [] },
      ],
    });
  });

  it('normalizes legacy multi-pipeline settings to the first active pipeline', () => {
    const settings = {
      [CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY]: {
        configured: true,
        pipelines: [
          { id: 1, enabled: true, hidden_stage_ids: [] },
          { id: 2, enabled: true, hidden_stage_ids: [] },
        ],
      },
    };

    const draft = buildConversationPipelineVisibilityDraft(settings, pipelines);

    expect(draft['1'].enabled).toBe(true);
    expect(draft['2'].enabled).toBe(false);
    expect(
      resolveVisibleConversationPipelines(pipelines, settings)
    ).toHaveLength(1);
  });

  it('does not render a selected pipeline when every stage is hidden', () => {
    const settings = {
      [CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY]: {
        configured: true,
        pipelines: [{ id: 1, enabled: true, hidden_stage_ids: [11, 12] }],
      },
    };

    expect(resolveVisibleConversationPipelines(pipelines, settings)).toEqual(
      []
    );
  });

  it('keeps a stage selected from an active non-default pipeline', () => {
    expect(isValidConversationPipelineSelection(pipelines, 2, 21)).toBe(true);
    expect(isValidConversationPipelineSelection(pipelines, 2, 11)).toBe(false);
  });

  it('rejects a missing pipeline and a stage without its pipeline', () => {
    expect(isValidConversationPipelineSelection(pipelines, 99, 21)).toBe(false);
    expect(isValidConversationPipelineSelection(pipelines, null, 21)).toBe(
      false
    );
  });
});
