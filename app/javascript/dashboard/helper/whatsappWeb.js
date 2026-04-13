import { INBOX_TYPES } from './inbox';

export const WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL = 30 * 1000;

const CONNECTED_LIFECYCLE_STATE = 'connected';
const DELETING_LIFECYCLE_STATE = 'deleting';
const OPEN_CONNECTION_STATE = 'open';
const TRANSIENT_LIFECYCLE_STATES = [
  'creating',
  'waiting_for_qr',
  'qr_ready',
  'reconnecting',
];
const TRANSIENT_CONNECTION_STATES = ['connecting', 'reconnecting'];

export const getWhatsappWebState = inbox => {
  return inbox?.additional_attributes?.evolution || {};
};

export const isWhatsappWebInbox = inbox => {
  return inbox?.channel_type === INBOX_TYPES.WHATSAPP_WEB;
};

export const isInboxPendingDeletion = inbox => {
  if (!inbox) {
    return false;
  }

  const state = getWhatsappWebState(inbox);

  return Boolean(
    inbox.deleting ||
      inbox.deleting_at ||
      inbox.lifecycle_state === DELETING_LIFECYCLE_STATE ||
      state.status === DELETING_LIFECYCLE_STATE
  );
};

export const isWhatsappWebConnected = inbox => {
  if (!isWhatsappWebInbox(inbox)) {
    return false;
  }

  if (isInboxPendingDeletion(inbox)) {
    return false;
  }

  const state = getWhatsappWebState(inbox);

  return (
    state.status === CONNECTED_LIFECYCLE_STATE &&
    state.connection_state === OPEN_CONNECTION_STATE
  );
};

export const hasWhatsappWebConnectionIssue = inbox => {
  const state = getWhatsappWebState(inbox);
  const lifecycleState = state.status || inbox?.lifecycle_state;
  const connectionState = state.connection_state || inbox?.connection_state;

  return (
    isWhatsappWebInbox(inbox) &&
    !isInboxPendingDeletion(inbox) &&
    !isWhatsappWebConnected(inbox) &&
    !TRANSIENT_LIFECYCLE_STATES.includes(lifecycleState) &&
    !TRANSIENT_CONNECTION_STATES.includes(connectionState)
  );
};
