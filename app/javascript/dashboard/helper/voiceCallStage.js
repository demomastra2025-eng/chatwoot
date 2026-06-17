export const OUTBOUND_CALL_STAGE_LABEL_KEYS = {
  CONNECTING_OPERATOR: 'CONVERSATION.VOICE_WIDGET.OUTGOING_CONNECTING_OPERATOR',
  CALLING_CUSTOMER: 'CONVERSATION.VOICE_WIDGET.OUTGOING_CALLING_CUSTOMER',
  CUSTOMER_RINGING: 'CONVERSATION.VOICE_WIDGET.OUTGOING_CLIENT_RINGING',
  IN_PROGRESS: 'CONVERSATION.VOICE_WIDGET.CALL_IN_PROGRESS',
};

const normalizeStageToken = value =>
  value?.toString()?.trim()?.toLowerCase()?.replaceAll('-', '_') || '';

const isOutboundCall = call => call?.callDirection === 'outbound';

const isCustomerLeg = call =>
  ['callee', 'customer', 'client'].includes(normalizeStageToken(call?.callLeg));

export const getOutboundCallStage = call => {
  if (!isOutboundCall(call)) return { labelKey: '', showDuration: false };

  const status = normalizeStageToken(call?.status);
  const event = normalizeStageToken(call?.callEvent);
  const rawStatus = normalizeStageToken(call?.rawStatus);
  const customerLeg = isCustomerLeg(call);
  const answeredStatuses = ['answered', 'answer', 'up', 'in_progress'];

  if (
    ['callee_answered', 'customer_answered', 'client_answered'].includes(
      event
    ) ||
    (event === 'answered' && customerLeg) ||
    (customerLeg && answeredStatuses.includes(status)) ||
    (event === 'dial_status' &&
      customerLeg &&
      answeredStatuses.includes(rawStatus))
  ) {
    return {
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.IN_PROGRESS,
      showDuration: true,
    };
  }

  if (
    ['callee_ringing', 'customer_ringing', 'client_ringing'].includes(event) ||
    (event === 'dial_status' &&
      customerLeg &&
      ['ringing', 'progress', 'early_media'].includes(rawStatus))
  ) {
    return {
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.CUSTOMER_RINGING,
      showDuration: false,
    };
  }

  if (
    [
      'operator_answered',
      'callee_dial_started',
      'customer_dial_started',
      'client_dial_started',
    ].includes(event) ||
    (event === 'dial_status' && customerLeg)
  ) {
    return {
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.CALLING_CUSTOMER,
      showDuration: false,
    };
  }

  if (status === 'in_progress') {
    return {
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.IN_PROGRESS,
      showDuration: true,
    };
  }

  return {
    labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.CONNECTING_OPERATOR,
    showDuration: false,
  };
};

export const getOutboundCallStageLabelKey = call =>
  getOutboundCallStage(call).labelKey;

export const outboundCallStageShowsDuration = call =>
  getOutboundCallStage(call).showDuration;
