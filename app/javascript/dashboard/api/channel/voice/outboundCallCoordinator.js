import VoiceAPI from './voiceAPIClient';
import WebphoneClient from './webphoneClient';

const activeAttempts = new Map();

const valueFor = (source, ...keys) => {
  const key = keys.find(
    candidate =>
      source?.[candidate] !== undefined && source?.[candidate] !== null
  );
  return key ? source[key] : null;
};

const outboundFailureReason = error => {
  const reason = error?.reason || error?.message;
  const knownReasons = new Set([
    'incoming_call_preempted',
    'operator_cancelled',
    'sip_outbound_call_failed',
    'sip_outbound_call_in_progress',
    'sip_outbound_calling_timeout',
    'sip_outbound_offer_failed',
    'sip_outbound_offer_timeout',
    'sip_registration_timeout',
  ]);
  if (knownReasons.has(reason)) return reason;
  return error?.sipCallSent
    ? 'sip_outbound_start_failed'
    : 'sip_invite_not_received';
};

const callScope = (call, sessionScope = {}) => ({
  provider: valueFor(call, 'provider') || valueFor(sessionScope, 'provider'),
  inboxId:
    valueFor(call, 'inboxId', 'inbox_id') ||
    valueFor(sessionScope, 'inboxId', 'inbox_id'),
  sessionKey:
    valueFor(call, 'janusSessionKey', 'janus_session_key') ||
    valueFor(sessionScope, 'sessionKey', 'session_key'),
  sipProfileId:
    valueFor(call, 'sipProfileId', 'sip_profile_id') ||
    valueFor(sessionScope, 'sipProfileId', 'sip_profile_id'),
});

const joinPayload = (call, sessionScope = {}) => ({
  ...callScope(call, sessionScope),
  callDirection: 'outbound',
  callRef: valueFor(call, 'callSid', 'call_sid'),
  toNumber: valueFor(call, 'toNumber', 'to_number', 'to'),
});

export const hasPendingOutboundCall = () => activeAttempts.size > 0;

export const startOutboundBrowserCall = ({
  call,
  sessionScope = {},
  onJoined = null,
  onFailed = null,
} = {}) => {
  const callSid = valueFor(call, 'callSid', 'call_sid');
  if (!callSid) return Promise.reject(new Error('call_sid_missing'));
  if (activeAttempts.has(String(callSid))) {
    return activeAttempts.get(String(callSid));
  }
  if (activeAttempts.size > 0) {
    return Promise.reject(new Error('sip_outbound_call_in_progress'));
  }

  const attempt = (async () => {
    try {
      const result = await WebphoneClient.joinClientCall(
        joinPayload(call, sessionScope)
      );
      if (!result) throw new Error('sip_invite_not_received');
      await onJoined?.(result);
      return result;
    } catch (error) {
      const reason = outboundFailureReason(error);
      await VoiceAPI.rejectIncomingCall(callSid, {
        status: 'failed',
        reason,
      }).catch(() => null);
      await onFailed?.({ error, reason });
      throw Object.assign(error instanceof Error ? error : new Error(reason), {
        reason,
      });
    } finally {
      activeAttempts.delete(String(callSid));
    }
  })();

  activeAttempts.set(String(callSid), attempt);
  return attempt;
};

export const resetOutboundCallCoordinatorForTests = () => {
  activeAttempts.clear();
};
