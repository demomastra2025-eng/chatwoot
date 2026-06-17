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

function extractCallData(message) {
  const contentData = getContentData(message);
  const contentMeta = getContentMeta(contentData);

  return {
    callSid: contentData.call_sid || contentData.callSid,
    status: contentData.status,
    callDirection: contentData.call_direction || contentData.callDirection,
    conversationId: message?.conversation_id,
    inboxId:
      message?.inbox_id ||
      contentData.inbox_id ||
      contentData.inboxId ||
      contentMeta?.chatwoot_inbox_id ||
      contentMeta?.inbox_id ||
      contentMeta?.inboxId,
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
  };
}

export function handleVoiceCallCreated(message, currentUserId) {
  if (!isVoiceCallMessage(message)) return;

  // WhatsApp calls are managed by their own store (whatsappCalls),
  // don't add them to the Twilio/Fonoster calls store.
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
  } = extractCallData(message);

  // Vuex message/conversation status updates apply to all call sources.
  const callInfo = { conversationId, callSid, callStatus: status };
  commit(types.UPDATE_CONVERSATION_CALL_STATUS, callInfo);
  commit(types.UPDATE_MESSAGE_CALL_STATUS, callInfo);

  // Twilio/Fonoster store interactions are not used for WhatsApp Cloud calls.
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
    });
  }
}
