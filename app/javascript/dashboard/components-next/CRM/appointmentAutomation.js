export const APPOINTMENT_AUTOMATION_EVENTS = [
  {
    key: 'scheduled',
    priority: 5,
    matchConditions: ['scheduled', 'provider_confirmed'],
    saveConditions: ['scheduled'],
    defaultScope: 'nearest',
  },
  {
    key: 'patient_confirmed',
    priority: 4,
    matchConditions: ['patient_confirmed'],
    saveConditions: ['patient_confirmed'],
    defaultScope: 'nearest',
  },
  {
    key: 'attended',
    priority: 1,
    matchConditions: ['attended'],
    saveConditions: ['attended'],
    defaultScope: 'any',
  },
  {
    key: 'no_show',
    priority: 2,
    matchConditions: ['no_show'],
    saveConditions: ['no_show'],
    defaultScope: 'nearest',
  },
  {
    key: 'cancelled',
    priority: 3,
    matchConditions: ['cancelled'],
    saveConditions: ['cancelled'],
    defaultScope: 'nearest',
  },
];

const matchingEventsForRule = rule =>
  APPOINTMENT_AUTOMATION_EVENTS.filter(event =>
    (rule?.conditions || []).some(condition =>
      event.matchConditions.includes(condition)
    )
  );

export const splitMultiEventRules = (rules = []) => {
  const sourceRules = Array.isArray(rules) ? rules : [];
  const dedicatedEventKeys = new Set();

  sourceRules.forEach(rule => {
    const events = matchingEventsForRule(rule);
    if (events.length === 1) {
      dedicatedEventKeys.add(events[0].key);
    }
  });

  const result = [];
  sourceRules.forEach(rule => {
    const stageId = rule?.stageId ?? rule?.stage_id;
    const scope = rule?.scope || 'any';
    const closingReasons = [
      ...(rule?.closingReasons || rule?.closing_reasons || []),
    ];
    const events = matchingEventsForRule(rule);

    if (events.length <= 1) {
      result.push({
        stage_id: stageId,
        scope,
        conditions: [...(rule?.conditions || [])],
        closing_reasons: closingReasons,
      });
      return;
    }

    events.forEach(event => {
      if (dedicatedEventKeys.has(event.key)) return;
      dedicatedEventKeys.add(event.key);
      result.push({
        stage_id: stageId,
        scope,
        conditions: [...event.saveConditions],
        closing_reasons: [...closingReasons],
      });
    });
  });

  return result;
};

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
    rules: splitMultiEventRules(config.rules),
  };
};
