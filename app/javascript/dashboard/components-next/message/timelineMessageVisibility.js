import { MESSAGE_TYPES } from './constants';

const NOISY_ACTIVITY_ACTIONS = new Set([
  'ai_speaking',
  'business_faq_gate_fired',
  'business_faq_gate_result_injected',
  'caller_interrupted',
  'direct_tool_context_barrier_timeout',
  'direct_tool_speech_deferred',
  'direct_tool_speech_not_started',
  'faq_check_started',
  'faq_check_completed',
  'faq_result_ready',
  'faq_gate_released',
  'faq_gate_waiting',
  'incomplete_answer_model_stall',
  'ordinary_model_stall',
  'ordinary_answer_model_stall',
  'post_tool_model_stall',
  'incomplete_tool_call_wait',
  'terminal_confirmation_missing',
  'tool_started',
  'tool_progress',
  'tool_completed',
  'tool_failed',
  'tool_suppressed',
  'tool_async_completed',
  'tool_result_deferred',
  'tool_result_delivery_completed',
  'tool_result_delivery_failed',
]);

const NOISY_SOURCE_ACTION_PATTERN = new RegExp(
  `:(${[...NOISY_ACTIVITY_ACTIONS].join('|')}):`
);

const activityAction = message => {
  const data = message.contentAttributes?.data || {};
  return data.action || data.type;
};

const noisySourceAction = message => {
  const sourceId = message.sourceId || '';
  return sourceId.match(NOISY_SOURCE_ACTION_PATTERN)?.[1];
};

export const isUsefulTimelineMessage = message => {
  if (message.messageType !== MESSAGE_TYPES.ACTIVITY) return true;

  return (
    !noisySourceAction(message) &&
    !NOISY_ACTIVITY_ACTIONS.has(activityAction(message))
  );
};

export const deduplicateThreadActivityMessages = messages => {
  const lastActivityByContent = new Map();

  return messages.filter(message => {
    if (message.messageType !== MESSAGE_TYPES.ACTIVITY) return true;

    const eventId = message.additionalAttributes?.communicationThreadEventId;
    const content = message.content?.trim();
    if (!eventId || !content) return true;

    const eventKey = `${eventId}:${content}`;
    const previous = lastActivityByContent.get(eventKey);
    const isCrossChannelDuplicate =
      previous && previous.conversationId !== message.conversationId;

    if (isCrossChannelDuplicate) return false;

    lastActivityByContent.set(eventKey, message);
    return true;
  });
};
