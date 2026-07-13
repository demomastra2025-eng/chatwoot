export const DEFAULT_INCOMING_CALL_RINGTONE =
  'universfield-ringtone-091-496417.mp3';

export const INCOMING_CALL_RINGTONES = Object.freeze([
  'universfield-mysterious-ringtone-02-494665.mp3',
  'universfield-ringtone-028-380250.mp3',
  'universfield-ringtone-066-496266.mp3',
  DEFAULT_INCOMING_CALL_RINGTONE,
]);

const RINGTONE_VALUES = new Set(INCOMING_CALL_RINGTONES);

const ACTIVE_CALL_STATUSES = new Set([
  'answered',
  'accepted',
  'connected',
  'in_progress',
  'up',
]);

const TERMINAL_CALL_STATUSES = new Set([
  'busy',
  'cancelled',
  'canceled',
  'completed',
  'ended',
  'failed',
  'missed',
  'no_answer',
  'rejected',
]);

const NON_RINGING_REASONS = new Set([
  'AI_AGENT_HANDLING',
  'CALL_ALREADY_CLAIMED',
  'CALL_IN_PROGRESS',
]);

const normalizeStatus = value =>
  value?.toString?.().trim().toLowerCase().replaceAll('-', '_') || '';

const normalizeReason = value =>
  value?.toString?.().trim().toUpperCase().replaceAll('-', '_') || '';

const callRouteAction = call =>
  (
    call?.routeAction ||
    call?.route_action ||
    call?.metadata?.routeAction ||
    call?.metadata?.route_action ||
    ''
  )
    .toString()
    .trim()
    .toLowerCase();

export const resolveIncomingCallRingtone = value => {
  const normalizedValue =
    typeof value === 'string' && value && !value.endsWith('.mp3')
      ? `${value}.mp3`
      : value;

  return RINGTONE_VALUES.has(normalizedValue)
    ? normalizedValue
    : DEFAULT_INCOMING_CALL_RINGTONE;
};

export const incomingCallRingtoneUrl = value =>
  `/audio/ringtone/${resolveIncomingCallRingtone(value)}`;

export const isVoiceCallRingtoneEligible = call => {
  const direction =
    call?.callDirection || call?.call_direction || call?.direction || '';
  const status = normalizeStatus(call?.status);
  const browserJoinSupported =
    call?.browserJoinSupported ?? call?.browser_join_supported;
  const unsupportedReason = normalizeReason(
    call?.browserJoinUnsupportedReason ||
      call?.browser_join_unsupported_reason ||
      ''
  );
  const handledByAi = Boolean(
    call?.serverManagedVoiceCall ||
      call?.server_managed_voice_call ||
      call?.aiVoice ||
      call?.ai_voice ||
      call?.callMode === 'ai' ||
      callRouteAction(call) === 'ai'
  );

  return Boolean(
    direction === 'inbound' &&
      !call?.isActive &&
      !call?.answeredAt &&
      !call?.answered_at &&
      browserJoinSupported !== false &&
      !ACTIVE_CALL_STATUSES.has(status) &&
      !TERMINAL_CALL_STATUSES.has(status) &&
      !handledByAi &&
      !NON_RINGING_REASONS.has(unsupportedReason)
  );
};
