import { INBOX_TYPES } from './inbox';

export const WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL = 30 * 1000;

const CONNECTED_LIFECYCLE_STATE = 'connected';
const OPEN_CONNECTION_STATE = 'open';

export const getWhatsappWebState = inbox => {
  return inbox?.additional_attributes?.evolution || {};
};

export const isWhatsappWebInbox = inbox => {
  return inbox?.channel_type === INBOX_TYPES.WHATSAPP_WEB;
};

export const isWhatsappWebConnected = inbox => {
  if (!isWhatsappWebInbox(inbox)) {
    return false;
  }

  const state = getWhatsappWebState(inbox);

  return (
    state.status === CONNECTED_LIFECYCLE_STATE &&
    state.connection_state === OPEN_CONNECTION_STATE
  );
};

export const hasWhatsappWebConnectionIssue = inbox => {
  return isWhatsappWebInbox(inbox) && !isWhatsappWebConnected(inbox);
};
