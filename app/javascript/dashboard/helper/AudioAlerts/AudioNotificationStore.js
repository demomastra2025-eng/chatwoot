import { CONVERSATION_ACCESS_PERMISSIONS } from 'dashboard/constants/permissions';
import { getUserPermissions } from 'dashboard/helper/permissionsHelper';
import {
  isCommunicationThread,
  isMessageInCommunicationThread,
} from 'dashboard/helper/communicationThreadHelper';
import wootConstants from 'dashboard/constants/globals';

class AudioNotificationStore {
  constructor(store) {
    this.store = store;
  }

  hasUnreadConversation = () => {
    const mineConversation = this.store.getters.getMineChats({
      assigneeType: 'me',
      status: 'open',
    });

    return mineConversation.some(conv => conv.unread_count > 0);
  };

  // Thread mode: the message carries the display id of its thread, and the
  // operator works with the thread (its own id, status and assignee), not with
  // the conversation of the channel the message came through.
  getCommunicationThread = (message = {}) => {
    const { communication_thread_id: threadId } = message || {};
    if (!threadId) return null;

    return (
      this.store.getters.getConversationById(
        threadId,
        'communication_thread'
      ) || null
    );
  };

  // The assignee an operator sees: the thread one in thread mode (the contact
  // owner or the latest routed conversation), the conversation one otherwise.
  // Falls back to the conversation of the message when the thread is not loaded.
  withVisibleAssignee = (message = {}) => {
    const thread = this.getCommunicationThread(message);
    if (!thread) return message;

    return {
      ...message,
      conversation: {
        ...message.conversation,
        assignee_id: thread.meta?.assignee?.id ?? thread.assignee_id ?? null,
      },
    };
  };

  isMessageFromPendingConversation = (message = {}) => {
    const { conversation_id: conversationId } = message || {};
    if (!conversationId) return false;

    const { PENDING } = wootConstants.STATUS_TYPE;
    const thread = this.getCommunicationThread(message);
    const channel = (thread?.channels || []).find(
      item => String(item.conversation_id) === String(conversationId)
    );
    if (channel?.status) return channel.status === PENDING;

    // A conversation created after the thread was loaded has no status in the
    // thread yet (its channel is built from the message), but conversation.created
    // has stored the conversation record itself. A thread can share its numeric id
    // with an unrelated conversation, so only a real conversation is looked up.
    const conversation = this.store.getters.getConversationById(
      conversationId,
      'conversation'
    );
    if (conversation?.status) return conversation.status === PENDING;

    return thread?.status === PENDING;
  };

  isMessageFromCurrentConversation = message => {
    const selectedChat = this.store.getters.getSelectedChat;
    if (!selectedChat) return false;

    // The open thread is never equal to the conversation id of its message.
    if (isCommunicationThread(selectedChat)) {
      return isMessageInCommunicationThread(selectedChat, message);
    }
    return selectedChat.id === message.conversation_id;
  };

  hasConversationPermission = user => {
    const currentAccountId = this.store.getters.getCurrentAccountId;
    // Get the user permissions for the current account
    const userPermissions = getUserPermissions(user, currentAccountId);
    // Check if the user has the required permissions
    const hasRequiredPermission = CONVERSATION_ACCESS_PERMISSIONS.some(
      permission => userPermissions.includes(permission)
    );
    return hasRequiredPermission;
  };
}

export default AudioNotificationStore;
