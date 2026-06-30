import { throwErrorMessage } from 'dashboard/store/utils/api';
import CommunicationThreadApi from '../../../../api/inbox/communicationThread';
import ConversationApi from '../../../../api/inbox/conversation';
import mutationTypes from '../../../mutation-types';

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
      commit(mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT, {
        id: communicationThread.id,
        lastSeen,
        unreadCount: communicationThread.unread_count,
        conversationType: 'communication_thread',
      });
      dispatch('fetchSidebarUnreadCounts');
    } catch (error) {
      // Handle error
    }
  },

  markMessagesUnread: async ({ commit, dispatch }, { id }) => {
    try {
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
