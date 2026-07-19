import { CONTENT_TYPES } from 'dashboard/components-next/message/constants';
import { useCallsStore } from 'dashboard/stores/calls';
import types from 'dashboard/store/mutation-types';

export const TERMINAL_STATUSES = [
  'completed',
  'busy',
  'failed',
  'no_answer',
  'no-answer',
  'cancelled',
  'canceled',
  'rejected',
  'missed',
  'ended',
];

export const isInbound = direction => direction === 'inbound';

const isVoiceCallMessage = message => {
  return CONTENT_TYPES.VOICE_CALL === message?.content_type;
};

const isWhatsappCall = message => {
  return message?.content_attributes?.data?.call_source === 'whatsapp';
};

const shouldSkipCall = (callDirection, senderId, currentUserId) => {
  return callDirection === 'outbound' && senderId !== currentUserId;
};

const getContentData = message => message?.content_attributes?.data || {};

const getContentMeta = contentData =>
  contentData?.metadata || contentData?.meta || {};

const normalizeOperatorClaim = claim => {
  if (!claim || typeof claim !== 'object') return null;
  return claim;
};

function extractCallData(message) {
  const contentData = getContentData(message);
  const contentMeta = getContentMeta(contentData);

  return {
    callSid: contentData.call_sid || contentData.callSid,
    accountId:
      contentData.account_id ||
      contentData.accountId ||
      contentMeta?.account_id ||
      contentMeta?.accountId,
    status: contentData.status,
    callDirection: contentData.call_direction || contentData.callDirection,
    conversationId: message?.conversation_id,
    conversationDisplayId:
      contentData.conversation_display_id ||
      contentData.conversationDisplayId ||
      contentMeta?.conversation_display_id ||
      contentMeta?.conversationDisplayId,
    communicationThreadId:
      message?.communication_thread_id ||
      message?.communicationThreadId ||
      contentData.communication_thread_id ||
      contentData.communicationThreadId ||
      contentMeta?.communication_thread_id ||
      contentMeta?.communicationThreadId,
    conversationDbId:
      contentData.conversation_db_id ||
      contentData.conversationDbId ||
      contentMeta?.conversation_db_id ||
      contentMeta?.conversationDbId,
    inboxId:
      message?.inbox_id ||
      contentData.inbox_id ||
      contentData.inboxId ||
      contentMeta?.chatwoot_inbox_id ||
      contentMeta?.inbox_id ||
      contentMeta?.inboxId,
    numberRef:
      contentData.number_ref ||
      contentData.numberRef ||
      contentMeta?.number_ref ||
      contentMeta?.numberRef,
    logicalCallKey:
      contentData.logical_call_key ||
      contentData.logicalCallKey ||
      contentData.call_group_key ||
      contentData.callGroupKey ||
      contentMeta?.logical_call_key ||
      contentMeta?.logicalCallKey ||
      contentMeta?.call_group_key ||
      contentMeta?.callGroupKey,
    logicalCallTerminal:
      contentData.logical_call_terminal ??
      contentData.logicalCallTerminal ??
      contentMeta?.logical_call_terminal ??
      contentMeta?.logicalCallTerminal,
    sipProfileId:
      contentData.sip_profile_id ||
      contentData.sipProfileId ||
      contentMeta?.sip_profile_id ||
      contentMeta?.sipProfileId,
    janusSessionKey:
      contentData.janus_session_key ||
      contentData.janusSessionKey ||
      contentMeta?.janus_session_key ||
      contentMeta?.janusSessionKey,
    provider:
      contentData.provider ||
      message?.provider ||
      contentMeta?.provider ||
      contentMeta?.chatwoot_provider,
    senderId: message?.sender?.id,
    callEvent:
      contentData.event_type ||
      contentData.eventType ||
      contentData.call_event ||
      contentData.callEvent ||
      contentMeta?.latest_event_type ||
      contentMeta?.event_type,
    callLeg:
      contentData.leg ||
      contentData.leg_type ||
      contentData.legType ||
      contentMeta?.latest_leg,
    rawStatus:
      contentData.raw_status ||
      contentData.rawStatus ||
      contentMeta?.latest_raw_status ||
      contentMeta?.latest_leg_status,
    fromNumber:
      contentData.from_number ||
      contentData.fromNumber ||
      contentMeta?.from_number ||
      contentMeta?.fromNumber,
    toNumber:
      contentData.to_number ||
      contentData.toNumber ||
      contentMeta?.to_number ||
      contentMeta?.toNumber,
    caller: contentData.caller || contentMeta?.caller,
    contactId:
      contentData.contact_id ||
      contentData.contactId ||
      contentMeta?.contact_id ||
      contentMeta?.contactId,
    operatorClaim: normalizeOperatorClaim(
      contentData.operator_claim ||
        contentData.operatorClaim ||
        contentMeta?.operator_claim ||
        contentMeta?.operatorClaim
    ),
    operatorCandidates:
      contentData.operator_candidates ||
      contentData.operatorCandidates ||
      contentMeta?.operator_candidates ||
      contentMeta?.operatorCandidates,
    operatorInternalExtension:
      contentData.operator_internal_extension ||
      contentData.operatorInternalExtension ||
      contentMeta?.operator_internal_extension ||
      contentMeta?.operatorInternalExtension,
  };
}

export function handleVoiceCallCreated(message, currentUserId) {
  if (!isVoiceCallMessage(message)) return;

  // WhatsApp calls are managed by their own store (whatsappCalls),
  // don't add them to the browser call store.
  if (isWhatsappCall(message)) return;

  const {
    callSid,
    status,
    callDirection,
    conversationId,
    inboxId,
    provider,
    senderId,
    callEvent,
    callLeg,
    rawStatus,
    fromNumber,
    toNumber,
    caller,
    operatorClaim,
    operatorCandidates,
    operatorInternalExtension,
    accountId,
    conversationDbId,
    conversationDisplayId,
    communicationThreadId,
    contactId,
    logicalCallKey,
    logicalCallTerminal,
    sipProfileId,
    janusSessionKey,
    numberRef,
  } = extractCallData(message);

  if (shouldSkipCall(callDirection, senderId, currentUserId)) return;
  if (TERMINAL_STATUSES.includes(status)) {
    const callsStore = useCallsStore();
    callsStore.handleCallStatusChanged({
      callSid,
      status,
      conversationId,
      inboxId,
      provider,
      callDirection,
      senderId,
      callEvent,
      callLeg,
      rawStatus,
      fromNumber,
      toNumber,
      caller,
      operatorClaim,
      operatorCandidates,
      operatorInternalExtension,
      accountId,
      conversationDbId,
      conversationDisplayId,
      communicationThreadId,
      contactId,
      logicalCallKey,
      logicalCallTerminal,
      sipProfileId,
      janusSessionKey,
      numberRef,
    });
    return;
  }

  const callsStore = useCallsStore();
  callsStore.addCall({
    callSid,
    status,
    conversationId,
    inboxId,
    provider,
    callDirection,
    senderId,
    callEvent,
    callLeg,
    rawStatus,
    fromNumber,
    toNumber,
    caller,
    operatorClaim,
    operatorCandidates,
    operatorInternalExtension,
    accountId,
    conversationDbId,
    conversationDisplayId,
    communicationThreadId,
    contactId,
    logicalCallKey,
    logicalCallTerminal,
    sipProfileId,
    janusSessionKey,
    numberRef,
  });
}

export function handleVoiceCallUpdated(commit, message, currentUserId) {
  if (!isVoiceCallMessage(message)) return;

  const {
    callSid,
    status,
    callDirection,
    conversationId,
    inboxId,
    provider,
    senderId,
    callEvent,
    callLeg,
    rawStatus,
    fromNumber,
    toNumber,
    caller,
    operatorClaim,
    operatorCandidates,
    operatorInternalExtension,
    accountId,
    conversationDbId,
    conversationDisplayId,
    communicationThreadId,
    contactId,
    logicalCallKey,
    logicalCallTerminal,
    sipProfileId,
    janusSessionKey,
    numberRef,
  } = extractCallData(message);

  // Vuex message/conversation status updates apply to all call sources.
  const callInfo = {
    conversationId,
    callSid,
    callStatus: status,
    callData: getContentData(message),
  };
  commit(types.UPDATE_CONVERSATION_CALL_STATUS, callInfo);
  commit(types.UPDATE_MESSAGE_CALL_STATUS, callInfo);

  // Browser call store interactions are not used for WhatsApp Cloud calls.
  if (isWhatsappCall(message)) return;

  const callsStore = useCallsStore();

  callsStore.handleCallStatusChanged({
    callSid,
    status,
    conversationId,
    inboxId,
    provider,
    callDirection,
    senderId,
    callEvent,
    callLeg,
    rawStatus,
    fromNumber,
    toNumber,
    caller,
    operatorClaim,
    operatorCandidates,
    operatorInternalExtension,
    accountId,
    conversationDbId,
    conversationDisplayId,
    communicationThreadId,
    contactId,
    logicalCallKey,
    logicalCallTerminal,
    sipProfileId,
    janusSessionKey,
    numberRef,
  });

  const isNewCall =
    status === 'ringing' &&
    !shouldSkipCall(callDirection, senderId, currentUserId);

  if (isNewCall) {
    callsStore.addCall({
      callSid,
      status,
      conversationId,
      inboxId,
      provider,
      callDirection,
      senderId,
      callEvent,
      callLeg,
      rawStatus,
      fromNumber,
      toNumber,
      caller,
      operatorClaim,
      operatorCandidates,
      operatorInternalExtension,
      accountId,
      conversationDbId,
      conversationDisplayId,
      communicationThreadId,
      contactId,
      logicalCallKey,
      logicalCallTerminal,
      sipProfileId,
      janusSessionKey,
      numberRef,
    });
  }
}
