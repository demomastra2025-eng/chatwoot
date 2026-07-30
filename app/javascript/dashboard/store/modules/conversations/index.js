import types from '../../mutation-types';
import getters, { getSelectedChatConversation } from './getters';
import actions from './actions';
import { findPendingMessageIndex, isStalePendingMessageMatch } from './helpers';
import { MESSAGE_STATUS, MESSAGE_TYPE } from 'shared/constants/messages';
import wootConstants from 'dashboard/constants/globals';
import { BUS_EVENTS } from '../../../../shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { CONTENT_TYPES } from 'dashboard/components-next/message/constants.js';
import {
  buildCommunicationChannelFromRealtimePayload,
  buildCommunicationChannelFromMessage,
  getDefaultReplyChannel,
  getPrimaryCommunicationChannel,
  getUniqueCommunicationChannels,
  isCommunicationChannelReplyable,
  isCommunicationThread,
  isMessageInCommunicationThread,
} from 'dashboard/helper/communicationThreadHelper';

const state = {
  allConversations: [],
  attachments: {},
  listLoadingStatus: true,
  chatStatusFilter: wootConstants.STATUS_TYPE.OPEN,
  chatSortFilter: wootConstants.SORT_BY_TYPE.LATEST,
  currentInbox: null,
  selectedChatId: null,
  selectedChatType: null,
  appliedFilters: [],
  contextMenuChatId: null,
  contextMenuChatType: null,
  conversationParticipants: [],
  conversationLastSeen: null,
  syncConversationsMessages: {},
  conversationFilters: {},
  copilotAssistant: {},
  sidebarUnreadCounts: {
    all: 0,
    statuses: {},
    inboxes: {},
    teams: {},
    labels: {},
    pipelines: {},
    stages: {},
    appointment_statuses: {},
  },
};

const conversationIdMatches = (conversation, conversationId) =>
  String(conversation?.id) === String(conversationId);

const conversationStoreType = conversation =>
  isCommunicationThread(conversation) ? 'communication_thread' : 'conversation';

const findConversationByIdAndType = (
  _state,
  conversationId,
  conversationType
) =>
  _state.allConversations.find(
    conversation =>
      conversationIdMatches(conversation, conversationId) &&
      conversationStoreType(conversation) === conversationType
  );

const findConversationById = (
  _state,
  conversationId,
  conversationType = null
) => {
  if (conversationType) {
    return findConversationByIdAndType(
      _state,
      conversationId,
      conversationType
    );
  }

  const selectedType = conversationIdMatches(
    { id: _state.selectedChatId },
    conversationId
  )
    ? _state.selectedChatType
    : null;

  if (selectedType) {
    return (
      findConversationByIdAndType(_state, conversationId, selectedType) ||
      _state.allConversations.find(conversation =>
        conversationIdMatches(conversation, conversationId)
      )
    );
  }

  return (
    findConversationByIdAndType(_state, conversationId, 'conversation') ||
    _state.allConversations.find(conversation =>
      conversationIdMatches(conversation, conversationId)
    )
  );
};

const getConversationById =
  _state =>
  (conversationId, conversationType = null) =>
    findConversationById(_state, conversationId, conversationType);

const conversationTargetFromPayload = payload => {
  if (payload && typeof payload === 'object') {
    return {
      id: payload.id ?? payload.conversationId,
      conversationType: payload.conversationType || null,
    };
  }

  return { id: payload, conversationType: null };
};

const conversationSyncKey = (conversationId, conversationType = null) =>
  conversationType ? `${conversationType}:${conversationId}` : conversationId;

const sortMessagesByTimeline = (leftMessage, rightMessage) => {
  const createdAtDifference =
    Number(leftMessage.created_at || 0) - Number(rightMessage.created_at || 0);
  if (createdAtDifference !== 0) return createdAtDifference;

  return String(leftMessage.id || '').localeCompare(
    String(rightMessage.id || '')
  );
};

const mergeUniqueIds = (...idLists) => {
  const ids = idLists.flat().filter(id => id !== undefined && id !== null);
  return [...new Set(ids.map(id => String(id)))].map(id => {
    const numberId = Number(id);
    return Number.isNaN(numberId) ? id : numberId;
  });
};

const messageTimestamp = message => {
  const timestamp = Number(message?.created_at || 0);
  return Number.isFinite(timestamp) && timestamp > 0 ? timestamp : 0;
};

const updateDirectionalMessageTimestamp = (chat, message) => {
  if (!chat || message?.private) return;

  const timestamp = messageTimestamp(message);
  if (!timestamp) return;

  if (Number(message.message_type) === MESSAGE_TYPE.INCOMING) {
    chat.last_incoming_message_at = Math.max(
      Number(chat.last_incoming_message_at || 0),
      timestamp
    );
    return;
  }

  if (
    [MESSAGE_TYPE.OUTGOING, MESSAGE_TYPE.TEMPLATE].includes(
      Number(message.message_type)
    )
  ) {
    chat.last_outgoing_message_at = Math.max(
      Number(chat.last_outgoing_message_at || 0),
      timestamp
    );
  }
};

const communicationThreadUpdatesWithRealtimeChannel = (
  selectedConversation,
  updates
) => {
  if (
    !isCommunicationThread(selectedConversation) ||
    !isCommunicationThread(updates)
  ) {
    return updates;
  }

  const mergedUpdates = updates.meta
    ? {
        ...updates,
        meta: { ...(selectedConversation.meta || {}), ...updates.meta },
      }
    : updates;
  const incomingChannels = Array.isArray(updates.channels)
    ? updates.channels
    : null;
  if (incomingChannels) {
    return {
      ...mergedUpdates,
      channels: incomingChannels,
      conversation_ids:
        updates.conversation_ids ||
        mergeUniqueIds(
          incomingChannels.map(
            incomingChannel => incomingChannel.conversation_id
          )
        ),
    };
  }

  const channel = buildCommunicationChannelFromRealtimePayload(updates);
  if (!channel) return mergedUpdates;

  return {
    ...mergedUpdates,
    channels: getUniqueCommunicationChannels([
      ...(selectedConversation.channels || []),
      channel,
    ]),
    conversation_ids: mergeUniqueIds(
      selectedConversation.conversation_ids || [],
      updates.conversation_ids || [],
      [channel.conversation_id]
    ),
  };
};

const addAttachmentsForChat = (_state, id, message) => {
  if (message.status !== MESSAGE_STATUS.SENT || !message.attachments?.length) {
    return;
  }

  const existingAttachments = _state.attachments[id] || [];
  const attachmentsToAdd = message.attachments.filter(attachment => {
    return !existingAttachments.some(
      existingAttachment => existingAttachment.id === attachment.id
    );
  });

  _state.attachments[id] = [...existingAttachments, ...attachmentsToAdd];
};

const identityKey = (type, value) => `${type}:${String(value)}`;

const messageIdentityKeys = message => {
  const keys = [];
  if (message?.id !== undefined && message?.id !== null) {
    keys.push(identityKey('id', message.id));
  }
  if (message?.echo_id !== undefined && message?.echo_id !== null) {
    keys.push(identityKey('echo', message.echo_id));
  }
  return keys;
};

const messageLookupKeys = message => {
  const keys = messageIdentityKeys(message);
  if (message?.echo_id !== undefined && message?.echo_id !== null) {
    keys.push(identityKey('id', message.echo_id));
  }
  return keys;
};

const registerMessageIdentity = (indexByIdentity, message, index) => {
  messageIdentityKeys(message).forEach(key => {
    indexByIdentity.set(key, index);
  });
};

const mergeMessagesById = (existingMessages = [], incomingMessages = []) => {
  const mergedMessages = [];
  const indexByIdentity = new Map();

  [...existingMessages, ...incomingMessages].forEach(message => {
    const identityKeys = messageIdentityKeys(message);
    if (!identityKeys.length) {
      mergedMessages.push(message);
      return;
    }

    const identityIndex = messageLookupKeys(message)
      .map(key => indexByIdentity.get(key))
      .find(index => index !== undefined);
    const pendingIndex =
      identityIndex === undefined
        ? mergedMessages.findIndex(existingMessage =>
            isStalePendingMessageMatch(existingMessage, message)
          )
        : -1;
    const existingIndex =
      identityIndex !== undefined || pendingIndex === -1
        ? identityIndex
        : pendingIndex;

    if (existingIndex === undefined) {
      registerMessageIdentity(indexByIdentity, message, mergedMessages.length);
      mergedMessages.push(message);
      return;
    }

    mergedMessages[existingIndex] =
      pendingIndex === existingIndex && identityIndex === undefined
        ? message
        : {
            ...mergedMessages[existingIndex],
            ...message,
          };
    registerMessageIdentity(
      indexByIdentity,
      mergedMessages[existingIndex],
      existingIndex
    );
  });

  return mergedMessages.sort(sortMessagesByTimeline);
};

const sameConversationType = (existingConversation, incomingConversation) => {
  return (
    conversationStoreType(existingConversation) ===
    conversationStoreType(incomingConversation)
  );
};

const isSelectedConversation = (_state, conversation) => {
  return (
    conversationIdMatches(conversation, _state.selectedChatId) &&
    (!_state.selectedChatType ||
      conversationStoreType(conversation) === _state.selectedChatType)
  );
};

const findConversationIndexByIdAndType = (_state, conversation) => {
  return _state.allConversations.findIndex(
    existingConversation =>
      conversationIdMatches(existingConversation, conversation.id) &&
      sameConversationType(existingConversation, conversation)
  );
};

const refreshCommunicationThreadReplyState = chat => {
  if (!isCommunicationThread(chat)) return;

  const channels = Array.isArray(chat.channels) ? chat.channels : [];
  const replyChannel =
    getDefaultReplyChannel(channels, chat.messages || []) ||
    getPrimaryCommunicationChannel(channels);

  chat.active_reply_channel = replyChannel || null;
  chat.active_reply_channel_conversation_id =
    replyChannel?.conversation_id || null;
  chat.active_reply_channel_key = replyChannel?.channel_key || null;
  chat.active_reply_channel_inbox_id = replyChannel?.inbox_id || null;
  chat.inbox_id = replyChannel?.inbox_id || null;
  chat.can_reply = channels.some(isCommunicationChannelReplyable);
};

// mutations
export const mutations = {
  [types.SET_ALL_CONVERSATION](_state, conversationList) {
    const newAllConversations = [..._state.allConversations];
    conversationList.forEach(conversation => {
      const indexInCurrentList = newAllConversations.findIndex(
        existingConversation =>
          conversationIdMatches(existingConversation, conversation.id) &&
          sameConversationType(existingConversation, conversation)
      );
      if (indexInCurrentList < 0) {
        newAllConversations.push(conversation);
      } else if (!isSelectedConversation(_state, conversation)) {
        // If the conversation is already in the list, replace it
        // Added this to fix the issue of the conversation not being updated
        // When reconnecting to the websocket. If the selectedChatId is not the same as
        // the conversation.id in the store, replace the existing conversation with the new one
        newAllConversations[indexInCurrentList] = conversation;
      } else {
        // If the conversation is already in the list and selectedChatId is the same,
        // replace all data except the messages array, attachments, dataFetched, allMessagesLoaded
        const existingConversation = newAllConversations[indexInCurrentList];
        newAllConversations[indexInCurrentList] = {
          ...conversation,
          allMessagesLoaded: existingConversation.allMessagesLoaded,
          messages: existingConversation.messages,
          dataFetched: existingConversation.dataFetched,
        };
      }
    });
    _state.allConversations = newAllConversations;
  },
  [types.REPLACE_ALL_CONVERSATION](_state, conversationList) {
    const selectedConversation = _state.allConversations.find(conversation =>
      isSelectedConversation(_state, conversation)
    );
    const selectedConversationInNextList = conversationList.find(conversation =>
      isSelectedConversation(_state, conversation)
    );

    _state.allConversations = conversationList.map(conversation => {
      if (!isSelectedConversation(_state, conversation)) return conversation;

      return {
        ...conversation,
        allMessagesLoaded: selectedConversation?.allMessagesLoaded,
        messages: selectedConversation?.messages,
        dataFetched: selectedConversation?.dataFetched,
      };
    });

    if (
      _state.selectedChatId !== null &&
      _state.selectedChatId !== undefined &&
      !selectedConversationInNextList
    ) {
      _state.selectedChatId = null;
      _state.selectedChatType = null;
    }
  },
  [types.EMPTY_ALL_CONVERSATION](_state) {
    _state.allConversations = [];
    _state.selectedChatId = null;
    _state.selectedChatType = null;
  },
  [types.SET_ALL_MESSAGES_LOADED](_state, payload) {
    const { id, conversationType } = conversationTargetFromPayload(payload);
    const chat = getConversationById(_state)(id, conversationType);
    if (chat) {
      chat.allMessagesLoaded = true;
    }
  },

  [types.CLEAR_ALL_MESSAGES_LOADED](_state, payload) {
    const { id, conversationType } = conversationTargetFromPayload(payload);
    const chat = getConversationById(_state)(id, conversationType);
    if (chat) {
      chat.allMessagesLoaded = false;
    }
  },
  [types.CLEAR_CURRENT_CHAT_WINDOW](_state) {
    _state.selectedChatId = null;
    _state.selectedChatType = null;
  },

  [types.SET_PREVIOUS_CONVERSATIONS](_state, { id, data, conversationType }) {
    if (data.length) {
      const chat = getConversationById(_state)(id, conversationType);
      if (!chat) return;

      chat.messages = mergeMessagesById(chat.messages, data);
      refreshCommunicationThreadReplyState(chat);
    }
  },
  [types.SET_ALL_ATTACHMENTS](_state, { id, data }) {
    _state.attachments[id] = [...data];
  },
  [types.SET_MISSING_MESSAGES](_state, { id, data, conversationType }) {
    const chat = getConversationById(_state)(id, conversationType);
    if (!chat) return;
    chat.messages = data;
    refreshCommunicationThreadReplyState(chat);
  },

  [types.SET_CHAT_DATA_FETCHED](_state, payload) {
    const { id, conversationType } = conversationTargetFromPayload(payload);
    const chat = getConversationById(_state)(id, conversationType);
    if (chat) {
      chat.dataFetched = true;
    }
  },

  [types.SET_CURRENT_CHAT_WINDOW](_state, activeChat) {
    if (activeChat) {
      _state.selectedChatId = activeChat.id;
      _state.selectedChatType = conversationStoreType(activeChat);
    }
  },

  [types.ASSIGN_AGENT](_state, { conversationId, assignee }) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (chat) {
      chat.meta.assignee = assignee;
    }
  },

  [types.ASSIGN_TEAM](_state, { team, conversationId }) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (chat) {
      chat.meta.team = team;
    }
  },

  [types.UPDATE_CONVERSATION_LAST_ACTIVITY](
    _state,
    { lastActivityAt, conversationId }
  ) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (chat) {
      chat.last_activity_at = lastActivityAt;
    }
  },
  [types.ASSIGN_PRIORITY](_state, { priority, conversationId }) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (chat) {
      chat.priority = priority;
    }
  },

  [types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES](
    _state,
    { conversationId, customAttributes }
  ) {
    const conversation = getConversationById(_state)(
      conversationId,
      'conversation'
    );
    if (conversation) {
      conversation.custom_attributes = customAttributes || {};
    }
  },

  [types.CHANGE_CONVERSATION_STATUS](
    _state,
    { conversationId, status, snoozedUntil, conversationType = 'conversation' }
  ) {
    const conversation =
      getters.getConversationById(_state)(conversationId, conversationType) ||
      {};
    conversation.snoozed_until = snoozedUntil;
    conversation.status = status;

    if (conversationType !== 'conversation') return;

    _state.allConversations
      .filter(isCommunicationThread)
      .flatMap(chat => chat.channels || [])
      .filter(
        channel => String(channel.conversation_id) === String(conversationId)
      )
      .forEach(channel => {
        channel.status = status;
      });
  },

  [types.MUTE_CONVERSATION](_state) {
    const [chat] = getSelectedChatConversation(_state);
    chat.muted = true;
  },

  [types.UNMUTE_CONVERSATION](_state) {
    const [chat] = getSelectedChatConversation(_state);
    chat.muted = false;
  },

  [types.ADD_CONVERSATION_ATTACHMENTS](_state, message) {
    addAttachmentsForChat(_state, message.conversation_id, message);
  },

  [types.DELETE_CONVERSATION_ATTACHMENTS](_state, message) {
    if (message.status !== MESSAGE_STATUS.SENT) return;

    const { conversation_id: id } = message;
    const existingAttachments = _state.attachments[id] || [];
    if (!existingAttachments.length) return;

    _state.attachments[id] = existingAttachments.filter(attachment => {
      return attachment.message_id !== message.id;
    });
  },

  [types.ADD_MESSAGE](_state, message) {
    const { conversation_id: conversationId } = message;
    const { selectedChatId } = _state;
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (!chat) return;

    const pendingMessageIndex = findPendingMessageIndex(chat, message);
    updateDirectionalMessageTimestamp(chat, message);
    if (pendingMessageIndex !== -1) {
      chat.messages[pendingMessageIndex] = message;
    } else {
      chat.messages.push(message);
      chat.timestamp = message.created_at;
      const { conversation: { unread_count: unreadCount = 0 } = {} } = message;
      chat.unread_count = unreadCount;
      if (
        String(selectedChatId) === String(conversationId) &&
        _state.selectedChatType !== 'communication_thread'
      ) {
        emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE);
      }
    }
  },

  [types.ADD_MESSAGE_TO_CHAT](_state, { chatId, message }) {
    const chat = getConversationById(_state)(chatId, 'communication_thread');
    if (!chat) return;
    if (!isMessageInCommunicationThread(chat, message)) return;

    chat.messages ||= [];
    const pendingMessageIndex = findPendingMessageIndex(chat, message);
    updateDirectionalMessageTimestamp(chat, message);
    if (pendingMessageIndex !== -1) {
      chat.messages[pendingMessageIndex] = message;
    } else if (!chat.messages.some(item => item.id === message.id)) {
      chat.messages.push(message);
    }

    chat.messages.sort(sortMessagesByTimeline);
    chat.timestamp = Math.max(
      Number(chat.timestamp || 0),
      Number(message.created_at || 0)
    );

    let channel = (chat.channels || []).find(
      item => String(item.conversation_id) === String(message.conversation_id)
    );
    if (!channel && chat.is_communication_thread && message.inbox_id) {
      channel = (chat.channels || []).find(
        item => String(item.inbox_id) === String(message.inbox_id)
      );
      if (channel && !channel.conversation_id && message.conversation_id) {
        channel.conversation_id = message.conversation_id;
        channel.contact_inbox_id ||= message.contact_inbox_id;
        channel.channel_key = `conversation:${message.conversation_id}`;
        chat.conversation_ids ||= [];
        if (
          !chat.conversation_ids.some(
            conversationId =>
              String(conversationId) === String(message.conversation_id)
          )
        ) {
          chat.conversation_ids.push(message.conversation_id);
        }
      }
    }
    if (!channel && chat.is_communication_thread) {
      channel = buildCommunicationChannelFromMessage(message);
      if (channel) {
        chat.channels ||= [];
        chat.channels.push(channel);
        chat.conversation_ids ||= [];
        if (
          !chat.conversation_ids.some(
            conversationId =>
              String(conversationId) === String(channel.conversation_id)
          )
        ) {
          chat.conversation_ids.push(channel.conversation_id);
        }
      }
    }
    if (channel) {
      channel.last_activity_at = Math.max(
        Number(channel.last_activity_at || 0),
        Number(message.created_at || 0)
      );
      if (message.message_type === MESSAGE_TYPE.INCOMING) {
        channel.can_reply = true;
        channel.can_send_text = true;
        channel.can_send_attachments = true;
        channel.reply_window_open = true;
        channel.disabled = false;
        channel.disabled_reason = null;
      }
    }
    addAttachmentsForChat(_state, chatId, message);
    refreshCommunicationThreadReplyState(chat);

    if (
      String(_state.selectedChatId) === String(chatId) &&
      _state.selectedChatType === 'communication_thread'
    ) {
      emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE);
    }
  },

  [types.ADD_CONVERSATION](_state, conversation) {
    const exists = _state.allConversations.some(
      existingConversation =>
        conversationIdMatches(existingConversation, conversation.id) &&
        sameConversationType(existingConversation, conversation)
    );
    if (!exists) {
      _state.allConversations.push(conversation);
    }
  },

  [types.DELETE_CONVERSATION](_state, conversationId) {
    _state.allConversations = _state.allConversations.filter(
      conversation =>
        !conversationIdMatches(conversation, conversationId) ||
        isCommunicationThread(conversation)
    );
  },

  [types.DELETE_COMMUNICATION_THREAD_CONVERSATIONS](
    _state,
    { threadId, conversationIds }
  ) {
    const deletedIdSet = new Set(
      (conversationIds || []).map(conversationId => String(conversationId))
    );
    if (!deletedIdSet.size) return;

    let removedSelectedThread = false;
    _state.allConversations = _state.allConversations
      .map(conversation => {
        if (
          !conversationIdMatches(conversation, threadId) ||
          !isCommunicationThread(conversation)
        ) {
          return conversation;
        }

        const channels = (conversation.channels || []).filter(
          channel => !deletedIdSet.has(String(channel.conversation_id))
        );
        if (!channels.length) {
          removedSelectedThread =
            removedSelectedThread ||
            (String(_state.selectedChatId) === String(threadId) &&
              _state.selectedChatType === 'communication_thread');
          return null;
        }

        const updatedConversation = {
          ...conversation,
          channels,
          conversation_ids: (conversation.conversation_ids || []).filter(
            conversationId => !deletedIdSet.has(String(conversationId))
          ),
          messages: (conversation.messages || []).filter(
            message => !deletedIdSet.has(String(message.conversation_id))
          ),
        };
        refreshCommunicationThreadReplyState(updatedConversation);
        return updatedConversation;
      })
      .filter(Boolean);

    if (removedSelectedThread) {
      _state.selectedChatId = null;
      _state.selectedChatType = null;
    }
  },

  [types.UPDATE_CONVERSATION](_state, conversation) {
    const { allConversations } = _state;
    const index = findConversationIndexByIdAndType(_state, conversation);

    if (index > -1) {
      const selectedConversation = allConversations[index];

      // ignore out of order events
      if (conversation.updated_at < selectedConversation.updated_at) {
        return;
      }

      const { messages, ...updates } = conversation;
      const normalizedUpdates = communicationThreadUpdatesWithRealtimeChannel(
        selectedConversation,
        updates
      );
      allConversations[index] = {
        ...selectedConversation,
        ...normalizedUpdates,
      };
      refreshCommunicationThreadReplyState(allConversations[index]);
    } else {
      const hasSameIdDifferentType = allConversations.some(
        existingConversation =>
          conversationIdMatches(existingConversation, conversation.id) &&
          !sameConversationType(existingConversation, conversation)
      );
      if (hasSameIdDifferentType) return;

      if (
        isCommunicationThread(conversation) &&
        !conversation.meta &&
        !conversation.channels
      ) {
        return;
      }

      const { conversationType } = _state.conversationFilters || {};
      const { MENTION, PARTICIPATING } = wootConstants.CONVERSATION_TYPE;
      if (![MENTION, PARTICIPATING].includes(conversationType)) {
        _state.allConversations.push(conversation);
      }
    }
  },

  [types.SET_LIST_LOADING_STATUS](_state) {
    _state.listLoadingStatus = true;
  },

  [types.CLEAR_LIST_LOADING_STATUS](_state) {
    _state.listLoadingStatus = false;
  },

  [types.UPDATE_MESSAGE_UNREAD_COUNT](
    _state,
    {
      id,
      lastSeen,
      unreadCount = 0,
      conversationType = 'conversation',
      channels = [],
    }
  ) {
    const chat = getConversationById(_state)(id, conversationType);
    if (chat) {
      chat.agent_last_seen_at = lastSeen;
      chat.unread_count = unreadCount;
      if (Array.isArray(chat.channels) && channels.length) {
        chat.channels = chat.channels.map(channel => {
          const updatedChannel = channels.find(
            item =>
              String(item.conversation_id) === String(channel.conversation_id)
          );
          return updatedChannel ? { ...channel, ...updatedChannel } : channel;
        });
      }
    }
  },
  [types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS](_state, counts) {
    _state.sidebarUnreadCounts = {
      all: Number(counts?.all || 0),
      statuses: counts?.statuses || {},
      inboxes: counts?.inboxes || {},
      teams: counts?.teams || {},
      labels: counts?.labels || {},
      pipelines: counts?.pipelines || {},
      stages: counts?.stages || {},
      appointment_statuses: counts?.appointment_statuses || {},
    };
  },
  [types.CHANGE_CHAT_STATUS_FILTER](_state, data) {
    _state.chatStatusFilter = data;
  },

  [types.CHANGE_CHAT_SORT_FILTER](_state, data) {
    _state.chatSortFilter = data;
  },

  // Update assignee on action cable message
  [types.UPDATE_ASSIGNEE](_state, payload) {
    const chat = getConversationById(_state)(payload.id, 'conversation');
    if (chat) {
      chat.meta.assignee = payload.assignee;
    }
  },

  [types.UPDATE_CONVERSATION_CONTACT](_state, { conversationId, ...payload }) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (chat) {
      chat.meta.sender = payload;
    }
  },

  [types.UPDATE_CONTACT_IN_CONVERSATIONS](_state, contact) {
    if (!contact?.id) return;

    _state.allConversations.forEach(chat => {
      if (String(chat?.meta?.sender?.id) !== String(contact.id)) return;

      chat.meta.sender = {
        ...chat.meta.sender,
        ...contact,
      };
    });
  },

  [types.UPDATE_CONVERSATION_CALL_STATUS](
    _state,
    { conversationId, callSid, callStatus }
  ) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (!chat) return;

    const currentCallRef =
      chat.additional_attributes?.telephony_call_ref ||
      chat.additional_attributes?.fonoster_call_ref;
    if (
      currentCallRef &&
      callSid &&
      String(currentCallRef) !== String(callSid)
    ) {
      return;
    }

    chat.additional_attributes = {
      ...chat.additional_attributes,
      call_status: callStatus,
    };
  },

  [types.UPDATE_MESSAGE_CALL_STATUS](
    _state,
    { conversationId, callSid, callStatus, callData }
  ) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (!chat) return;

    const voiceCalls = (chat.messages || []).filter(
      message => message.content_type === CONTENT_TYPES.VOICE_CALL
    );
    const lastCall = callSid
      ? voiceCalls.findLast(message => {
          const data = message.content_attributes?.data || {};
          return (
            String(data.call_sid || data.callSid || '') === String(callSid) ||
            String(message.source_id || '') === `voice_call:${callSid}`
          );
        })
      : voiceCalls.at(-1);

    if (!lastCall) return;

    lastCall.content_attributes ??= {};
    const incomingData =
      callData && typeof callData === 'object' ? callData : {};
    lastCall.content_attributes.data = {
      ...lastCall.content_attributes.data,
      ...incomingData,
      status: callStatus,
    };
  },

  [types.SET_ACTIVE_INBOX](_state, inboxId) {
    _state.currentInbox = inboxId ? parseInt(inboxId, 10) : null;
  },

  [types.SET_CONVERSATION_CAN_REPLY](_state, { conversationId, canReply }) {
    const chat = getConversationById(_state)(conversationId, 'conversation');
    if (chat) {
      chat.can_reply = canReply;
    }
  },

  [types.CLEAR_CONTACT_CONVERSATIONS](_state, contactId) {
    const chats = _state.allConversations.filter(
      c => c.meta.sender.id !== contactId
    );
    _state.allConversations = chats;
  },

  [types.SET_CONVERSATION_FILTERS](_state, data) {
    _state.appliedFilters = data;
  },

  [types.CLEAR_CONVERSATION_FILTERS](_state) {
    _state.appliedFilters = [];
  },

  [types.SET_LAST_MESSAGE_ID_IN_SYNC_CONVERSATION](
    _state,
    { conversationId, conversationType, messageId }
  ) {
    _state.syncConversationsMessages[
      conversationSyncKey(conversationId, conversationType)
    ] = messageId;
  },

  [types.SET_CONTEXT_MENU_CHAT_ID](_state, payload) {
    const hasPayloadObject = payload && typeof payload === 'object';
    _state.contextMenuChatId = hasPayloadObject ? payload.id : payload;
    _state.contextMenuChatType = hasPayloadObject
      ? payload.conversationType || null
      : null;
  },

  [types.SET_CHAT_LIST_FILTERS](_state, data) {
    _state.conversationFilters = data;
  },
  [types.UPDATE_CHAT_LIST_FILTERS](_state, data) {
    _state.conversationFilters = { ..._state.conversationFilters, ...data };
  },
  [types.SET_INBOX_CAPTAIN_ASSISTANT](_state, data) {
    _state.copilotAssistant = data.assistant;
  },
};

export default {
  state,
  getters,
  actions,
  mutations,
};
