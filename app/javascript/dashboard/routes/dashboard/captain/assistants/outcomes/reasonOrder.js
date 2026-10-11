// The "Other" reason is the platform-owned fallback of every outcome reason
// list (handoff and completion). It can neither be removed nor disabled and it
// always closes the list, so every list goes through the helpers below.
export const SYSTEM_REASON_ID = 'other';

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

export const isBuiltInReason = reason => BUILTIN_REASON_IDS.has(reason?.id);
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
