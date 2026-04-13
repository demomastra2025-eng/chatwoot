import { INBOX_TYPES } from './inbox';

export const TELEGRAM_PERSONAL_SIDEBAR_STATUS_POLL_INTERVAL = 30 * 1000;

const CONNECTED_CONNECTION_STATE = 'connected';
const CONNECTED_LIFECYCLE_STATE = 'connected';
const SETUP_LIFECYCLE_STATES = [
  'pending_auth',
  'code_sent',
  'qr_ready',
  'qr_expired',
  'password_required',
];
const TRANSIENT_LIFECYCLE_STATES = ['reconnecting'];
const TRANSIENT_CONNECTION_STATES = [
  'connecting',
  'reconnecting',
  'flood_wait',
];

export const getTelegramPersonalState = inbox => {
  return inbox?.runtime_state || {};
};

export const isTelegramPersonalInbox = inbox => {
  return inbox?.channel_type === INBOX_TYPES.TELEGRAM_PERSONAL;
};

export const isTelegramPersonalConnected = inbox => {
  if (!isTelegramPersonalInbox(inbox)) {
    return false;
  }

  const state = getTelegramPersonalState(inbox);
  const authState = state.auth_state;
  const lifecycleState =
    authState === 'authorized'
      ? CONNECTED_LIFECYCLE_STATE
      : state.lifecycle_state || inbox?.lifecycle_state;
  const connectionState = state.connection_state || inbox?.connection_state;

  return (
    connectionState === CONNECTED_CONNECTION_STATE &&
    lifecycleState === CONNECTED_LIFECYCLE_STATE
  );
};

export const hasTelegramPersonalConnectionIssue = inbox => {
  if (!isTelegramPersonalInbox(inbox) || isTelegramPersonalConnected(inbox)) {
    return false;
  }

  const state = getTelegramPersonalState(inbox);
  const lifecycleState = state.lifecycle_state || inbox?.lifecycle_state;
  const connectionState = state.connection_state || inbox?.connection_state;

  return !(
    SETUP_LIFECYCLE_STATES.includes(lifecycleState) ||
    TRANSIENT_LIFECYCLE_STATES.includes(lifecycleState) ||
    TRANSIENT_CONNECTION_STATES.includes(connectionState)
  );
};
