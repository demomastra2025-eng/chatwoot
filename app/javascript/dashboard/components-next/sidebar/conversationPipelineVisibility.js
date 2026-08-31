const sortByPositionThenId = (left, right) => {
  const leftPosition = Number(left?.position);
  const rightPosition = Number(right?.position);
  const normalizedLeftPosition = Number.isFinite(leftPosition)
    ? leftPosition
    : Number.MAX_SAFE_INTEGER;
  const normalizedRightPosition = Number.isFinite(rightPosition)
    ? rightPosition
    : Number.MAX_SAFE_INTEGER;

  if (normalizedLeftPosition !== normalizedRightPosition) {
    return normalizedLeftPosition - normalizedRightPosition;
  }

  return Number(left?.id || 0) - Number(right?.id || 0);
};

const normalizeId = value => String(value ?? '');

export const CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY =
  'dashboard_conversation_sidebar_pipeline_visibility';

export const resolveActiveConversationPipelines = (pipelines = []) =>
  [...(pipelines || [])]
    .filter(pipeline => pipeline?.active !== false)
    .sort(sortByPositionThenId)
    .map(pipeline => ({
      ...pipeline,
      stages: [...(pipeline.stages || [])]
        .filter(stage => stage?.active !== false)
        .sort(sortByPositionThenId),
    }));

const resolveDefaultPipelineId = pipelines =>
  normalizeId(
    pipelines.find(pipeline => pipeline?.default)?.id || pipelines[0]?.id
  );

const persistedPipelinesById = setting =>
  new Map(
    (Array.isArray(setting?.pipelines) ? setting.pipelines : [])
      .filter(entry => normalizeId(entry?.id))
      .map(entry => [normalizeId(entry.id), entry])
  );

export const buildConversationPipelineVisibilityDraft = (
  settings = {},
  pipelines = []
) => {
  const activePipelines = resolveActiveConversationPipelines(pipelines);
  const selectablePipelines = activePipelines.filter(
    pipeline => pipeline.stages.length > 0
  );
  const setting = settings?.[CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY];
  const isConfigured = setting?.configured === true;
  const savedPipelines = persistedPipelinesById(setting);
  const defaultPipelineId = resolveDefaultPipelineId(selectablePipelines);
  const configuredPipelineId = normalizeId(
    selectablePipelines.find(
      pipeline => savedPipelines.get(normalizeId(pipeline.id))?.enabled === true
    )?.id
  );

  return activePipelines.reduce((draft, pipeline) => {
    const pipelineId = normalizeId(pipeline.id);
    const savedPipeline = savedPipelines.get(pipelineId);
    const hiddenStageIds = new Set(
      (savedPipeline?.hidden_stage_ids || []).map(normalizeId)
    );

    draft[pipelineId] = {
      enabled: isConfigured
        ? pipelineId === configuredPipelineId
        : pipelineId === defaultPipelineId,
      stages: pipeline.stages.reduce((stages, stage) => {
        stages[normalizeId(stage.id)] = !hiddenStageIds.has(
          normalizeId(stage.id)
        );
        return stages;
      }, {}),
    };

    return draft;
  }, {});
};

export const serializeConversationPipelineVisibility = (
  draft = {},
  pipelines = []
) => {
  const activePipelines = resolveActiveConversationPipelines(pipelines);
  const selectablePipelines = activePipelines.filter(
    pipeline => pipeline.stages.length > 0
  );
  const selectedPipelineId = normalizeId(
    selectablePipelines.find(
      pipeline => draft[normalizeId(pipeline.id)]?.enabled === true
    )?.id
  );

  return {
    configured: true,
    pipelines: activePipelines.map(pipeline => {
      const pipelineDraft = draft[normalizeId(pipeline.id)] || {};

      return {
        id: pipeline.id,
        enabled: normalizeId(pipeline.id) === selectedPipelineId,
        hidden_stage_ids: pipeline.stages
          .filter(
            stage => pipelineDraft.stages?.[normalizeId(stage.id)] === false
          )
          .map(stage => stage.id),
      };
    }),
  };
};

export const resolveVisibleConversationPipelines = (
  pipelines = [],
  settings = {}
) => {
  const activePipelines = resolveActiveConversationPipelines(pipelines);
  const draft = buildConversationPipelineVisibilityDraft(
    settings,
    activePipelines
  );

  return activePipelines
    .filter(pipeline => draft[normalizeId(pipeline.id)]?.enabled)
    .map(pipeline => ({
      ...pipeline,
      stages: pipeline.stages.filter(
        stage =>
          draft[normalizeId(pipeline.id)]?.stages?.[normalizeId(stage.id)] !==
          false
      ),
    }))
    .filter(pipeline => pipeline.stages.length > 0);
};

export const isValidConversationPipelineSelection = (
  pipelines,
  pipelineId,
  stageId
) => {
  if (!normalizeId(pipelineId)) {
    return !normalizeId(stageId);
  }

  const pipeline = resolveActiveConversationPipelines(pipelines).find(
    candidate => normalizeId(candidate.id) === normalizeId(pipelineId)
  );
  if (!pipeline) return false;
  if (!normalizeId(stageId)) return true;

  return pipeline.stages.some(
    stage => normalizeId(stage.id) === normalizeId(stageId)
  );
};
