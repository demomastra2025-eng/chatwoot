import {
  getWhatsappWebConnectionState,
  getWhatsappWebLifecycleState,
  isInboxPendingDeletion,
  isWhatsappWebConnected,
} from 'dashboard/helper/whatsappWeb';
import { WHATSAPP_WEB_BROKEN_LIFECYCLE_STATES } from './inboxHealthStatus';

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

const WEIXIN_LOGIN_STEPS = ['qr_ready', 'qr_scanned'];

const normalizeState = value =>
  String(value || '')
    .trim()
    .toLowerCase();

export const getWhatsappWebConnectionStatus = inbox => {
  if (isInboxPendingDeletion(inbox)) {
    return CONNECTION_STATUS.DISCONNECTED;
  }

  if (isWhatsappWebConnected(inbox)) {
    return CONNECTION_STATUS.CONNECTED;
  }

  const lifecycleState = normalizeState(getWhatsappWebLifecycleState(inbox));
  const connectionState = normalizeState(getWhatsappWebConnectionState(inbox));

  // A failed or closed session is «Нет связи» even when the connection state
  // was left on «connecting» (a failed reconnect does not reset it). This is
  // the same order the channels list uses.
  if (WHATSAPP_WEB_BROKEN_LIFECYCLE_STATES.includes(lifecycleState)) {
    return CONNECTION_STATUS.DISCONNECTED;
  }

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

// WeChat keeps a QR login session like Telegram (personal). It is connected
// only when the connection is up and the login is complete, which is also what
// the channels list shows.
export const getWeixinConnectionStatus = ({
  lifecycleState = '',
  connectionState = '',
} = {}) => {
  const lifecycle = normalizeState(lifecycleState);
  const connection = normalizeState(connectionState);

  if (connection === 'connected' && (!lifecycle || lifecycle === 'connected')) {
    return CONNECTION_STATUS.CONNECTED;
  }

  if (connection === 'connecting' || WEIXIN_LOGIN_STEPS.includes(lifecycle)) {
    return CONNECTION_STATUS.CONNECTING;
  }

  return CONNECTION_STATUS.DISCONNECTED;
};
