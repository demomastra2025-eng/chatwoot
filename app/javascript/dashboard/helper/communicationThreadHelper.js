import { MESSAGE_TYPE } from 'shared/constants/messages';

export const isCommunicationThread = chat => {
  return Boolean(
    chat?.is_communication_thread || chat?.communication_thread_id
  );
};

const sortByNewestMessage = (firstMessage, secondMessage) => {
  const createdAtDifference =
    Number(secondMessage?.created_at || 0) -
    Number(firstMessage?.created_at || 0);
  if (createdAtDifference !== 0) return createdAtDifference;

  return Number(secondMessage?.id || 0) - Number(firstMessage?.id || 0);
};

const sortByNewestChannelActivity = (firstChannel, secondChannel) => {
  const activityDifference =
    Number(secondChannel?.last_activity_at || 0) -
    Number(firstChannel?.last_activity_at || 0);
  if (activityDifference !== 0) return activityDifference;

  return (
    Number(secondChannel?.conversation_id || 0) -
    Number(firstChannel?.conversation_id || 0)
  );
};

const isIncomingMessage = message => {
  return (
    message?.message_type === MESSAGE_TYPE.INCOMING ||
    message?.message_type === 'incoming'
  );
};

const channelForMessage = (channels, message) => {
  return channels.find(
    channel =>
      String(channel.conversation_id) === String(message?.conversation_id)
  );
};

const getLatestIncomingReplyableChannel = (channels, messages = []) => {
  const latestIncomingMessage = [...messages]
    .filter(message => {
      const channel = channelForMessage(channels, message);
      return isIncomingMessage(message) && channel?.can_reply;
    })
    .sort(sortByNewestMessage)[0];

  return latestIncomingMessage
    ? channelForMessage(channels, latestIncomingMessage)
    : null;
};

export const getPrimaryCommunicationChannel = channels => {
  if (!Array.isArray(channels) || !channels.length) return null;
  return channels.find(channel => channel.primary) || channels[0];
};

export const getDefaultReplyChannel = (channels, messages = []) => {
  if (!Array.isArray(channels) || !channels.length) return null;

  const latestIncomingReplyableChannel = getLatestIncomingReplyableChannel(
    channels,
    messages
  );
  if (latestIncomingReplyableChannel) return latestIncomingReplyableChannel;

  const replyableChannels = channels.filter(channel => channel.can_reply);
  if (replyableChannels.length) {
    return [...replyableChannels].sort(sortByNewestChannelActivity)[0];
  }

  return getPrimaryCommunicationChannel(channels);
};

export const getCommunicationReplyChannel = (chat, conversationId = null) => {
  const channels = Array.isArray(chat?.channels) ? chat.channels : [];
  if (!channels.length) return null;

  if (conversationId) {
    const selectedChannel = channels.find(
      channel =>
        String(channel.channel_key) === String(conversationId) ||
        String(channel.conversation_id) === String(conversationId)
    );
    if (selectedChannel) return selectedChannel;
  }

  return getDefaultReplyChannel(channels, chat?.messages || []);
};

const CHANNEL_LABELS = {
  'Channel::WebWidget': 'Web',
  'Channel::Api': 'API',
  'Channel::Email': 'Email',
  'Channel::TwilioSms': 'SMS',
  'Channel::Sms': 'SMS',
  'Channel::Telegram': 'Telegram',
  'Channel::TelegramPersonal': 'Telegram',
  'Channel::Whatsapp': 'WhatsApp',
  'Channel::WhatsappWeb': 'WhatsApp',
  'Channel::Line': 'LINE',
  'Channel::FacebookPage': 'Facebook',
  'Channel::Instagram': 'Instagram',
  'Channel::Voice': 'Voice',
};

export const getCommunicationChannelLabel = channel => {
  if (!channel) return '';

  return (
    channel.inbox_name ||
    CHANNEL_LABELS[channel.channel] ||
    channel.channel?.replace('Channel::', '') ||
    `#${channel.inbox_id}`
  );
};

export const isMessageInCommunicationThread = (chat, message) => {
  if (!isCommunicationThread(chat)) return false;
  if (message?.communication_thread_id) {
    return String(chat.id) === String(message.communication_thread_id);
  }

  const conversationIds = chat.conversation_ids || [];
  return conversationIds.some(
    conversationId =>
      String(conversationId) === String(message?.conversation_id)
  );
};

export const buildCommunicationChannelFromMessage = message => {
  if (!message?.conversation_id || !message?.inbox_id) return null;

  return {
    conversation_id: message.conversation_id,
    inbox_id: message.inbox_id,
    inbox_name: message.inbox_name,
    contact_inbox_id: message.contact_inbox_id,
    channel: message.channel,
    can_reply: isIncomingMessage(message),
    can_send_text: isIncomingMessage(message),
    can_send_attachments: isIncomingMessage(message),
    requires_template: false,
    reply_window_open: isIncomingMessage(message),
    reauthorization_required: false,
    disabled: !isIncomingMessage(message),
    disabled_reason: isIncomingMessage(message) ? null : 'not_replyable',
    primary: false,
    last_activity_at: message.created_at || 0,
    channel_key: `conversation:${message.conversation_id}`,
  };
};

const compactPayload = payload => {
  return Object.fromEntries(
    Object.entries(payload).filter(
      ([, value]) => value !== undefined && value !== null && value !== ''
    )
  );
};

export const decoratePayloadWithCommunicationThread = (
  payload,
  chat,
  selectedChannelIdentifier = null
) => {
  if (!isCommunicationThread(chat)) return payload;

  const replyChannel = getCommunicationReplyChannel(
    chat,
    selectedChannelIdentifier || payload.channelKey || payload.conversationId
  );
  if (!replyChannel) return payload;

  return {
    ...payload,
    ...compactPayload({
      conversationId: replyChannel.conversation_id,
      communicationThreadId: chat.id,
      channelKey: replyChannel.channel_key,
      targetInboxId: replyChannel.inbox_id,
      targetContactInboxId: replyChannel.contact_inbox_id,
      inbox_id: replyChannel.inbox_id,
      inbox_name: replyChannel.inbox_name,
      contact_inbox_id: replyChannel.contact_inbox_id,
      channel: replyChannel.channel,
      medium: replyChannel.medium,
    }),
  };
};

export const buildCommunicationThreadConversation = thread => {
  const channels = Array.isArray(thread?.channels) ? thread.channels : [];
  const messages = Array.isArray(thread?.messages) ? thread.messages : [];
  const primaryChannel = getPrimaryCommunicationChannel(channels) || {};
  const replyChannel =
    getDefaultReplyChannel(channels, messages) || primaryChannel;

  return {
    ...thread,
    id: thread.id,
    display_id: thread.id,
    communication_thread_id: thread.id,
    is_communication_thread: true,
    inbox_id: replyChannel?.inbox_id || primaryChannel?.inbox_id || null,
    active_reply_channel_conversation_id: replyChannel?.conversation_id || null,
    active_reply_channel_key: replyChannel?.channel_key || null,
    active_reply_channel_inbox_id: replyChannel?.inbox_id || null,
    active_reply_channel: replyChannel || null,
    can_reply: channels.some(channel => channel.can_reply),
    conversation_ids:
      thread.conversation_ids ||
      channels.map(channel => channel.conversation_id).filter(Boolean),
    labels: thread.labels || [],
    custom_attributes: thread.custom_attributes || {},
    additional_attributes: thread.additional_attributes || {},
    agent_last_seen_at: thread.agent_last_seen_at || 0,
    first_reply_created_at: thread.first_reply_created_at || null,
    waiting_since: thread.waiting_since || null,
    messages,
    meta: {
      ...(thread.meta || {}),
      sender: thread.meta?.sender || thread.contact || {},
      assignee: thread.meta?.assignee || null,
      team: thread.meta?.team || null,
    },
  };
};
