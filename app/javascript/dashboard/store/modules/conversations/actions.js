import types from '../../mutation-types';
import ConversationApi from '../../../api/inbox/conversation';
import CommunicationThreadApi from '../../../api/inbox/communicationThread';
import MessageApi from '../../../api/inbox/message';
import { MESSAGE_STATUS, MESSAGE_TYPE } from 'shared/constants/messages';
import { createPendingMessage } from 'dashboard/helper/commons';
import { createSingleFlight } from 'dashboard/helper/singleFlight';
import {
  buildCommunicationThreadConversation,
  isCommunicationThread,
  isMessageInCommunicationThread,
} from 'dashboard/helper/communicationThreadHelper';
import {
  buildConversationList,
  setContacts,
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
import { isCaptainToolActivityMessage } from 'dashboard/components-next/message/timelineMessageVisibility';

let conversationListRequestGeneration = 0;
const communicationThreadListUpdates = new Map();

const replayCommunicationThreadListUpdates = (generation, context, apply) => {
  const updates = communicationThreadListUpdates.get(generation) || [];
  communicationThreadListUpdates.delete(generation);
  updates.forEach(payload => {
    const threadId = payload.communication_thread_id || payload.id;
    const current = context.state?.allConversations?.find(
      chat =>
        String(chat.id) === String(threadId) && isCommunicationThread(chat)
    );
    // The HTTP snapshot can itself be newer than an event received in flight.
    if (payload.updated_at < current?.updated_at) return;
    apply(context, payload);
  });
};
let sidebarUnreadCountsRequestId = 0;
const sidebarUnreadCountsFlight = createSingleFlight();

const startConversationListRequest = () => {
  conversationListRequestGeneration += 1;
  sidebarUnreadCountsRequestId += 1;
  return conversationListRequestGeneration;
};

const invalidateConversationListRequest = commit => {
  startConversationListRequest();
  CommunicationThreadApi.invalidateListRequests();
  commit(types.CLEAR_LIST_LOADING_STATUS);
};

const isExpectedRouteCurrent = (rootState, expectedRouteFullPath) =>
  !expectedRouteFullPath ||
  rootState?.route?.fullPath === expectedRouteFullPath;

const requestContext = request =>
  request && typeof request === 'object'
    ? request
    : { conversationId: request };

const preserveConversationState = (conversation, previousState) => {
  if (!previousState) return conversation;

  return {
    ...conversation,
    ...(previousState.messages ? { messages: previousState.messages } : {}),
    ...(previousState.allMessagesLoaded !== undefined
      ? { allMessagesLoaded: previousState.allMessagesLoaded }
      : {}),
    ...(previousState.dataFetched !== undefined
      ? { dataFetched: previousState.dataFetched }
      : {}),
    ...(previousState.firstUnreadMessageId !== undefined
      ? {
          meta: {
            ...conversation.meta,
            first_unread_message_id: previousState.firstUnreadMessageId,
          },
        }
      : {}),
  };
};

const SIDEBAR_UNREAD_COUNT_FILTER_KEYS = [
  'inboxId',
  'status',
  'assigneeType',
  'labels',
  'labelsScope',
  'teamId',
  'teamScope',
  'conversationType',
  'communicationThreadMode',
  'crmPipelineId',
  'crmStageId',
  'appointmentStatus',
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

const findActiveChatById = (state, conversationId, conversationType = null) => {
  if (conversationType) {
    return findChatByIdAndType(state, conversationId, conversationType);
  }

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

// Opening a conversation loads only the newest page. The server cursor of the
// first unread message is kept on the chat so the unread divider and the
// "N unread" jump can load the older unread range on demand.
const withFirstUnreadCursor = (chatMeta, request, responseMeta) => {
  if (request.after || request.before) return chatMeta || {};

  return {
    ...(chatMeta || {}),
    first_unread_message_id: responseMeta?.first_unread_message_id || null,
  };
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

const getCommunicationThreadTarget = (
  state,
  conversationId,
  conversationType = null
) => {
  if (conversationType === 'communication_thread') {
    return findChatByIdAndType(state, conversationId, 'communication_thread');
  }
  if (conversationType === 'conversation') {
    return null;
  }

  return getCommunicationThreadById(state, conversationId);
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
  const threadPayload = { ...(payload || {}) };
  delete threadPayload.message;
  delete threadPayload.messages;

  const threadId = threadPayload.communication_thread_id || threadPayload.id;
  return {
    ...threadPayload,
    id: threadId,
    display_id: threadId,
    communication_thread_id: threadId,
    is_communication_thread: true,
  };
};

const communicationThreadRealtimeMessages = payload => {
  const messages = [];
  if (payload?.message) messages.push(payload.message);
  if (Array.isArray(payload?.messages)) messages.push(...payload.messages);

  return messages.filter(Boolean);
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

const refreshSidebarUnreadCounts = async (
  { commit, dispatch, state = {} },
  params = null
) => {
  sidebarUnreadCountsRequestId += 1;
  const requestId = sidebarUnreadCountsRequestId;
  const requestGeneration = conversationListRequestGeneration;
  try {
    const requestParams = params || state.conversationFilters || {};
    let counts = {};
    let metaData;

    if (hasSidebarUnreadCountFilters(requestParams)) {
      let meta;
      if (requestParams.communicationThreadMode && requestParams.queryData) {
        const response = await CommunicationThreadApi.filterMeta(requestParams);
        meta = response.data?.data?.meta;
      } else {
        const statsApi = requestParams.communicationThreadMode
          ? CommunicationThreadApi
          : ConversationApi;
        const response = await statsApi.meta(requestParams);
        meta = response.data?.meta;
      }
      metaData = meta;
      counts = meta?.unread_counts || {};
    } else {
      const {
        data: { counts: globalCounts },
      } = await ConversationApi.sidebarUnreadCounts();
      counts = globalCounts;
    }

    if (requestGeneration !== conversationListRequestGeneration) {
      return undefined;
    }

    if (requestParams.communicationThreadMode && metaData) {
      dispatch('conversationStats/set', metaData);
    }
    if (requestId !== sidebarUnreadCountsRequestId) return undefined;

    commit(types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS, counts || {});
    return counts || {};
  } catch (error) {
    // Keep the last known sidebar counts if the refresh fails.
    return undefined;
  }
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
  invalidateConversationListRequests({ commit }) {
    invalidateConversationListRequest(commit);
  },

  getConversation: async ({ commit, dispatch, state, rootState }, request) => {
    const {
      conversationId,
      expectedRouteFullPath,
      preserveConversationState: previousState,
      resumeActiveConversation = false,
    } = requestContext(request);
    if (
      !conversationId ||
      !isExpectedRouteCurrent(rootState, expectedRouteFullPath)
    ) {
      return null;
    }

    try {
      const response = await ConversationApi.show(conversationId);
      if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath))
        return null;

      const conversation = preserveConversationState(
        response.data,
        previousState
      );
      const exists = state.allConversations.some(
        existingConversation =>
          existingConversation.id === conversation.id &&
          !isCommunicationThread(existingConversation)
      );

      if (exists) {
        commit(types.UPDATE_CONVERSATION, conversation);
      } else {
        commit(types.ADD_CONVERSATION, conversation);
      }

      commit(`contacts/${types.SET_CONTACT_ITEM}`, conversation.meta.sender);
      if (resumeActiveConversation) {
        await dispatch('setActiveChat', {
          data: conversation,
          expectedRouteFullPath,
          resumeActiveConversation: true,
        });
      }
      return conversation;
    } catch (error) {
      // Ignore error
      return null;
    }
  },

  fetchAllConversations: async (
    { commit, state, dispatch, rootState },
    { expectedRouteFullPath } = {}
  ) => {
    if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) return;
    const requestGeneration = startConversationListRequest();
    commit(types.SET_LIST_LOADING_STATUS);
    try {
      const params = state.conversationFilters;
      const isFirstPage = Number(params.page || 1) === 1;
      const {
        data: { data },
      } = await ConversationApi.get({ ...params, includeMeta: isFirstPage });
      if (requestGeneration !== conversationListRequestGeneration) return;
      if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) {
        commit(types.CLEAR_LIST_LOADING_STATUS);
        return;
      }
      buildConversationList(
        { commit, dispatch },
        params,
        data,
        params.assigneeType,
        isFirstPage
      );
    } catch (error) {
      if (requestGeneration === conversationListRequestGeneration) {
        commit(types.CLEAR_LIST_LOADING_STATUS, { error: true });
      }
    }
  },

  fetchCommunicationThreads: async (
    { commit, state, dispatch, rootState },
    { expectedRouteFullPath } = {}
  ) => {
    if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) return;
    const requestGeneration = startConversationListRequest();
    communicationThreadListUpdates.set(requestGeneration, []);
    commit(types.SET_LIST_LOADING_STATUS);
    try {
      const params = state.conversationFilters;
      const isFirstPage = Number(params.page || 1) === 1;
      const {
        data: { data },
      } = await CommunicationThreadApi.get({
        ...params,
        includeMeta: false,
      });
      if (requestGeneration !== conversationListRequestGeneration) return;
      if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) {
        commit(types.CLEAR_LIST_LOADING_STATUS);
        return;
      }
      buildConversationList(
        { commit, dispatch },
        params,
        {
          meta: data.meta || {},
          payload: (data.payload || []).map(
            buildCommunicationThreadConversation
          ),
        },
        params.assigneeType,
        isFirstPage
      );
      replayCommunicationThreadListUpdates(
        requestGeneration,
        { commit, state, dispatch },
        actions.updateCommunicationThreadRealtime
      );
      if (isFirstPage) dispatch('fetchSidebarUnreadCounts', params);
    } catch (error) {
      if (requestGeneration === conversationListRequestGeneration) {
        commit(types.CLEAR_LIST_LOADING_STATUS, { error: true });
      }
    } finally {
      communicationThreadListUpdates.delete(requestGeneration);
    }
  },

  getCommunicationThread: async ({ commit, dispatch, rootState }, request) => {
    const {
      conversationId,
      expectedRouteFullPath,
      preserveConversationState: previousState,
      resumeActiveConversation = false,
    } = requestContext(request);
    if (
      !conversationId ||
      !isExpectedRouteCurrent(rootState, expectedRouteFullPath)
    ) {
      return null;
    }

    try {
      const response = await CommunicationThreadApi.show(conversationId);
      if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath))
        return null;

      const communicationThread = preserveConversationState(
        buildCommunicationThreadConversation(response.data),
        previousState
      );
      commit(types.SET_ALL_CONVERSATION, [communicationThread]);
      commit(
        `contacts/${types.SET_CONTACT_ITEM}`,
        communicationThread.meta.sender
      );
      if (resumeActiveConversation) {
        await dispatch('setActiveChat', {
          data: communicationThread,
          expectedRouteFullPath,
          resumeActiveConversation: true,
        });
      }
      return communicationThread;
    } catch (error) {
      return null;
    }
  },

  // Overlapping refreshes with the same filters share one request instead of each asking the server.
  fetchSidebarUnreadCounts: (context, params = null) => {
    const requestParams = params || context.state?.conversationFilters || {};
    return sidebarUnreadCountsFlight(JSON.stringify(requestParams), () =>
      refreshSidebarUnreadCounts(context, params)
    );
  },

  fetchRealtimeSidebarUnreadCounts: async (
    { commit, dispatch, state = {} },
    params = null
  ) => {
    const requestParams = params || state.conversationFilters || {};
    if (!requestParams.communicationThreadMode) {
      return dispatch('fetchSidebarUnreadCounts', requestParams);
    }

    sidebarUnreadCountsRequestId += 1;
    const requestId = sidebarUnreadCountsRequestId;
    const requestGeneration = conversationListRequestGeneration;
    try {
      const response = requestParams.queryData
        ? await CommunicationThreadApi.filterSidebarUnreadCounts(requestParams)
        : await CommunicationThreadApi.sidebarUnreadCounts(requestParams);
      if (
        requestGeneration !== conversationListRequestGeneration ||
        requestId !== sidebarUnreadCountsRequestId
      ) {
        return undefined;
      }

      const counts = response.data?.counts || {};
      commit(types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS, counts);
      return counts;
    } catch (error) {
      // Keep the last known sidebar counts if the lightweight refresh fails.
      return undefined;
    }
  },

  // Search box of the conversation list. The server searches all statuses and assignees, so the results are only
  // added to the store (to open them and keep them live); the list, its pagination and its counters stay as they were.
  fetchListSearchResults: async (
    { commit, dispatch },
    { q, page = 1, communicationThreadMode = false }
  ) => {
    const api = communicationThreadMode
      ? CommunicationThreadApi
      : ConversationApi;
    const {
      data: { data },
    } = await api.listSearch({ q, page });
    const payload = data.payload || [];
    const conversations = communicationThreadMode
      ? payload.map(buildCommunicationThreadConversation)
      : payload;

    commit(types.SET_ALL_CONVERSATION, conversations);
    dispatch('conversationLabels/setBulkConversationLabels', conversations);
    setContacts(commit, conversations);
    return { conversations, meta: data.meta || {} };
  },

  fetchFilteredConversations: async (
    { commit, state, dispatch, rootState },
    params
  ) => {
    const { expectedRouteFullPath, ...requestParams } = params || {};
    if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) return;

    const requestGeneration = startConversationListRequest();
    if (requestParams?.communicationThreadMode) {
      communicationThreadListUpdates.set(requestGeneration, []);
    }
    commit(types.SET_LIST_LOADING_STATUS);
    try {
      const isFirstPage = Number(requestParams.page || 1) === 1;
      const filterApi = requestParams?.communicationThreadMode
        ? CommunicationThreadApi
        : ConversationApi;
      // Thread filters never carry counts (fetched apart); native ones only on the first page.
      const { data } = requestParams?.communicationThreadMode
        ? await filterApi.filter(requestParams)
        : await filterApi.filter(requestParams, { includeMeta: isFirstPage });
      if (requestGeneration !== conversationListRequestGeneration) return;
      if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) {
        commit(types.CLEAR_LIST_LOADING_STATUS);
        return;
      }
      const responseData = requestParams?.communicationThreadMode
        ? {
            meta: data.data?.meta || {},
            payload: (data.data?.payload || []).map(
              buildCommunicationThreadConversation
            ),
          }
        : data;
      buildConversationList(
        { commit, dispatch },
        requestParams,
        responseData,
        'appliedFilters',
        isFirstPage
      );
      replayCommunicationThreadListUpdates(
        requestGeneration,
        { commit, state, dispatch },
        actions.updateCommunicationThreadRealtime
      );
      if (requestParams?.communicationThreadMode && isFirstPage) {
        dispatch('fetchSidebarUnreadCounts', requestParams);
      }
    } catch (error) {
      if (requestGeneration === conversationListRequestGeneration) {
        commit(types.CLEAR_LIST_LOADING_STATUS, { error: true });
      }
    } finally {
      communicationThreadListUpdates.delete(requestGeneration);
    }
  },

  emptyAllConversations({ commit }) {
    commit(types.EMPTY_ALL_CONVERSATION);
  },

  clearSelectedState({ commit }) {
    commit(types.CLEAR_CURRENT_CHAT_WINDOW);
  },

  fetchPreviousMessages: async ({ commit, state, rootState }, data) => {
    if (!isExpectedRouteCurrent(rootState, data.expectedRouteFullPath)) return;
    try {
      const conversationType = activeChatTypeForPayload(state, data);
      const selectedChat = findActiveChatById(
        state,
        data.conversationId,
        conversationType
      );

      if (selectedChat?.is_communication_thread) {
        const {
          data: { meta, payload },
        } = await CommunicationThreadApi.messages(data.conversationId, {
          after: data.after,
          before: data.before,
          include_history: true,
          ...(data.includeTarget ? { include_target: true } : {}),
        });
        if (!isExpectedRouteCurrent(rootState, data.expectedRouteFullPath))
          return;
        const messagesPayload = payload;
        selectedChat.channels = meta.channels || selectedChat.channels || [];
        selectedChat.meta = {
          ...withFirstUnreadCursor(selectedChat.meta, data, meta),
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
      if (!isExpectedRouteCurrent(rootState, data.expectedRouteFullPath))
        return;
      const messagesPayload = payload;
      if (selectedChat) {
        selectedChat.meta = withFirstUnreadCursor(
          selectedChat.meta,
          data,
          meta
        );
      }
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
    { commit, state, dispatch, rootState },
    {
      conversationId,
      conversationType: requestedConversationType,
      expectedRouteFullPath,
    }
  ) => {
    if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) return;
    const { syncConversationsMessages } = state;
    const selectedChat = findActiveChatById(
      state,
      conversationId,
      requestedConversationType
    );
    if (!selectedChat) return;
    const conversationType =
      activeChatTypeForPayload(state, {
        conversationId,
        conversationType: requestedConversationType,
      }) ||
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
      if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) return;
      commit(`conversationMetadata/${types.SET_CONVERSATION_METADATA}`, {
        id: conversationId,
        data: meta,
      });
      if (selectedChat.is_communication_thread) {
        selectedChat.channels = meta.channels || selectedChat.channels || [];
      }
      // Merge fresh messages through the mutation path so local pending echoes
      // are reconciled with server-delivered messages consistently.
      const missingMessages = payload.filter(
        message => !messages.find(item => item.id === message.id)
      );
      commit(
        types.SET_PREVIOUS_CONVERSATIONS,
        withConversationType(
          {
            id: conversationId,
            data: missingMessages,
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
    { conversationId, conversationType: requestedConversationType }
  ) => {
    const selectedChat = findActiveChatById(
      state,
      conversationId,
      requestedConversationType
    );
    if (!selectedChat) return;
    const conversationType =
      activeChatTypeForPayload(state, {
        conversationId,
        conversationType: requestedConversationType,
      }) ||
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

  async setActiveChat(
    { commit, dispatch, rootState },
    { data, after, expectedRouteFullPath, resumeActiveConversation = false }
  ) {
    if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) return;

    commit(
      types.SET_CURRENT_CHAT_WINDOW,
      resumeActiveConversation ? { ...data, preserveUnreadCursor: true } : data
    );
    const conversationType = conversationStoreType(data);
    if (!resumeActiveConversation) {
      commit(types.CLEAR_ALL_MESSAGES_LOADED, {
        id: data.id,
        conversationType,
      });
    }
    if (data.dataFetched === undefined) {
      try {
        const fetchParams = {
          after,
          ...(after && data.is_communication_thread
            ? { includeTarget: true }
            : {}),
          conversationId: data.id,
          conversationType,
          ...(expectedRouteFullPath !== undefined
            ? { expectedRouteFullPath }
            : {}),
        };

        if (
          after &&
          (!data.is_communication_thread ||
            Number(after) < Number(data.messages?.[0]?.id))
        ) {
          fetchParams.before = data.messages?.[0]?.id;
        }

        await dispatch('fetchPreviousMessages', fetchParams);
        if (!isExpectedRouteCurrent(rootState, expectedRouteFullPath)) return;
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
    { conversationId, agentId, conversationType = null, throwOnError = false }
  ) => {
    try {
      const communicationThread = getCommunicationThreadTarget(
        state,
        conversationId,
        conversationType
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
      if (throwOnError) throw error;
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
    {
      conversationId,
      status,
      snoozedUntil = null,
      customAttributes = null,
      statusReason = null,
      conversationType = null,
    }
  ) => {
    invalidateConversationListRequest(commit);
    try {
      const communicationThread = getCommunicationThreadTarget(
        state,
        conversationId,
        conversationType
      );
      if (communicationThread) {
        const response = await CommunicationThreadApi.update(conversationId, {
          status,
          snoozed_until: snoozedUntil,
          status_reason: statusReason,
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
        statusReason,
      });
      commit(types.CHANGE_CONVERSATION_STATUS, {
        conversationId,
        conversationType: 'conversation',
        status: updatedStatus,
        snoozedUntil: updatedSnoozedUntil,
      });
    } catch (error) {
      if (conversationType === 'communication_thread') throw error;
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
    // Hidden timeline events must not move the open conversation or its unread state.
    if (isCaptainToolActivityMessage(message)) return;

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
    if (isCaptainToolActivityMessage(message)) return;

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
    // Keep realtime patches received during this list request. Replay them
    // after its snapshot rather than dropping the page or starting more GETs.
    communicationThreadListUpdates
      .get(conversationListRequestGeneration)
      ?.push(payload);
    CommunicationThreadApi.invalidateListRequests();
    const communicationThread = commitCommunicationThreadUpdate(
      commit,
      payload,
      { realtime: true }
    );
    communicationThreadRealtimeMessages(payload).forEach(message => {
      commit(types.ADD_MESSAGE_TO_CHAT, {
        chatId: communicationThread.id,
        message,
      });
    });
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

  setCommunicationThreadPinned: async (
    { commit },
    { conversationId, pinned }
  ) => {
    const payload = pinned
      ? { custom_attributes: { pinned: true } }
      : { destroy_custom_attributes: ['pinned'] };
    const response = await CommunicationThreadApi.update(
      conversationId,
      payload
    );
    commitCommunicationThreadUpdate(commit, response.data);
  },

  setConversationPinned: async (
    { dispatch, state },
    { conversationId, pinned, conversationType = null }
  ) => {
    const communicationThread = getCommunicationThreadTarget(
      state,
      conversationId,
      conversationType
    );
    if (communicationThread) {
      await dispatch('setCommunicationThreadPinned', {
        conversationId,
        pinned,
      });
      return;
    }

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
