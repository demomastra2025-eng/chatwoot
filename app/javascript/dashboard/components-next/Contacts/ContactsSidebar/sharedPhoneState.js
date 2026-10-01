// What the contact card may show from GET /contacts/:id/shared_phone. Manual promotion ships switched off
// (ONELINK_SHARED_PHONE_MANUAL_PROMOTION): the hint, its button and the confirmation dialog appear only when the
// server reports the switch on.
export const isManualPromotionEnabled = sharedPhone =>
  sharedPhone?.manual_promotion_enabled === true;

export const visibleSharedPhoneHint = sharedPhone =>
  isManualPromotionEnabled(sharedPhone) ? sharedPhone?.hint || null : null;

const ERROR_REASONS = {
  SHARED_PHONE_TAKEN: 'taken',
  SHARED_PHONE_STATE_CHANGED: 'state_changed',
  SHARED_PHONE_PROMOTION_DISABLED: 'disabled',
  SHARED_PHONE_HISTORY_TRANSFER_DISABLED: 'disabled',
};

// The promote API answers with a code; the card shows one message per reason.
export const sharedPhoneErrorReason = code => ERROR_REASONS[code] || 'failed';
