import { INBOX_TYPES } from 'dashboard/helper/inbox';
import {
  MESSAGE_STATUS,
  MESSAGE_TYPES,
} from 'dashboard/components-next/message/constants';

// Channels whose sent/delivered/read state is only trustworthy once the
// provider has accepted the message and returned its external id. These lists
// mirror the bubble status rules in components-next/message/MessageMeta.vue so
// the conversation list never shows a check mark before the thread does.
const PROVIDER_SENT_CHANNELS = [
  INBOX_TYPES.WHATSAPP,
  INBOX_TYPES.WHATSAPP_WEB,
  INBOX_TYPES.TWILIO,
  INBOX_TYPES.FB,
  INBOX_TYPES.SMS,
  INBOX_TYPES.TELEGRAM,
  INBOX_TYPES.TELEGRAM_PERSONAL,
  INBOX_TYPES.INSTAGRAM,
  INBOX_TYPES.TIKTOK,
];

const PROVIDER_DELIVERED_CHANNELS = [
  INBOX_TYPES.WHATSAPP,
  INBOX_TYPES.WHATSAPP_WEB,
  INBOX_TYPES.TWILIO,
  INBOX_TYPES.SMS,
  INBOX_TYPES.FB,
  INBOX_TYPES.TELEGRAM_PERSONAL,
  INBOX_TYPES.INSTAGRAM,
  INBOX_TYPES.TIKTOK,
];

const PROVIDER_READ_CHANNELS = [
  INBOX_TYPES.WHATSAPP,
  INBOX_TYPES.WHATSAPP_WEB,
  INBOX_TYPES.TWILIO,
  INBOX_TYPES.FB,
  INBOX_TYPES.TELEGRAM_PERSONAL,
  INBOX_TYPES.INSTAGRAM,
  INBOX_TYPES.TIKTOK,
];

const KNOWN_DELIVERY_CHANNELS = new Set([
  ...PROVIDER_SENT_CHANNELS,
  INBOX_TYPES.API,
  INBOX_TYPES.EMAIL,
  INBOX_TYPES.LINE,
  INBOX_TYPES.WEB,
]);

const sourceIdOf = message => message?.source_id ?? message?.sourceId ?? '';

const isReadStatus = (channelType, status, hasSourceId) => {
  if (PROVIDER_READ_CHANNELS.includes(channelType)) {
    return hasSourceId && status === MESSAGE_STATUS.READ;
  }
  if ([INBOX_TYPES.WEB, INBOX_TYPES.API].includes(channelType)) {
    return status === MESSAGE_STATUS.READ;
  }
  return false;
};

const isDeliveredStatus = (channelType, status, hasSourceId) => {
  if (PROVIDER_DELIVERED_CHANNELS.includes(channelType)) {
    return hasSourceId && status === MESSAGE_STATUS.DELIVERED;
  }
  if ([INBOX_TYPES.API, INBOX_TYPES.LINE].includes(channelType)) {
    return status === MESSAGE_STATUS.DELIVERED;
  }
  // Web widget messages are delivered as soon as they are stored.
  if (channelType === INBOX_TYPES.WEB) return status === MESSAGE_STATUS.SENT;
  return false;
};

const isSentStatus = (channelType, status, hasSourceId) => {
  if (channelType === INBOX_TYPES.EMAIL) return hasSourceId;
  if (PROVIDER_SENT_CHANNELS.includes(channelType)) {
    return hasSourceId && status === MESSAGE_STATUS.SENT;
  }
  if (channelType === INBOX_TYPES.API) return status === MESSAGE_STATUS.SENT;
  // Line has no provider id, every stored message counts as sent.
  if (channelType === INBOX_TYPES.LINE) return true;
  return false;
};

/**
 * Resolves the delivery state that should be displayed for an outgoing
 * message. Provider channels keep the "sending" state until the provider has
 * confirmed the message (external source id), even when the local record is
 * already stored with the default `sent` status.
 *
 * @param {Object} message - message payload (snake or camel case)
 * @param {string} channelType - inbox channel type, e.g. `Channel::Whatsapp`
 * @returns {string} one of MESSAGE_STATUS values, or '' when nothing is shown
 */
export const resolveOutgoingDeliveryStatus = (message, channelType) => {
  if (!message) return '';

  const messageType = Number(message.message_type ?? message.messageType);
  if (messageType !== MESSAGE_TYPES.OUTGOING) return '';
  if (message.private) return '';

  const contentAttributes =
    message.content_attributes || message.contentAttributes || {};
  if (contentAttributes.deleted) return '';

  const { status } = message;
  if (status === MESSAGE_STATUS.FAILED) return '';
  if (status === MESSAGE_STATUS.PROGRESS) return MESSAGE_STATUS.PROGRESS;
  // Channels without a delivery model do not get a perpetual "sending" icon.
  if (!KNOWN_DELIVERY_CHANNELS.has(channelType)) return '';

  const hasSourceId = Boolean(sourceIdOf(message));
  if (isReadStatus(channelType, status, hasSourceId)) {
    return MESSAGE_STATUS.READ;
  }
  if (isDeliveredStatus(channelType, status, hasSourceId)) {
    return MESSAGE_STATUS.DELIVERED;
  }
  if (isSentStatus(channelType, status, hasSourceId)) {
    return MESSAGE_STATUS.SENT;
  }

  return MESSAGE_STATUS.PROGRESS;
};
