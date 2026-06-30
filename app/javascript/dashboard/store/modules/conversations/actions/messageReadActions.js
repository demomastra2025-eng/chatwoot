import { throwErrorMessage } from 'dashboard/store/utils/api';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import CommunicationThreadApi from '../../../../api/inbox/communicationThread';
import ConversationApi from '../../../../api/inbox/conversation';
import mutationTypes from '../../../mutation-types';

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

  markCommunicationThreadRead: async ({ commit, dispatch }, data) => {
    try {
      const { data: communicationThread } =
        await CommunicationThreadApi.markMessageRead(data);
      const lastSeen =
        communicationThread.agent_last_seen_at || Math.floor(Date.now() / 1000);
      const unreadPayload = {
        id: communicationThread.id,
        lastSeen,
        unreadCount: communicationThread.unread_count,
        conversationType: 'communication_thread',
      };
      if (communicationThread.channels) {
        unreadPayload.channels = communicationThread.channels;
      }
      commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, unreadPayload);
      dispatch('fetchSidebarUnreadCounts');
    } catch (error) {
      // Handle error
    }
  },

  markMessagesUnread: async ({ commit, dispatch, state }, data) => {
    const { id } = data;
    try {
      if (shouldUseCommunicationThreadApi(state, data)) {
        const { data: communicationThread } =
          await CommunicationThreadApi.markMessagesUnread({ id });
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
        dispatch('fetchSidebarUnreadCounts');
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
      throwErrorMessage(error);
    }
  },
};
