const touchId = attributes => attributes?.touchId || attributes?.touch_id;
const touchSource = attributes =>
  attributes?.touchSource || attributes?.touch_source;
const touchOrigin = attributes =>
  attributes?.touchOrigin || attributes?.touch_origin;
const automationRuleId = attributes =>
  attributes?.automationRuleId || attributes?.automation_rule_id;

export const isDelayedTouchMessage = attributes =>
  Boolean(touchId(attributes) || touchSource(attributes) === 'touch');

export const isAutomationTouchMessage = attributes =>
  Boolean(
    touchId(attributes) &&
      touchSource(attributes) === 'touch' &&
      touchOrigin(attributes) === 'automation' &&
      automationRuleId(attributes)
  );
