import { INBOX_TYPES } from './inbox';

export const WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL = 30 * 1000;

const CONNECTED_LIFECYCLE_STATE = 'connected';
const DELETING_LIFECYCLE_STATE = 'deleting';
const OPEN_CONNECTION_STATE = 'open';
const RECONNECTING_CONNECTION_STATE = 'reconnecting';
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

export const getWhatsappWebLifecycleState = inbox => {
  const state = getWhatsappWebState(inbox);

  return state.status || state.lifecycle_state || inbox?.lifecycle_state || '';
};

export const getWhatsappWebConnectionState = inbox => {
  const state = getWhatsappWebState(inbox);

  return state.connection_state || inbox?.connection_state || '';
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

  return (
    getWhatsappWebLifecycleState(inbox) === CONNECTED_LIFECYCLE_STATE &&
    getWhatsappWebConnectionState(inbox) === OPEN_CONNECTION_STATE
  );
};

export const hasWhatsappWebNonOpenState = inbox => {
  return (
    isWhatsappWebInbox(inbox) &&
    !isInboxPendingDeletion(inbox) &&
    !isWhatsappWebConnected(inbox)
  );
};

export const isWhatsappWebReconnecting = inbox => {
  if (!hasWhatsappWebNonOpenState(inbox)) {
    return false;
  }

  const lifecycleState = getWhatsappWebLifecycleState(inbox);
  const connectionState = getWhatsappWebConnectionState(inbox);

  return (
    lifecycleState === RECONNECTING_CONNECTION_STATE ||
    connectionState === RECONNECTING_CONNECTION_STATE
  );
};

export const isWhatsappWebTransientState = inbox => {
  if (!hasWhatsappWebNonOpenState(inbox)) {
    return false;
  }

  const lifecycleState = getWhatsappWebLifecycleState(inbox);
  const connectionState = getWhatsappWebConnectionState(inbox);

  return (
    TRANSIENT_LIFECYCLE_STATES.includes(lifecycleState) ||
    TRANSIENT_CONNECTION_STATES.includes(connectionState)
  );
};

export const getWhatsappWebDisplayLabel = inbox => {
  const state = getWhatsappWebState(inbox);
  const number =
    state.number || inbox?.phone_number || inbox?.channel?.phone_number || '';
  const name = inbox?.name || state.instance_name || '';

  if (number && name && name !== number) {
    return `${name} (${number})`;
  }

  return number || name || `#${inbox?.id || ''}`;
};

export const hasWhatsappWebAuthenticationArtifacts = inbox => {
  const qrcode = getWhatsappWebState(inbox).qrcode || {};

  return Boolean(
    qrcode.base64 || qrcode.code || qrcode.pairingCode || qrcode.pairing_code
  );
};

const shouldRequestWhatsappWebQr = inbox => {
  if (!isWhatsappWebInbox(inbox)) {
    return false;
  }

  if (isInboxPendingDeletion(inbox) || isWhatsappWebConnected(inbox)) {
    return false;
  }

  if (hasWhatsappWebAuthenticationArtifacts(inbox)) {
    return false;
  }

  const lifecycleState = getWhatsappWebLifecycleState(inbox);
  const connectionState = getWhatsappWebConnectionState(inbox);

  return (
    lifecycleState !== CONNECTED_LIFECYCLE_STATE ||
    connectionState !== OPEN_CONNECTION_STATE
  );
};

export const shouldRequestWhatsappWebQrAfterRepair = inbox => {
  if (isWhatsappWebReconnecting(inbox)) {
    return false;
  }

  return shouldRequestWhatsappWebQr(inbox);
};

export const shouldRequestWhatsappWebQrAfterReconnect = inbox => {
  return shouldRequestWhatsappWebQr(inbox);
};

export const hasWhatsappWebConnectionIssue = inbox => {
  const lifecycleState = getWhatsappWebLifecycleState(inbox);
  const connectionState = getWhatsappWebConnectionState(inbox);

  return (
    hasWhatsappWebNonOpenState(inbox) &&
    !TRANSIENT_LIFECYCLE_STATES.includes(lifecycleState) &&
    !TRANSIENT_CONNECTION_STATES.includes(connectionState)
  );
};

export const hasWhatsappWebImportInProgress = inbox => {
  if (!isWhatsappWebInbox(inbox)) {
    return false;
  }

  return Boolean(getWhatsappWebState(inbox).history_sync_in_progress);
};

export const getWhatsappWebImportAlertKey = inbox => {
  const state = getWhatsappWebState(inbox);
  const requestedAt = state.history_sync_requested_at || 'active';

  return `whatsapp:import:${inbox?.id}:${requestedAt}`;
};
