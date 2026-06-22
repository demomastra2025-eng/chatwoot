import types from '../../mutation-types';
import ConversationApi from '../../../api/inbox/conversation';
import CommunicationThreadApi from '../../../api/inbox/communicationThread';
import MessageApi from '../../../api/inbox/message';
import { MESSAGE_STATUS, MESSAGE_TYPE } from 'shared/constants/messages';
import { createPendingMessage } from 'dashboard/helper/commons';
import {
  buildCommunicationThreadConversation,
  isCommunicationThread,
  isMessageInCommunicationThread,
} from 'dashboard/helper/communicationThreadHelper';
import {
  buildConversationList,
  isOnMentionsView,
  isOnParticipatingView,
  isOnUnattendedView,
  isOnFoldersView,
} from './helpers/actionHelpers';
import messageReadActions from './actions/messageReadActions';
import messageTranslateActions from './actions/messageTranslateActions';
import * as Sentry from '@sentry/vue';
import {
  handleVoiceCallCreated,
  handleVoiceCallUpdated,
} from 'dashboard/helper/voice';

let sidebarUnreadCountsRequestId = 0;

const SIDEBAR_UNREAD_COUNT_FILTER_KEYS = [
  'inboxId',
  'status',
  'assigneeType',
  'labels',
  'teamId',
  'conversationType',
  'communicationThreadMode',
];

const hasFilterValue = value => {
  if (Array.isArray(value)) return value.length > 0;
  return (
    value !== undefined && value !== null && value !== '' && value !== false
  );
};

const hasSidebarUnreadCountFilters = params =>
  SIDEBAR_UNREAD_COUNT_FILTER_KEYS.some(key => hasFilterValue(params?.[key]));

const communicationThreadIdsForMessage = (state, message) => {
  return (state?.allConversations || [])
    .filter(chat => isMessageInCommunicationThread(chat, message))
    .map(chat => chat.id);
};

const addMessageToCommunicationThreads = (commit, state, message) => {
  communicationThreadIdsForMessage(state, message).forEach(chatId => {
    commit(types.ADD_MESSAGE_TO_CHAT, { chatId, message });
  });
};

const conversationStoreType = conversation =>
  isCommunicationThread(conversation) ? 'communication_thread' : 'conversation';

const conversationIdMatches = (conversation, conversationId) =>
  String(conversation?.id) === String(conversationId);

const findChatByIdAndType = (state, conversationId, conversationType) =>
  (state?.allConversations || []).find(
    chat =>
      conversationIdMatches(chat, conversationId) &&
      conversationStoreType(chat) === conversationType
  );

const findActiveChatById = (state, conversationId) => {
  if (
    String(state?.selectedChatId) === String(conversationId) &&
    state?.selectedChatType
  ) {
    const selectedChat = findChatByIdAndType(
      state,
      conversationId,
      state.selectedChatType
    );
    if (selectedChat) return selectedChat;
  }

  return (state?.allConversations || []).find(chat =>
    conversationIdMatches(chat, conversationId)
  );
};

const activeChatTypeForPayload = (state, payload) => {
  if (payload?.conversationType) return payload.conversationType;
  if (
    String(state?.selectedChatId) === String(payload?.conversationId) &&
    state?.selectedChatType
  ) {
    return state.selectedChatType;
  }
  return null;
};

const withConversationType = (payload, conversationType) =>
  conversationType ? { ...payload, conversationType } : payload;

const sortMessagesByTimeline = (leftMessage, rightMessage) => {
  const createdAtDifference =
    Number(leftMessage.created_at || 0) - Number(rightMessage.created_at || 0);
  if (createdAtDifference !== 0) return createdAtDifference;

  const leftId = Number(leftMessage.id || 0);
  const rightId = Number(rightMessage.id || 0);
  if (Number.isFinite(leftId) && Number.isFinite(rightId)) {
    return leftId - rightId;
  }

  return String(leftMessage.id || '').localeCompare(
    String(rightMessage.id || '')
  );
};

const mergeMessagePayloadsById = (
  existingMessages = [],
  incomingMessages = []
) => {
  const mergedMessages = [];
  const indexById = new Map();

  [...existingMessages, ...incomingMessages].forEach(message => {
    const messageId = message?.id;
    if (messageId === undefined || messageId === null) {
      mergedMessages.push(message);
      return;
    }

    const key = String(messageId);
    const existingIndex = indexById.get(key);
    if (existingIndex === undefined) {
      indexById.set(key, mergedMessages.length);
      mergedMessages.push(message);
      return;
    }

    mergedMessages[existingIndex] = {
      ...mergedMessages[existingIndex],
      ...message,
    };
  });

  return mergedMessages.sort(sortMessagesByTimeline);
};

const messageExistsInPayload = (messages, messageId) =>
  (messages || []).some(message => String(message?.id) === String(messageId));

const shouldFetchFirstUnreadPage = ({
  request,
  selectedChat,
  meta,
  payload,
}) => {
  const firstUnreadMessageId = meta?.first_unread_message_id;
  return (
    !request.after &&
    !request.before &&
    Number(selectedChat?.unread_count || 0) > 0 &&
    firstUnreadMessageId &&
    payload.length > 0 &&
    !messageExistsInPayload(payload, firstUnreadMessageId)
  );
};

const payloadWithFirstUnreadPage = async ({
  request,
  selectedChat,
  meta,
  payload,
  fetchPage,
}) => {
  if (!shouldFetchFirstUnreadPage({ request, selectedChat, meta, payload })) {
    return payload;
  }

  const firstUnreadMessageId = meta.first_unread_message_id;
  const beforeMessageId = payload[0]?.id;
  const {
    data: { payload: firstUnreadPayload = [] },
  } = await fetchPage({
    after: firstUnreadMessageId,
    before: beforeMessageId,
  });

  return mergeMessagePayloadsById(firstUnreadPayload, payload);
};

const getCommunicationThreadById = (state, conversationId) => {
  if (
    String(state?.selectedChatId) === String(conversationId) &&
    state?.selectedChatType === 'conversation'
  ) {
    return null;
  }

  return (state?.allConversations || []).find(
    chat =>
      String(chat.id) === String(conversationId) && isCommunicationThread(chat)
  );
};

const resolveAttachmentTarget = (state, payload) => {
  const conversationState = state || {};
  const hasPayloadObject = payload && typeof payload === 'object';
  const conversationId = hasPayloadObject ? payload.conversationId : payload;
  const hasExplicitThreadFlag =
    hasPayloadObject &&
    Object.prototype.hasOwnProperty.call(payload, 'isCommunicationThread');

  if (hasExplicitThreadFlag) {
    return {
      conversationId,
      isCommunicationThread: Boolean(payload.isCommunicationThread),
    };
  }

  const matchingChats = (conversationState.allConversations || []).filter(
    conversation => Number(conversation.id) === Number(conversationId)
  );
  const selectedChat =
    matchingChats.find(conversation => isCommunicationThread(conversation)) ||
    matchingChats[0];

  return {
    conversationId,
    isCommunicationThread: isCommunicationThread(selectedChat),
  };
};

const hasFullCommunicationThreadPayload = payload => {
  return ['contact', 'channels', 'messages'].some(key =>
    Object.prototype.hasOwnProperty.call(payload || {}, key)
  );
};

const buildCommunicationThreadRealtimePatch = payload => {
  const threadId = payload.communication_thread_id || payload.id;
  return {
    ...payload,
    id: threadId,
    display_id: threadId,
    communication_thread_id: threadId,
    is_communication_thread: true,
  };
};

const commitCommunicationThreadUpdate = (
  commit,
  payload,
  { realtime = false } = {}
) => {
  const threadId = payload.communication_thread_id || payload.id;
  const communicationThread =
    !realtime && hasFullCommunicationThreadPayload(payload)
      ? buildCommunicationThreadConversation({
          ...payload,
          id: threadId,
        })
      : buildCommunicationThreadRealtimePatch(payload);
  commit(types.UPDATE_CONVERSATION, communicationThread);
  return communicationThread;
};

export const hasMessageFailedWithExternalError = pendingMessage => {
  // This helper is used to check if the message has failed with an external error.
  // We have two cases
  // 1. Messages that fail from the UI itself (due to large attachments or a failed network):
  //    In this case, the message will have a status of failed but no external error. So we need to create that message again
  // 2. Messages sent from Chatwoot but failed to deliver to the customer for some reason (user blocking or client system down):
  //    In this case, the message will have a status of failed and an external error. So we need to retry that message
  const { content_attributes: contentAttributes, status } = pendingMessage;
  const externalError = contentAttributes?.external_error ?? '';
  return status === MESSAGE_STATUS.FAILED && externalError !== '';
};

// actions
const actions = {
  getConversation: async ({ commit, state }, conversationId) => {
    try {
      const response = await ConversationApi.show(conversationId);
      const conversation = response.data;
      const exists = state.allConversations.some(
        existingConversation => existingConversation.id === conversation.id
      );

      if (exists) {
        commit(types.UPDATE_CONVERSATION, conversation);
      } else {
        commit(types.ADD_CONVERSATION, conversation);
      }

      commit(`contacts/${types.SET_CONTACT_ITEM}`, conversation.meta.sender);
      return conversation;
    } catch (error) {
      // Ignore error
      return null;
    }
  },

  fetchAllConversations: async ({ commit, state, dispatch }) => {
    commit(types.SET_LIST_LOADING_STATUS);
    try {
      const params = state.conversationFilters;
      const {
        data: { data },
      } = await ConversationApi.get(params);
      buildConversationList(
        { commit, dispatch },
        params,
        data,
        params.assigneeType
      );
    } catch (error) {
      // Handle error
    }
  },

  fetchCommunicationThreads: async ({ commit, state, dispatch }) => {
    commit(types.SET_LIST_LOADING_STATUS);
    try {
      const params = state.conversationFilters;
      const {
        data: { data },
      } = await CommunicationThreadApi.get(params);
      buildConversationList(
        { commit, dispatch },
        params,
        {
          meta: data.meta || {},
          payload: (data.payload || []).map(
            buildCommunicationThreadConversation
          ),
        },
        params.assigneeType
      );
    } catch (error) {
      commit(types.CLEAR_LIST_LOADING_STATUS);
    }
  },

  getCommunicationThread: async ({ commit }, communicationThreadId) => {
    try {
      const response = await CommunicationThreadApi.show(communicationThreadId);
      const communicationThread = buildCommunicationThreadConversation(
        response.data
      );
      commit(types.SET_ALL_CONVERSATION, [communicationThread]);
      commit(
        `contacts/${types.SET_CONTACT_ITEM}`,
        communicationThread.meta.sender
      );
      return communicationThread;
    } catch (error) {
      return null;
    }
  },

  fetchSidebarUnreadCounts: async ({ commit, state = {} }, params = null) => {
    sidebarUnreadCountsRequestId += 1;
    const requestId = sidebarUnreadCountsRequestId;
    try {
      const requestParams = params || state.conversationFilters || {};
      let counts = {};

      if (hasSidebarUnreadCountFilters(requestParams)) {
        const statsApi = requestParams.communicationThreadMode
          ? CommunicationThreadApi
          : ConversationApi;
        const {
          data: { meta },
        } = await statsApi.meta(requestParams);
        counts = meta?.unread_counts || {};
      } else {
        const {
          data: { counts: globalCounts },
        } = await ConversationApi.sidebarUnreadCounts();
        counts = globalCounts;
      }

      if (requestId !== sidebarUnreadCountsRequestId) return;

      commit(types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS, counts || {});
    } catch (error) {
      // Keep the last known sidebar counts if the refresh fails.
    }
  },

  fetchFilteredConversations: async ({ commit, dispatch }, params) => {
    commit(types.SET_LIST_LOADING_STATUS);
    try {
      const { data } = await ConversationApi.filter(params);
      buildConversationList(
        { commit, dispatch },
        params,
        data,
        'appliedFilters'
      );
    } catch (error) {
      // Handle error
    }
  },

  emptyAllConversations({ commit }) {
    commit(types.EMPTY_ALL_CONVERSATION);
  },

  clearSelectedState({ commit }) {
    commit(types.CLEAR_CURRENT_CHAT_WINDOW);
  },

  fetchPreviousMessages: async ({ commit, state }, data) => {
    try {
      const selectedChat = findActiveChatById(state, data.conversationId);
      const conversationType = activeChatTypeForPayload(state, data);

      if (selectedChat?.is_communication_thread) {
        const {
          data: { meta, payload },
        } = await CommunicationThreadApi.messages(data.conversationId, {
          after: data.after,
          before: data.before,
        });
        const messagesPayload = await payloadWithFirstUnreadPage({
          request: data,
          selectedChat,
          meta,
          payload,
          fetchPage: params =>
            CommunicationThreadApi.messages(data.conversationId, params),
        });
        selectedChat.channels = meta.channels || selectedChat.channels || [];
        selectedChat.meta = {
          ...(selectedChat.meta || {}),
          sender: meta.contact || selectedChat.meta?.sender || {},
        };
        commit(`conversationMetadata/${types.SET_CONVERSATION_METADATA}`, {
          id: data.conversationId,
          data: meta,
        });
        commit(
          types.SET_PREVIOUS_CONVERSATIONS,
          withConversationType(
            {
              id: data.conversationId,
              data: messagesPayload,
            },
            conversationType
          )
        );
        if (!messagesPayload.length) {
          commit(
            types.SET_ALL_MESSAGES_LOADED,
            withConversationType({ id: data.conversationId }, conversationType)
          );
        }
        return;
      }

      const {
        data: { meta, payload },
      } = await MessageApi.getPreviousMessages(data);
      const messagesPayload = await payloadWithFirstUnreadPage({
        request: data,
        selectedChat,
        meta,
        payload,
        fetchPage: params =>
          MessageApi.getPreviousMessages({
            conversationId: data.conversationId,
            ...params,
          }),
      });
      commit(`conversationMetadata/${types.SET_CONVERSATION_METADATA}`, {
        id: data.conversationId,
        data: meta,
      });
      commit(
        types.SET_PREVIOUS_CONVERSATIONS,
        withConversationType(
          {
            id: data.conversationId,
            data: messagesPayload,
          },
          conversationType
        )
      );
      if (!messagesPayload.length) {
        commit(
          types.SET_ALL_MESSAGES_LOADED,
          withConversationType({ id: data.conversationId }, conversationType)
        );
      }
    } catch (error) {
      // Handle error
    }
  },

  fetchAllAttachments: async ({ commit, state = {} }, payload) => {
    let attachments = [];
    const { conversationId, isCommunicationThread: isThreadAttachmentTarget } =
      resolveAttachmentTarget(state, payload);
    const attachmentsApi = isThreadAttachmentTarget
      ? CommunicationThreadApi.attachments(conversationId)
      : ConversationApi.getAllAttachments(conversationId);

    try {
      const { data } = await attachmentsApi;
      attachments = data.payload;
    } catch (error) {
      // in case of error, log the error and continue
      Sentry.setContext('Conversation', {
        id: conversationId,
        type: isThreadAttachmentTarget
          ? 'communication_thread'
          : 'conversation',
      });
      Sentry.captureException(error);
    } finally {
      // we run the commit even if the request fails
      // this ensures that the `attachment` variable is always present on chat
      commit(types.SET_ALL_ATTACHMENTS, {
        id: conversationId,
        data: attachments,
      });
    }
  },

  syncActiveConversationMessages: async (
    { commit, state, dispatch },
    { conversationId }
  ) => {
    const { syncConversationsMessages } = state;
    const selectedChat = findActiveChatById(state, conversationId);
    if (!selectedChat) return;
    const conversationType =
      activeChatTypeForPayload(state, { conversationId }) ||
      (isCommunicationThread(selectedChat) ? 'communication_thread' : null);
    const syncKey = conversationType
      ? `${conversationType}:${conversationId}`
      : conversationId;
    const lastMessageId =
      syncConversationsMessages[syncKey] ||
      syncConversationsMessages[conversationId];
    try {
      const { messages } = selectedChat;
      const syncMessagesApi = selectedChat.is_communication_thread
        ? CommunicationThreadApi.messages(conversationId, {
            after: lastMessageId,
          })
        : MessageApi.getPreviousMessages({
            conversationId,
            after: lastMessageId,
          });
      // Fetch all the messages after the last message id
      const {
        data: { meta, payload },
      } = await syncMessagesApi;
      commit(`conversationMetadata/${types.SET_CONVERSATION_METADATA}`, {
        id: conversationId,
        data: meta,
      });
      if (selectedChat.is_communication_thread) {
        selectedChat.channels = meta.channels || selectedChat.channels || [];
      }
      // Find the messages that are not already present in the store
      const missingMessages = payload.filter(
        message => !messages.find(item => item.id === message.id)
      );
      selectedChat.messages.push(...missingMessages);
      // Sort the messages by created_at
      const sortedMessages = selectedChat.messages.sort((a, b) => {
        return Number(a.created_at || 0) - Number(b.created_at || 0);
      });
      commit(
        types.SET_MISSING_MESSAGES,
        withConversationType(
          {
            id: conversationId,
            data: sortedMessages,
          },
          conversationType
        )
      );
      commit(types.SET_LAST_MESSAGE_ID_IN_SYNC_CONVERSATION, {
        conversationId,
        ...(conversationType ? { conversationType } : {}),
        messageId: null,
      });
      if (selectedChat.is_communication_thread) {
        await Promise.all(
          (selectedChat.conversation_ids || []).map(id =>
            dispatch('markMessagesRead', { id }, { root: true })
          )
        );
      } else {
        dispatch('markMessagesRead', { id: conversationId }, { root: true });
      }
    } catch (error) {
      // Handle error
    }
  },

  setConversationLastMessageId: async (
    { commit, state },
    { conversationId }
  ) => {
    const selectedChat = findActiveChatById(state, conversationId);
    if (!selectedChat) return;
    const conversationType =
      activeChatTypeForPayload(state, { conversationId }) ||
      (isCommunicationThread(selectedChat) ? 'communication_thread' : null);
    const { messages } = selectedChat;
    const lastMessage = messages.last();
    if (!lastMessage) return;
    commit(types.SET_LAST_MESSAGE_ID_IN_SYNC_CONVERSATION, {
      conversationId,
      ...(conversationType ? { conversationType } : {}),
      messageId: lastMessage.id,
    });
  },

  async setActiveChat({ commit, dispatch }, { data, after }) {
    commit(types.SET_CURRENT_CHAT_WINDOW, data);
    const conversationType = conversationStoreType(data);
    commit(types.CLEAR_ALL_MESSAGES_LOADED, {
      id: data.id,
      conversationType,
    });
    if (data.dataFetched === undefined) {
      try {
        const fetchParams = {
          after,
          conversationId: data.id,
          conversationType,
        };

        if (after) {
          fetchParams.before = data.messages?.[0]?.id;
        }

        await dispatch('fetchPreviousMessages', fetchParams);
        commit(types.SET_CHAT_DATA_FETCHED, {
          id: data.id,
          conversationType,
        });
      } catch (error) {
        // Ignore error
      }
    }
  },

  assignAgent: async (
    { commit, dispatch, state },
    { conversationId, agentId }
  ) => {
    try {
      const communicationThread = getCommunicationThreadById(
        state,
        conversationId
      );
      if (communicationThread) {
        const response = await CommunicationThreadApi.update(conversationId, {
          assignee_id: agentId,
        });
        commitCommunicationThreadUpdate(commit, response.data);
        return;
      }

      const response = await ConversationApi.assignAgent({
        conversationId,
        agentId,
      });
      dispatch('setCurrentChatAssignee', {
        conversationId,
        assignee: response.data,
      });
    } catch (error) {
      // Handle error
    }
  },

  setCurrentChatAssignee({ commit }, { conversationId, assignee }) {
    commit(types.ASSIGN_AGENT, { conversationId, assignee });
  },

  assignTeam: async (
    { commit, dispatch, state },
    { conversationId, teamId }
  ) => {
    try {
      const communicationThread = getCommunicationThreadById(
        state,
        conversationId
      );
      if (communicationThread) {
        const response = await CommunicationThreadApi.update(conversationId, {
          team_id: teamId,
        });
        commitCommunicationThreadUpdate(commit, response.data);
        return;
      }

      const response = await ConversationApi.assignTeam({
        conversationId,
        teamId,
      });
      dispatch('setCurrentChatTeam', { team: response.data, conversationId });
    } catch (error) {
      // Handle error
    }
  },

  setCurrentChatTeam({ commit }, { team, conversationId }) {
    commit(types.ASSIGN_TEAM, { team, conversationId });
  },

  toggleStatus: async (
    { commit, state },
    { conversationId, status, snoozedUntil = null, customAttributes = null }
  ) => {
    try {
      const communicationThread = getCommunicationThreadById(
        state,
        conversationId
      );
      if (communicationThread) {
        const response = await CommunicationThreadApi.update(conversationId, {
          status,
          snoozed_until: snoozedUntil,
        });
        commitCommunicationThreadUpdate(commit, response.data);
        return;
      }

      // Update custom attributes first if provided
      if (customAttributes) {
        const response = await ConversationApi.updateCustomAttributes({
          conversationId,
          customAttributes,
        });
        const { custom_attributes } = response.data;
        commit(types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES, {
          conversationId,
          customAttributes: custom_attributes,
        });
      }

      const {
        data: {
          payload: {
            current_status: updatedStatus,
            snoozed_until: updatedSnoozedUntil,
          } = {},
        } = {},
      } = await ConversationApi.toggleStatus({
        conversationId,
        status,
        snoozedUntil,
      });
      commit(types.CHANGE_CONVERSATION_STATUS, {
        conversationId,
        status: updatedStatus,
        snoozedUntil: updatedSnoozedUntil,
      });
    } catch (error) {
      // Handle error
    }
  },

  updateCommunicationThreadLabels: async (
    { commit },
    { conversationId, labels }
  ) => {
    const response = await CommunicationThreadApi.updateLabels(
      conversationId,
      labels
    );
    const updatedLabels = response.data?.payload || labels;
    commitCommunicationThreadUpdate(commit, {
      id: conversationId,
      labels: updatedLabels,
    });
    return updatedLabels;
  },

  createPendingMessageAndSend: async ({ dispatch }, data) => {
    const pendingMessage = createPendingMessage(data);
    dispatch('sendMessageWithData', pendingMessage);
  },

  sendMessageWithData: async ({ commit }, pendingMessage) => {
    const { conversation_id: conversationId, id } = pendingMessage;
    const communicationThreadId =
      pendingMessage.communication_thread_id ||
      pendingMessage.communicationThreadId;
    const addMessage = message => {
      commit(types.ADD_MESSAGE, message);
      if (communicationThreadId) {
        commit(types.ADD_MESSAGE_TO_CHAT, {
          chatId: communicationThreadId,
          message,
        });
      }
    };

    try {
      addMessage({
        ...pendingMessage,
        status: MESSAGE_STATUS.PROGRESS,
      });
      let response;
      if (hasMessageFailedWithExternalError(pendingMessage)) {
        response = await MessageApi.retry(conversationId, id);
      } else if (communicationThreadId) {
        response = await CommunicationThreadApi.createMessage(
          communicationThreadId,
          pendingMessage
        );
      } else {
        response = await MessageApi.create(pendingMessage);
      }
      addMessage({
        ...response.data,
        status: MESSAGE_STATUS.SENT,
      });
      commit(types.ADD_CONVERSATION_ATTACHMENTS, {
        ...response.data,
        status: MESSAGE_STATUS.SENT,
      });
    } catch (error) {
      const errorMessage = error.response
        ? error.response.data.error
        : undefined;
      addMessage({
        ...pendingMessage,
        meta: {
          error: errorMessage,
        },
        status: MESSAGE_STATUS.FAILED,
      });
      throw error;
    }
  },

  addMessage({ commit, rootGetters, state }, message) {
    commit(types.ADD_MESSAGE, message);
    addMessageToCommunicationThreads(commit, state, message);
    if (message.message_type === MESSAGE_TYPE.INCOMING) {
      commit(types.SET_CONVERSATION_CAN_REPLY, {
        conversationId: message.conversation_id,
        canReply: true,
      });
    }
    if (
      message.message_type === MESSAGE_TYPE.INCOMING ||
      message.attachments?.length
    ) {
      commit(types.ADD_CONVERSATION_ATTACHMENTS, message);
    }
    handleVoiceCallCreated(message, rootGetters?.getCurrentUserID);
  },

  updateMessage({ commit, rootGetters, state }, message) {
    commit(types.ADD_MESSAGE, message);
    addMessageToCommunicationThreads(commit, state, message);
    if (message.attachments?.length) {
      commit(types.ADD_CONVERSATION_ATTACHMENTS, message);
    }
    handleVoiceCallUpdated(commit, message, rootGetters?.getCurrentUserID);
  },

  updateMessageContent: async (
    { commit, state },
    { conversationId, messageId, content }
  ) => {
    const { data } = await MessageApi.update(conversationId, messageId, {
      content,
    });
    commit(types.ADD_MESSAGE, data);
    addMessageToCommunicationThreads(commit, state, data);
    return data;
  },

  deleteMessage: async function deleteLabels(
    { commit },
    { conversationId, messageId }
  ) {
    try {
      const { data } = await MessageApi.delete(conversationId, messageId);
      commit(types.ADD_MESSAGE, data);
      commit(types.DELETE_CONVERSATION_ATTACHMENTS, data);
    } catch (error) {
      throw new Error(error);
    }
  },

  deleteConversation: async ({ commit, dispatch }, conversationId) => {
    try {
      await ConversationApi.delete(conversationId);
      commit(types.DELETE_CONVERSATION, conversationId);
      dispatch('conversationStats/get', {}, { root: true });
    } catch (error) {
      throw new Error(error);
    }
  },

  deleteCommunicationThreadConversations: async (
    { commit, dispatch },
    { threadId, conversationIds }
  ) => {
    try {
      const { data } = await CommunicationThreadApi.deleteConversations(
        threadId,
        conversationIds
      );
      const deletedConversationIds =
        data?.deleted_conversation_ids || conversationIds;
      commit(types.DELETE_COMMUNICATION_THREAD_CONVERSATIONS, {
        threadId,
        conversationIds: deletedConversationIds,
      });
      dispatch(
        'conversationStats/get',
        { communicationThreadMode: true },
        { root: true }
      );
      dispatch('fetchSidebarUnreadCounts');
      return data;
    } catch (error) {
      throw new Error(error);
    }
  },

  addConversation({ commit, state, dispatch, rootState }, conversation) {
    const { currentInbox, appliedFilters } = state;
    const {
      inbox_id: inboxId,
      meta: { sender },
    } = conversation;
    const hasAppliedFilters = !!appliedFilters.length;
    const isMatchingInboxFilter =
      !currentInbox || Number(currentInbox) === inboxId;
    if (
      !hasAppliedFilters &&
      !isOnFoldersView(rootState) &&
      !isOnMentionsView(rootState) &&
      !isOnParticipatingView(rootState) &&
      !isOnUnattendedView(rootState) &&
      isMatchingInboxFilter
    ) {
      commit(types.ADD_CONVERSATION, conversation);
      dispatch('contacts/setContact', sender);
    }
  },

  addMentions({ dispatch, rootState }, conversation) {
    if (isOnMentionsView(rootState)) {
      dispatch('updateConversation', conversation);
    }
  },

  addUnattended({ dispatch, rootState }, conversation) {
    if (isOnUnattendedView(rootState)) {
      dispatch('updateConversation', conversation);
    }
  },

  updateConversation({ commit, dispatch }, conversation) {
    const {
      meta: { sender },
    } = conversation;

    commit(types.UPDATE_CONVERSATION, conversation);

    dispatch('conversationLabels/setConversationLabel', {
      id: conversation.id,
      data: conversation.labels,
    });

    dispatch('contacts/setContact', sender);
  },

  updateCommunicationThreadRealtime({ commit, dispatch }, payload) {
    const communicationThread = commitCommunicationThreadUpdate(
      commit,
      payload,
      { realtime: true }
    );
    const sender = payload?.meta?.sender;
    if (sender?.id) {
      dispatch('contacts/setContact', sender);
    }
    if (Object.prototype.hasOwnProperty.call(payload || {}, 'labels')) {
      dispatch('conversationLabels/setConversationLabel', {
        id: communicationThread.id,
        data: payload.labels,
      });
    }
    if (payload?.source_event === 'conversation.contact_changed') {
      dispatch('fetchCommunicationThreads');
    }
  },

  updateConversationLastActivity(
    { commit },
    { conversationId, lastActivityAt }
  ) {
    commit(types.UPDATE_CONVERSATION_LAST_ACTIVITY, {
      lastActivityAt,
      conversationId,
    });
  },

  setChatStatusFilter({ commit }, data) {
    commit(types.CHANGE_CHAT_STATUS_FILTER, data);
  },

  setChatSortFilter({ commit }, data) {
    commit(types.CHANGE_CHAT_SORT_FILTER, data);
  },

  updateAssignee({ commit }, data) {
    commit(types.UPDATE_ASSIGNEE, data);
  },

  updateConversationContact({ commit }, data) {
    if (data.id) {
      commit(`contacts/${types.SET_CONTACT_ITEM}`, data);
    }
    commit(types.UPDATE_CONVERSATION_CONTACT, data);
  },

  updateContactInConversations({ commit }, contact) {
    commit(types.UPDATE_CONTACT_IN_CONVERSATIONS, contact);
  },

  setActiveInbox({ commit }, inboxId) {
    commit(types.SET_ACTIVE_INBOX, inboxId);
  },

  muteConversation: async ({ commit }, conversationId) => {
    try {
      await ConversationApi.mute(conversationId);
      commit(types.MUTE_CONVERSATION);
    } catch (error) {
      //
    }
  },

  unmuteConversation: async ({ commit }, conversationId) => {
    try {
      await ConversationApi.unmute(conversationId);
      commit(types.UNMUTE_CONVERSATION);
    } catch (error) {
      //
    }
  },

  sendEmailTranscript: async (_, { conversationId, email }) => {
    await ConversationApi.sendEmailTranscript({ conversationId, email });
  },

  updateCustomAttributes: async (
    { commit },
    { conversationId, customAttributes }
  ) => {
    const response = await ConversationApi.updateCustomAttributes({
      conversationId,
      customAttributes,
    });
    const { custom_attributes } = response.data;
    commit(types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES, {
      conversationId,
      customAttributes: custom_attributes,
    });
  },

  setConversationPinned: async ({ dispatch }, { conversationId, pinned }) => {
    if (pinned) {
      await dispatch('updateCustomAttributes', {
        conversationId,
        customAttributes: { pinned: true },
      });
      return;
    }

    await dispatch('deleteCustomAttributes', {
      conversationId,
      customAttributes: ['pinned'],
    });
  },

  deleteCustomAttributes: async (
    { commit },
    { conversationId, customAttributes }
  ) => {
    const response = await ConversationApi.destroyCustomAttributes({
      conversationId,
      customAttributes,
    });
    const { custom_attributes } = response.data;
    commit(types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES, {
      conversationId,
      customAttributes: custom_attributes,
    });
  },

  setConversationFilters({ commit }, data) {
    commit(types.SET_CONVERSATION_FILTERS, data);
  },

  clearConversationFilters({ commit }) {
    commit(types.CLEAR_CONVERSATION_FILTERS);
  },

  setChatListFilters({ commit }, data) {
    commit(types.SET_CHAT_LIST_FILTERS, data);
  },

  updateChatListFilters({ commit }, data) {
    commit(types.UPDATE_CHAT_LIST_FILTERS, data);
  },

  assignPriority: async (
    { commit, dispatch, state },
    { conversationId, priority }
  ) => {
    try {
      const communicationThread = getCommunicationThreadById(
        state,
        conversationId
      );
      if (communicationThread) {
        const response = await CommunicationThreadApi.update(conversationId, {
          priority,
        });
        commitCommunicationThreadUpdate(commit, response.data);
        return;
      }

      await ConversationApi.togglePriority({
        conversationId,
        priority,
      });

      dispatch('setCurrentChatPriority', {
        priority,
        conversationId,
      });
    } catch (error) {
      // Handle error
    }
  },

  setCurrentChatPriority({ commit }, { priority, conversationId }) {
    commit(types.ASSIGN_PRIORITY, { priority, conversationId });
  },

  setContextMenuChatId({ commit }, chatId) {
    commit(types.SET_CONTEXT_MENU_CHAT_ID, chatId);
  },

  getInboxCaptainAssistantById: async ({ commit }, conversationId) => {
    try {
      const response = await ConversationApi.getInboxAssistant(conversationId);
      commit(types.SET_INBOX_CAPTAIN_ASSISTANT, response.data);
    } catch (error) {
      // Handle error
    }
  },

  ...messageReadActions,
  ...messageTranslateActions,
};

export default actions;
