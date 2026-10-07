const TERMINAL_STAGE_OUTCOMES = new Set(['won', 'lost']);

export const isTerminalStage = stage =>
  TERMINAL_STAGE_OUTCOMES.has(String(stage?.outcome || '').toLowerCase());

export const filterVisibleBoardStages = (stages = [], showInactive = false) =>
  stages.filter(
    stage => stage.active !== false && (showInactive || !isTerminalStage(stage))
  );

export const filterVisibleBoardDeals = (deals = [], stages = []) => {
  const visibleStageIds = new Set(
    stages
      .map(stage => Number(stage.id))
      .filter(stageId => Number.isFinite(stageId))
  );

  return deals.filter(deal => visibleStageIds.has(Number(deal.stageId)));
};

export const visibleBoardTotals = (
  stages = [],
  stageCounts = {},
  stageAmounts = {}
) => {
  const amounts = {};
  const count = stages.reduce((total, stage) => {
    const stageId = String(stage.id);
    Object.entries(stageAmounts[stageId] || {}).forEach(
      ([currency, amount]) => {
        amounts[currency] = (amounts[currency] || 0) + Number(amount);
      }
    );
    return total + Number(stageCounts[stageId] || 0);
  }, 0);

  return { amounts, count };
};
