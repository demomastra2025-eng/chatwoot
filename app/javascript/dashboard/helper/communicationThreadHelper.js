import { MESSAGE_TYPE } from 'shared/constants/messages';
import { timestampInSeconds } from './timestampHelper';

export const isCommunicationThread = chat => {
  return Boolean(
    chat?.is_communication_thread || chat?.communication_thread_id
  );
};

export const matchesCommunicationThreadMode = (
  conversation,
  communicationThreadMode = false
) => isCommunicationThread(conversation) === Boolean(communicationThreadMode);

export const filterConversationsByCommunicationThreadMode = (
  conversations = [],
  communicationThreadMode = false
) => {
  const conversationList = Array.isArray(conversations) ? conversations : [];

  return conversationList.filter(conversation =>
    matchesCommunicationThreadMode(conversation, communicationThreadMode)
  );
};

const sortByNewestMessage = (firstMessage, secondMessage) => {
  const createdAtDifference =
    (timestampInSeconds(secondMessage?.created_at) ?? 0) -
    (timestampInSeconds(firstMessage?.created_at) ?? 0);
  if (createdAtDifference !== 0) return createdAtDifference;

  return Number(secondMessage?.id || 0) - Number(firstMessage?.id || 0);
};

const sortByNewestChannelActivity = (firstChannel, secondChannel) => {
  const activityDifference =
    (timestampInSeconds(secondChannel?.last_activity_at) ?? 0) -
    (timestampInSeconds(firstChannel?.last_activity_at) ?? 0);
  if (activityDifference !== 0) return activityDifference;

  return (
    Number(secondChannel?.conversation_id || 0) -
    Number(firstChannel?.conversation_id || 0)
  );
};

export const isCommunicationVoiceChannel = channel =>
  channel?.channel === 'Channel::Voice';

export const COMMUNICATION_CHANNEL_ACTIONS = {
  MESSAGE: 'message',
  CALL: 'call',
};

const ACTION_KEY_SEPARATOR = ':action:';

const splitCommunicationChannelActionKey = identifier => {
  const value = String(identifier || '');
  const [baseKey, action] = value.split(ACTION_KEY_SEPARATOR);

  return {
    baseKey,
    action: action || null,
  };
};

const communicationChannelBaseKey = channel => {
  if (channel?.message_channel_key) return channel.message_channel_key;
  if (channel?.channel_key) {
    return splitCommunicationChannelActionKey(channel.channel_key).baseKey;
  }
  if (channel?.conversation_id) {
    return `conversation:${channel.conversation_id}`;
  }
  if (channel?.inbox_id) return `inbox:${channel.inbox_id}`;
  return null;
};

const communicationChannelAction = channel => {
  if (channel?.communication_action) return channel.communication_action;
  if (channel?.channel_key) {
    const { action } = splitCommunicationChannelActionKey(channel.channel_key);
    if (action) return action;
  }
  return COMMUNICATION_CHANNEL_ACTIONS.MESSAGE;
};

const communicationChannelActionKey = (
  channel,
  action = COMMUNICATION_CHANNEL_ACTIONS.MESSAGE
) => {
  const baseKey = communicationChannelBaseKey(channel);
  if (!baseKey) return null;

  if (action === COMMUNICATION_CHANNEL_ACTIONS.CALL) {
    return `${baseKey}${ACTION_KEY_SEPARATOR}${action}`;
  }

  return baseKey;
};

export const isCommunicationWhatsappCallChannel = channel =>
  channel?.channel === 'Channel::Whatsapp' &&
  communicationChannelAction(channel) === COMMUNICATION_CHANNEL_ACTIONS.CALL;

export const isCommunicationCallChannel = channel =>
  isCommunicationVoiceChannel(channel) ||
  isCommunicationWhatsappCallChannel(channel);

const isCommunicationWhatsappCallAvailable = channel =>
  channel?.channel === 'Channel::Whatsapp' &&
  channel?.can_call === true &&
  channel?.conversation_id &&
  channel?.disabled !== true;

const isCommunicationMessageActionable = channel =>
  Boolean(
    channel?.can_reply || channel?.can_send_text || channel?.requires_template
  );

export const isCommunicationChannelReplyable = channel => {
  const canCall =
    (isCommunicationVoiceChannel(channel) ||
      isCommunicationWhatsappCallAvailable(channel) ||
      isCommunicationCallChannel(channel)) &&
    channel?.disabled !== true;

  return Boolean(
    channel?.can_reply ||
      channel?.can_send_text ||
      channel?.requires_template ||
      canCall
  );
};

const communicationChannelIdentity = channel => {
  return communicationChannelBaseKey(channel);
};

const isBetterCommunicationChannel = (candidate, current) => {
  if (!current) return true;

  const candidateScore = [
    isCommunicationChannelReplyable(candidate) ? 1 : 0,
    candidate?.can_send_text ? 1 : 0,
    candidate?.reply_window_open ? 1 : 0,
    timestampInSeconds(candidate?.last_activity_at) ?? 0,
    Number(candidate?.conversation_id || 0),
  ];
  const currentScore = [
    isCommunicationChannelReplyable(current) ? 1 : 0,
    current?.can_send_text ? 1 : 0,
    current?.reply_window_open ? 1 : 0,
    timestampInSeconds(current?.last_activity_at) ?? 0,
    Number(current?.conversation_id || 0),
  ];

  for (let index = 0; index < candidateScore.length; index += 1) {
    if (candidateScore[index] !== currentScore[index]) {
      return candidateScore[index] > currentScore[index];
    }
  }

  return false;
};

export const getUniqueCommunicationChannels = (channels = []) => {
  const channelByIdentity = new Map();
  const sourceChannels = Array.isArray(channels) ? channels : [];

  sourceChannels.filter(Boolean).forEach(channel => {
    const identity = communicationChannelIdentity(channel);
    if (!identity) return;

    const currentChannel = channelByIdentity.get(identity);
    if (isBetterCommunicationChannel(channel, currentChannel)) {
      channelByIdentity.set(identity, channel);
    }
  });

  return Array.from(channelByIdentity.values()).sort(
    sortByNewestChannelActivity
  );
};

export const getCommunicationReplyChannels = (channels = []) => {
  const sourceChannels = Array.isArray(channels) ? channels : [];
  if (sourceChannels.some(channel => channel?.communication_action)) {
    return sourceChannels.filter(isCommunicationChannelReplyable);
  }

  return getUniqueCommunicationChannels(sourceChannels)
    .filter(isCommunicationChannelReplyable)
    .flatMap(channel => {
      if (isCommunicationVoiceChannel(channel)) return [channel];
      if (!isCommunicationWhatsappCallAvailable(channel)) return [channel];

      const actionChannels = [];
      const baseKey = communicationChannelActionKey(channel);

      if (isCommunicationMessageActionable(channel)) {
        actionChannels.push({
          ...channel,
          communication_action: COMMUNICATION_CHANNEL_ACTIONS.MESSAGE,
          message_channel_key: baseKey,
          channel_key: baseKey,
        });
      }

      if (isCommunicationWhatsappCallAvailable(channel)) {
        actionChannels.push({
          ...channel,
          communication_action: COMMUNICATION_CHANNEL_ACTIONS.CALL,
          message_channel_key: baseKey,
          channel_key: communicationChannelActionKey(
            channel,
            COMMUNICATION_CHANNEL_ACTIONS.CALL
          ),
          can_reply: true,
          can_send_text: false,
          can_send_attachments: false,
          requires_template: false,
          disabled: false,
          disabled_reason: null,
        });
      }

      return actionChannels;
    });
};

const normalizeChannelStatus = status => String(status || '').trim();

const channelMatchesStatus = (channel, status) => {
  const normalizedStatus = normalizeChannelStatus(status);
  if (!normalizedStatus) return true;
  if (!channel?.status) return true;

  return normalizeChannelStatus(channel.status) === normalizedStatus;
};

const channelInboxLabel = inbox => inbox.name || `#${inbox.id}`;

const channelInboxDuplicateKey = inbox =>
  [
    inbox.channel_type || '',
    channelInboxLabel(inbox).trim().toLowerCase(),
  ].join(':');

const disambiguateDuplicateChannelInboxLabels = inboxes => {
  const labelCounts = inboxes.reduce((counts, inbox) => {
    const key = channelInboxDuplicateKey(inbox);
    counts.set(key, (counts.get(key) || 0) + 1);
    return counts;
  }, new Map());

  return inboxes.map(inbox => {
    const key = channelInboxDuplicateKey(inbox);
    if (labelCounts.get(key) <= 1) return inbox;

    return {
      ...inbox,
      display_name: `${channelInboxLabel(inbox)} #${inbox.id}`,
    };
  });
};

export const getCommunicationThreadChannelFilterInboxes = (inboxes = []) => {
  const inboxesById = new Map();
  const sourceInboxes = Array.isArray(inboxes) ? inboxes : [];

  sourceInboxes
    .filter(inbox => inbox?.id)
    .forEach(inbox => {
      const inboxId = Number(inbox.id);
      if (inboxesById.has(inboxId)) return;

      inboxesById.set(inboxId, {
        ...inbox,
        id: inboxId,
      });
    });

  const sortedInboxes = Array.from(inboxesById.values()).sort(
    (leftInbox, rightInbox) => {
      const nameComparison = (leftInbox.name || '').localeCompare(
        rightInbox.name || ''
      );
      if (nameComparison !== 0) return nameComparison;

      return Number(leftInbox.id || 0) - Number(rightInbox.id || 0);
    }
  );

  return disambiguateDuplicateChannelInboxLabels(sortedInboxes);
};

export const getCommunicationThreadChannelInboxes = (
  threads = [],
  activeStatus = null
) => {
  const inboxesById = new Map();
  const threadList = Array.isArray(threads) ? threads : [];

  threadList
    .filter(isCommunicationThread)
    .flatMap(thread =>
      getUniqueCommunicationChannels(
        (thread.channels || []).filter(channel =>
          channelMatchesStatus(channel, activeStatus)
        )
      )
    )
    .filter(channel => channel?.inbox_id)
    .forEach(channel => {
      const inboxId = Number(channel.inbox_id);
      if (inboxesById.has(inboxId)) return;

      inboxesById.set(inboxId, {
        id: inboxId,
        name: channel.inbox_name,
        channel_type: channel.channel,
        medium: channel.medium,
      });
    });

  const sortedInboxes = Array.from(inboxesById.values()).sort(
    (leftInbox, rightInbox) => {
      const nameComparison = (leftInbox.name || '').localeCompare(
        rightInbox.name || ''
      );
      if (nameComparison !== 0) return nameComparison;

      return Number(leftInbox.id || 0) - Number(rightInbox.id || 0);
    }
  );

  return disambiguateDuplicateChannelInboxLabels(sortedInboxes);
};

const isIncomingMessage = message => {
  return (
    message?.message_type === MESSAGE_TYPE.INCOMING ||
    message?.message_type === 'incoming'
  );
};

const channelForMessage = (channels, message) => {
  const exactChannel = channels.find(
    channel =>
      String(channel.conversation_id) === String(message?.conversation_id)
  );
  if (exactChannel) return exactChannel;

  return channels.find(
    channel =>
      channel.inbox_id && String(channel.inbox_id) === String(message?.inbox_id)
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
  const uniqueChannels = getUniqueCommunicationChannels(channels);
  if (!uniqueChannels.length) return null;
  return uniqueChannels.find(channel => channel.primary) || uniqueChannels[0];
};

export const getDefaultReplyChannel = (channels, messages = []) => {
  const uniqueChannels = getUniqueCommunicationChannels(channels);
  if (!uniqueChannels.length) return null;

  const replyChannels = getCommunicationReplyChannels(uniqueChannels);
  const latestIncomingReplyableChannel = getLatestIncomingReplyableChannel(
    replyChannels,
    messages
  );
  if (latestIncomingReplyableChannel) return latestIncomingReplyableChannel;

  if (replyChannels.length) {
    return replyChannels[0];
  }

  return getPrimaryCommunicationChannel(uniqueChannels);
};

const sameCommunicationChannel = (channel, identifier) => {
  const { baseKey: identifierBaseKey, action: identifierAction } =
    splitCommunicationChannelActionKey(identifier);
  const channelBaseKey = communicationChannelBaseKey(channel);
  const channelAction = communicationChannelAction(channel);
  const hasExplicitAction = Boolean(channel?.communication_action);

  if (identifierAction) {
    if (!channelBaseKey || channelBaseKey !== identifierBaseKey) return false;
    return hasExplicitAction ? channelAction === identifierAction : true;
  }

  if (
    hasExplicitAction &&
    channelAction !== COMMUNICATION_CHANNEL_ACTIONS.MESSAGE
  ) {
    return false;
  }

  return (
    String(channelBaseKey) === String(identifierBaseKey) ||
    String(channel?.conversation_id) === String(identifier) ||
    String(channel?.inbox_id) === String(identifier)
  );
};

const sameCommunicationInbox = (leftChannel, rightChannel) => {
  if (!leftChannel?.inbox_id || !rightChannel?.inbox_id) return false;
  return String(leftChannel.inbox_id) === String(rightChannel.inbox_id);
};

export const getCommunicationReplyChannel = (chat, conversationId = null) => {
  const rawChannels = Array.isArray(chat?.channels) ? chat.channels : [];
  const channels = getUniqueCommunicationChannels(rawChannels);
  if (!channels.length) return null;

  const replyChannels = getCommunicationReplyChannels(channels);
  const selectableChannels = replyChannels.length ? replyChannels : channels;

  if (conversationId) {
    const selectedRawChannel = rawChannels.find(channel =>
      sameCommunicationChannel(channel, conversationId)
    );
    const selectedChannel = selectableChannels.find(channel =>
      sameCommunicationChannel(channel, conversationId)
    );
    if (selectedChannel) return selectedChannel;

    const { action: selectedAction } =
      splitCommunicationChannelActionKey(conversationId);
    if (!selectedAction) {
      const selectedInboxChannel = selectableChannels.find(channel =>
        sameCommunicationInbox(channel, selectedRawChannel)
      );
      if (selectedInboxChannel) return selectedInboxChannel;
    }
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

export const getCommunicationContactIdentityLabel = channel => {
  if (!channel) return '';

  const channelProfile =
    channel.channel_profile || channel.channelProfile || {};

  return (
    channelProfile.phone_number ||
    channelProfile.username ||
    channelProfile.email ||
    channelProfile.identifier ||
    channelProfile.source_id ||
    channel.source_id ||
    channel.contact_source_id ||
    channel.contact_identifier ||
    channelProfile.display_name ||
    channelProfile.name ||
    ''
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

export const getCommunicationThreadTypingTargetIds = chat => {
  const ids = [chat?.id];
  if (isCommunicationThread(chat)) {
    ids.push(...(chat.conversation_ids || []));
  }

  return [...new Set(ids.filter(id => id !== undefined && id !== null))];
};

export const buildCommunicationChannelFromRealtimePayload = payload => {
  if (!payload?.conversation_id || !payload?.inbox_id) return null;

  return {
    conversation_id: payload.conversation_id,
    inbox_id: payload.inbox_id,
    inbox_name: payload.inbox_name,
    contact_inbox_id: payload.contact_inbox_id,
    channel: payload.channel,
    medium: payload.medium,
    can_reply: payload.can_reply,
    can_send_text: payload.can_send_text ?? payload.can_reply,
    can_send_attachments: payload.can_send_attachments ?? payload.can_reply,
    can_call: payload.can_call ?? false,
    requires_template: payload.requires_template || false,
    reply_window_open: payload.reply_window_open ?? payload.can_reply,
    reauthorization_required: payload.reauthorization_required || false,
    disabled: payload.disabled ?? payload.can_reply === false,
    disabled_reason: payload.disabled_reason || null,
    primary: payload.primary || false,
    last_activity_at: payload.last_activity_at || payload.timestamp || 0,
    media_server_enabled: payload.media_server_enabled ?? false,
    channel_key: `conversation:${payload.conversation_id}`,
  };
};

export const buildCommunicationChannelFromMessage = message => {
  if (!message?.conversation_id || !message?.inbox_id) return null;

  return {
    conversation_id: message.conversation_id,
    inbox_id: message.inbox_id,
    inbox_name: message.inbox_name,
    contact_inbox_id: message.contact_inbox_id,
    channel: message.channel,
    medium: message.medium,
    can_reply: isIncomingMessage(message),
    can_send_text: isIncomingMessage(message),
    can_send_attachments: isIncomingMessage(message),
    can_call: message.can_call ?? false,
    requires_template: false,
    reply_window_open: isIncomingMessage(message),
    reauthorization_required: false,
    disabled: !isIncomingMessage(message),
    disabled_reason: isIncomingMessage(message) ? null : 'not_replyable',
    primary: false,
    last_activity_at: message.created_at || 0,
    media_server_enabled: message.media_server_enabled ?? false,
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
      channelKey: replyChannel.message_channel_key || replyChannel.channel_key,
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
  const channels = getUniqueCommunicationChannels(
    Array.isArray(thread?.channels) ? thread.channels : []
  );
  const messages = Array.isArray(thread?.messages) ? thread.messages : [];
  const primaryChannel = getPrimaryCommunicationChannel(channels) || {};
  const replyChannel =
    getDefaultReplyChannel(channels, messages) || primaryChannel;

  return {
    ...thread,
    channels,
    id: thread.id,
    display_id: thread.id,
    communication_thread_id: thread.id,
    is_communication_thread: true,
    inbox_id: replyChannel?.inbox_id || primaryChannel?.inbox_id || null,
    active_reply_channel_conversation_id: replyChannel?.conversation_id || null,
    active_reply_channel_key: replyChannel?.channel_key || null,
    active_reply_channel_inbox_id: replyChannel?.inbox_id || null,
    active_reply_channel: replyChannel || null,
    can_reply: channels.some(isCommunicationChannelReplyable),
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
