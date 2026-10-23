import {
  getWhatsappWebConnectionState,
  getWhatsappWebLifecycleState,
  isInboxPendingDeletion,
  isWhatsappWebConnected,
} from 'dashboard/helper/whatsappWeb';

// One status a manager can read at a glance: connected, connecting or no
// connection. It is derived from the same live lifecycle and connection fields
// the channel settings page already reads, so there is never a second opinion.
export const CONNECTION_STATUS = {
  CONNECTED: 'connected',
  CONNECTING: 'connecting',
  DISCONNECTED: 'disconnected',
};

const WHATSAPP_WEB_CONNECTING_STATES = [
  'creating',
  'waiting_for_qr',
  'qr_ready',
  'qr_scanned',
  'connecting',
  'reconnecting',
];

const TELEGRAM_PERSONAL_LOGIN_STEPS = [
  'code_sent',
  'qr_ready',
  'password_required',
];

export const getWhatsappWebConnectionStatus = inbox => {
  if (isInboxPendingDeletion(inbox)) {
    return CONNECTION_STATUS.DISCONNECTED;
  }

  if (isWhatsappWebConnected(inbox)) {
    return CONNECTION_STATUS.CONNECTED;
  }

  const lifecycleState = getWhatsappWebLifecycleState(inbox);
  const connectionState = getWhatsappWebConnectionState(inbox);

  if (
    WHATSAPP_WEB_CONNECTING_STATES.includes(lifecycleState) ||
    WHATSAPP_WEB_CONNECTING_STATES.includes(connectionState)
  ) {
    return CONNECTION_STATUS.CONNECTING;
  }

  return CONNECTION_STATUS.DISCONNECTED;
};

export const getTelegramPersonalConnectionStatus = ({
  isConnected = false,
  lifecycleState = '',
  connectionState = '',
} = {}) => {
  if (isConnected && connectionState === 'connected') {
    return CONNECTION_STATUS.CONNECTED;
  }

  if (
    connectionState === 'connecting' ||
    TELEGRAM_PERSONAL_LOGIN_STEPS.includes(lifecycleState)
  ) {
    return CONNECTION_STATUS.CONNECTING;
  }

  return CONNECTION_STATUS.DISCONNECTED;
};
