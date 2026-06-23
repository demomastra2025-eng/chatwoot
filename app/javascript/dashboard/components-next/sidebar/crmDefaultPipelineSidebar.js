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

const resolveActivePipelineSidebarItems = (pipelines = []) =>
  [...(pipelines || [])]
    .filter(pipeline => pipeline?.active !== false)
    .sort(sortByPositionThenId)
    .map(pipeline => ({
      ...pipeline,
      stages: [...(pipeline.stages || [])]
        .filter(stage => stage?.active !== false)
        .sort(sortByPositionThenId),
    }));

const resolvePreferredPipeline = activePipelines =>
  activePipelines.find(item => item?.default) || activePipelines[0] || null;

export const resolveDefaultPipelineWithStages = (pipelines = []) => {
  const activePipelines = resolveActivePipelineSidebarItems(pipelines);
  const pipeline = resolvePreferredPipeline(activePipelines);

  if (!pipeline) {
    return { pipeline: null, stages: [] };
  }

  return { pipeline, stages: pipeline.stages };
};
