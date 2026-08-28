import { throwErrorMessage } from 'dashboard/store/utils/api';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import CommunicationThreadApi from '../../../../api/inbox/communicationThread';
import ConversationApi from '../../../../api/inbox/conversation';
import mutationTypes from '../../../mutation-types';

const communicationThreadReadRevisions = new Map();
const communicationThreadReadOperations = new Map();

const nextCommunicationThreadReadRevision = revisionKey => {
  const revision = (communicationThreadReadRevisions.get(revisionKey) || 0) + 1;
  communicationThreadReadRevisions.set(revisionKey, revision);
  return revision;
};

const markCommunicationThreadReadWithRetry = async (data, attempt = 1) => {
  try {
    return await CommunicationThreadApi.markMessageRead(data);
  } catch (error) {
    if (attempt >= 2) throw error;
    return markCommunicationThreadReadWithRetry(data, attempt + 1);
  }
};

const enqueueCommunicationThreadReadOperation = (operationKey, operation) => {
  const previousOperation = communicationThreadReadOperations.get(operationKey);
  const currentOperation = (previousOperation || Promise.resolve())
    .catch(() => undefined)
    .then(operation);
  communicationThreadReadOperations.set(operationKey, currentOperation);

  return currentOperation.finally(() => {
    if (
      communicationThreadReadOperations.get(operationKey) === currentOperation
    ) {
      communicationThreadReadOperations.delete(operationKey);
    }
  });
};

const refreshCommunicationThreadStats = (dispatch, state) =>
  dispatch(
    'conversationStats/get',
    {
      communicationThreadMode: true,
      status: state?.conversationFilters?.status,
    },
    { root: true }
  );

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

const shouldUseCommunicationThreadApi = (state, { id, conversationType }) => {
  if (conversationType === 'communication_thread') return true;
  if (conversationType === 'conversation') return false;

  return Boolean(getCommunicationThreadById(state, id));
};

export default {
  markMessagesRead: async ({ commit, dispatch }, data) => {
    try {
      const {
        data: { id, agent_last_seen_at: lastSeen },
      } = await ConversationApi.markMessageRead(data);
      commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, {
        id,
        lastSeen,
        unreadCount: 0,
      });
      dispatch('fetchSidebarUnreadCounts');
    } catch (error) {
      // Handle error
    }
  },

  markCommunicationThreadRead: async (
    { commit, dispatch, state, rootGetters },
    data
  ) => {
    const communicationThread = (state?.allConversations || []).find(
      chat => String(chat.id) === String(data.id) && isCommunicationThread(chat)
    );
    if (communicationThread?.unread_count === 0) return;

    const previousUnreadCount = communicationThread?.unread_count;
    const previousLastSeen = communicationThread?.agent_last_seen_at;
    const optimisticLastSeen = Math.floor(Date.now() / 1000);
    const revisionKey = `${rootGetters?.getCurrentAccountId || 'current'}:${data.id}`;
    const revision = nextCommunicationThreadReadRevision(revisionKey);
    const isCurrentRevision = () =>
      communicationThreadReadRevisions.get(revisionKey) === revision;
    commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, {
      id: data.id,
      lastSeen: optimisticLastSeen,
      unreadCount: 0,
      conversationType: 'communication_thread',
    });
    try {
      const { data: readState } = await enqueueCommunicationThreadReadOperation(
        revisionKey,
        () => markCommunicationThreadReadWithRetry(data)
      );
      if (!isCurrentRevision()) return;
      const currentThread = (state?.allConversations || []).find(
        chat =>
          String(chat.id) === String(data.id) && isCommunicationThread(chat)
      );
      const stateMatchesOptimisticRead =
        !currentThread ||
        (currentThread.unread_count === 0 &&
          currentThread.agent_last_seen_at === optimisticLastSeen) ||
        (currentThread.unread_count === previousUnreadCount &&
          currentThread.agent_last_seen_at === previousLastSeen);
      if (!stateMatchesOptimisticRead) {
        refreshCommunicationThreadStats(dispatch, state);
        return;
      }
      const lastSeen = readState.agent_last_seen_at || optimisticLastSeen;
      const unreadPayload = {
        id: readState.id,
        lastSeen,
        unreadCount: readState.unread_count,
        conversationType: 'communication_thread',
      };
      commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, unreadPayload);
      refreshCommunicationThreadStats(dispatch, state);
    } catch (error) {
      const currentThread = (state?.allConversations || []).find(
        chat =>
          String(chat.id) === String(data.id) && isCommunicationThread(chat)
      );
      const optimisticStateIsCurrent =
        !currentThread ||
        (currentThread.unread_count === 0 &&
          currentThread.agent_last_seen_at === optimisticLastSeen) ||
        (currentThread.unread_count === previousUnreadCount &&
          currentThread.agent_last_seen_at === previousLastSeen);
      if (
        isCurrentRevision() &&
        optimisticStateIsCurrent &&
        previousUnreadCount !== undefined
      ) {
        commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, {
          id: data.id,
          lastSeen: previousLastSeen,
          unreadCount: previousUnreadCount,
          conversationType: 'communication_thread',
        });
      }
      if (isCurrentRevision()) refreshCommunicationThreadStats(dispatch, state);
    }
  },

  markMessagesUnread: async (
    { commit, dispatch, state, rootGetters },
    data
  ) => {
    const { id } = data;
    const useCommunicationThreadApi = shouldUseCommunicationThreadApi(
      state,
      data
    );
    const revisionKey = `${rootGetters?.getCurrentAccountId || 'current'}:${id}`;
    const revision = useCommunicationThreadApi
      ? nextCommunicationThreadReadRevision(revisionKey)
      : null;
    const isCurrentRevision = () =>
      !useCommunicationThreadApi ||
      communicationThreadReadRevisions.get(revisionKey) === revision;
    try {
      if (useCommunicationThreadApi) {
        const { data: communicationThread } =
          await enqueueCommunicationThreadReadOperation(revisionKey, () =>
            CommunicationThreadApi.markMessagesUnread({ id })
          );
        if (!isCurrentRevision()) return;
        const unreadPayload = {
          id: communicationThread.id || id,
          lastSeen: communicationThread.agent_last_seen_at,
          unreadCount: communicationThread.unread_count,
          conversationType: 'communication_thread',
        };
        if (communicationThread.channels) {
          unreadPayload.channels = communicationThread.channels;
        }
        commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, unreadPayload);
        refreshCommunicationThreadStats(dispatch, state);
        return;
      }

      const {
        data: { agent_last_seen_at: lastSeen, unread_count: unreadCount },
      } = await ConversationApi.markMessagesUnread({ id });
      commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, {
        id,
        lastSeen,
        unreadCount,
      });
      dispatch('fetchSidebarUnreadCounts');
    } catch (error) {
      if (!isCurrentRevision()) return;
      throwErrorMessage(error);
    }
  },
};
