// The "Other" reason is the platform-owned fallback of every outcome reason
// list (handoff and completion). It can neither be removed nor disabled and it
// always closes the list, so every list goes through the helpers below.
export const SYSTEM_REASON_ID = 'other';

// Same limit as Captain::OutcomeReasonConfig::MAX_REASONS_PER_TYPE.
export const MAX_REASONS_PER_LIST = 27;
export const MAX_REASON_LABEL_LENGTH = 255;

export const isSystemReason = reason => reason?.id === SYSTEM_REASON_ID;

export const BUILTIN_REASON_IDS = new Set([
  'goal_achieved',
  'question_resolved',
  'customer_declined',
  'no_response',
  'customer_requested_human',
  'low_confidence',
  'manual_action_required',
  'complaint_or_conflict',
  'tool_or_policy_limit',
  'faq_no_answer',
  SYSTEM_REASON_ID,
]);

// The workspace settings API marks platform reasons with `builtin: true`;
// the known ids stay built in even when the flag is missing.
export const isBuiltInReason = reason =>
  reason?.builtin === true || BUILTIN_REASON_IDS.has(reason?.id);
export const isReasonLocked = reason =>
  isSystemReason(reason) || reason?.locked === true;

// User-defined reasons keep the order they already have, the system reason is
// always last. Array#filter is stable, so no other reordering happens.
export const sortReasons = reasons => {
  const list = Array.isArray(reasons) ? reasons : [];
  return [
    ...list.filter(reason => !isSystemReason(reason)),
    ...list.filter(isSystemReason),
  ];
};

// A new (possibly still unsaved) reason lands after the existing user reasons
// and before the system reason.
export const insertReason = (reasons, reason) =>
  sortReasons([...(Array.isArray(reasons) ? reasons : []), reason]);

// Ids follow Captain::OutcomeReasonConfig::ID_PATTERN (lowercase letters,
// digits, `_` and `-`, at most 64 characters).
let customReasonSequence = 0;
export const createCustomReason = type => {
  customReasonSequence += 1;
  return {
    id: `custom_${type}_${Date.now().toString(36)}_${customReasonSequence}`,
    label: '',
    enabled: true,
    builtin: false,
  };
};
