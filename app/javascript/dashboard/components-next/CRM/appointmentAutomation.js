export const appointmentAutomationDraft = (config = {}) => {
  const calendar =
    config.autoCreateFromCalendar ?? config.auto_create_from_calendar ?? false;
  const medelement =
    config.autoCreateFromMedelement ??
    config.auto_create_from_medelement ??
    false;
  return {
    enabled: config.enabled === true,
    auto_create_deals:
      config.autoCreateDeals ??
      config.auto_create_deals ??
      (calendar === true || medelement === true),
    cardinality: config.cardinality || 'request',
    auto_create_from_calendar: calendar === true,
    auto_create_from_medelement: medelement === true,
    manual_stage_change:
      config.manualStageChange || config.manual_stage_change || 'continue',
    success_mode: config.successMode || config.success_mode || 'manual',
    rules: (config.rules || []).map(rule => ({
      stage_id: rule.stageId ?? rule.stage_id,
      scope: rule.scope || 'any',
      conditions: [...(rule.conditions || [])],
      closing_reasons: [...(rule.closingReasons || rule.closing_reasons || [])],
    })),
  };
};
