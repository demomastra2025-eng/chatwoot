const TERMINAL_STAGE_OUTCOMES = new Set(['won', 'lost']);

export const isTerminalStage = stage =>
  TERMINAL_STAGE_OUTCOMES.has(String(stage?.outcome || '').toLowerCase());

export const filterVisibleBoardStages = (stages = [], showInactive = false) =>
  showInactive ? stages : stages.filter(stage => !isTerminalStage(stage));

export const filterVisibleBoardDeals = (deals = [], stages = []) => {
  const visibleStageIds = new Set(
    stages
      .map(stage => Number(stage.id))
      .filter(stageId => Number.isFinite(stageId))
  );

  return deals.filter(deal => visibleStageIds.has(Number(deal.stageId)));
};
