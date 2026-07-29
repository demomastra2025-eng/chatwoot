const touchId = attributes => attributes?.touchId || attributes?.touch_id;
const touchSource = attributes =>
  attributes?.touchSource || attributes?.touch_source;

export const isDelayedTouchMessage = attributes =>
  Boolean(touchId(attributes) || touchSource(attributes) === 'touch');

export const isAutomationTouchMessage = attributes =>
  Boolean(touchId(attributes) && touchSource(attributes) === 'touch');
