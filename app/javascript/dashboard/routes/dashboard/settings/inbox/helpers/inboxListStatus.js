import { INBOX_TYPES } from 'dashboard/helper/inbox';
import {
  getWhatsappWebLifecycleState,
  isInboxPendingDeletion,
  isWhatsappWebConnected,
} from 'dashboard/helper/whatsappWeb';
import { getInboxHealthStatus } from './inboxHealthStatus';

// The channels list shows ONE status per channel: it either has a connection
// or it does not. The reason for "no connection" is a short friendly hint, never
// the raw provider error text.

const STATUS_LABEL_KEYS = {
  connected: 'INBOX_MGMT.LIST.STATUS.CONNECTED',
  disconnected: 'INBOX_MGMT.LIST.STATUS.NO_CONNECTION',
};

const HINT_KEYS = {
  reconnect: 'INBOX_MGMT.LIST.HINT.RECONNECT',
  connecting: 'INBOX_MGMT.LIST.HINT.CONNECTING',
  finish_login: 'INBOX_MGMT.LIST.HINT.FINISH_LOGIN',
  temporary: 'INBOX_MGMT.LIST.HINT.TEMPORARY',
  registration: 'INBOX_MGMT.LIST.HINT.REGISTRATION',
  problem: 'INBOX_MGMT.LIST.HINT.PROBLEM',
  channel_missing: 'INBOX_MGMT.LIST.HINT.CHANNEL_MISSING',
  deletion_recovery: 'INBOX_MGMT.LIST.HINT.DELETION_RECOVERY',
  expiring: 'INBOX_MGMT.LIST.HINT.EXPIRING',
};

// Every translation key this helper can hand to the list (checked in the spec).
export const INBOX_LIST_STATUS_I18N_KEYS = [
  ...Object.values(STATUS_LABEL_KEYS),
  ...Object.values(HINT_KEYS),
];

// ruby: the owner has to act (reconnect). amber: it may fix itself or needs a small step.
const REASON_TONES = {
  reconnect: 'ruby',
  channel_missing: 'ruby',
  connecting: 'amber',
  finish_login: 'amber',
  temporary: 'amber',
  registration: 'amber',
  problem: 'amber',
  deletion_recovery: 'amber',
  deleting: 'amber',
};

const HEALTH_REASONS = {
  reauthorization_required: 'reconnect',
  disconnected: 'reconnect',
  pending: 'connecting',
  phone_registration_required: 'registration',
  webhook_signature_invalid: 'problem',
  provider_unavailable: 'temporary',
};

// WhatsApp Web is waiting for the owner to scan the QR code.
const WHATSAPP_WEB_LOGIN_STATES = ['waiting_for_qr', 'qr_ready'];

// Telegram (personal) and WeChat keep a login session that must be `connected`.
const SESSION_CHANNEL_TYPES = [
  INBOX_TYPES.TELEGRAM_PERSONAL,
  INBOX_TYPES.WEIXIN,
];
const SESSION_LOGIN_STATES = [
  'pending_auth',
  'code_sent',
  'qr_ready',
  'password_required',
];
const SESSION_THROTTLED_STATES = ['flood_wait', 'rate_limited'];

const normalizeState = value =>
  String(value ?? '')
    .trim()
    .toLowerCase();

const connected = (reason = 'connected', hintKey = null) => ({
  id: 'connected',
  reason,
  tone: 'teal',
  labelKey: STATUS_LABEL_KEYS.connected,
  hintKey,
  hintTone: hintKey ? 'amber' : null,
});

const noConnection = reason => ({
  id: 'disconnected',
  reason,
  tone: REASON_TONES[reason],
  labelKey: STATUS_LABEL_KEYS.disconnected,
  hintKey: HINT_KEYS[reason] || null,
  hintTone: REASON_TONES[reason],
});

const getGenericStatus = inbox => {
  const health = getInboxHealthStatus(inbox);

  if (!health || health.id === 'connected') {
    return connected();
  }

  if (health.id === 'token_expiring') {
    // Still works today, but will stop soon: stays "connected" with a gentle hint.
    return connected('expiring', HINT_KEYS.expiring);
  }

  return noConnection(HEALTH_REASONS[health.id] || 'reconnect');
};

const getWhatsappWebStatus = inbox => {
  const health = getInboxHealthStatus(inbox);

  // Only a session that is both `connected` and `open` is connected. A stale
  // error text next to a working session must not turn the badge red.
  if (isWhatsappWebConnected(inbox) || health?.id === 'connected') {
    return connected();
  }

  if (
    health?.id === 'pending' &&
    WHATSAPP_WEB_LOGIN_STATES.includes(
      normalizeState(getWhatsappWebLifecycleState(inbox))
    )
  ) {
    return noConnection('finish_login');
  }

  return noConnection(HEALTH_REASONS[health?.id] || 'reconnect');
};

const getSessionStatus = inbox => {
  const connection = normalizeState(inbox.connection_state);
  const lifecycle = normalizeState(inbox.lifecycle_state);

  if (connection === 'connected' && (!lifecycle || lifecycle === 'connected')) {
    return connected();
  }

  if (connection === 'connecting' || lifecycle === 'qr_scanned') {
    return noConnection('connecting');
  }

  if (SESSION_THROTTLED_STATES.includes(connection)) {
    return noConnection('temporary');
  }

  if (SESSION_LOGIN_STATES.includes(lifecycle)) {
    return noConnection('finish_login');
  }

  return noConnection('reconnect');
};

export const getInboxListStatus = inbox => {
  if (!inbox) {
    return null;
  }

  if (isInboxPendingDeletion(inbox)) {
    return noConnection('deleting');
  }

  if (inbox.channel_missing) {
    return noConnection('channel_missing');
  }

  if (inbox.deletion_recovery?.status === 'failed') {
    return noConnection('deletion_recovery');
  }

  if (inbox.channel_type === INBOX_TYPES.WHATSAPP_WEB) {
    return getWhatsappWebStatus(inbox);
  }

  if (SESSION_CHANNEL_TYPES.includes(inbox.channel_type)) {
    return getSessionStatus(inbox);
  }

  return getGenericStatus(inbox);
};
