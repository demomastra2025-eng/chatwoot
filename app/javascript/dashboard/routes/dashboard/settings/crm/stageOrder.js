const TERMINAL_STAGE_OUTCOMES = new Set(['won', 'lost']);
const TECHNICAL_STAGE_CODES = new Set(['new']);

export const isTerminalStageOutcome = outcome =>
  TERMINAL_STAGE_OUTCOMES.has(String(outcome || '').toLowerCase());

export const isTerminalStage = stage => isTerminalStageOutcome(stage?.outcome);

export const isTechnicalStage = stage =>
  TECHNICAL_STAGE_CODES.has(String(stage?.code || '').toLowerCase());

export const isPositionLockedStage = stage =>
  Boolean(
    stage?.positionLocked || isTechnicalStage(stage) || isTerminalStage(stage)
  );

const stageSortWeight = stage => {
  if (isTechnicalStage(stage)) return 0;
  if (!isTerminalStage(stage)) return 1;
  return String(stage.outcome).toLowerCase() === 'won' ? 2 : 3;
};

export const sortStages = stages =>
  [...(stages || [])].sort(
    (left, right) =>
      stageSortWeight(left) - stageSortWeight(right) ||
      Number(left.position ?? 0) - Number(right.position ?? 0) ||
      Number(left.id ?? 0) - Number(right.id ?? 0)
  );

export const normalizeDraggedStageOrder = stages => {
  const currentStages = [...(stages || [])];
  const technicalStages = currentStages.filter(isTechnicalStage);
  const movableStages = currentStages.filter(
    stage => !isPositionLockedStage(stage)
  );
  const terminalStages = sortStages(currentStages.filter(isTerminalStage));

  return [...technicalStages, ...movableStages, ...terminalStages];
};

export const movableStageIds = stages =>
  (stages || [])
    .filter(stage => !isPositionLockedStage(stage))
    .map(stage => stage.id);
