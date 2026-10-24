import { FEATURE_FLAGS } from '../../../featureFlags';
import ConversationApi from '../../../api/inbox/conversation';
import store from '../../../store';

const isCommunicationThreadsEnabled = accountId => {
  try {
    return Boolean(
      store.getters['accounts/isFeatureEnabledonAccount'](
        accountId,
        FEATURE_FLAGS.COMMUNICATION_THREADS
      )
    );
  } catch (error) {
    return false;
  }
};

// A link to one channel conversation (push, email, bot, Slack, old bookmarks) opens the person's
// dialog when the account uses communication threads and the conversation belongs to a thread.
// On any miss the plain conversation view opens as before.
export const redirectToCommunicationThread = async (to, _from, next) => {
  const { accountId, conversation_id: conversationId } = to.params;

  if (conversationId && isCommunicationThreadsEnabled(accountId)) {
    try {
      const { data } = await ConversationApi.show(conversationId);
      const threadId = data?.meta?.communication_thread_id;
      if (threadId) {
        next({
          name: 'communication_thread_conversation',
          params: { accountId, communication_thread_id: threadId },
          query: to.query,
          hash: to.hash,
          replace: true,
        });
        return;
      }
    } catch (error) {
      // The conversation view reports an unreachable conversation itself.
    }
  }

  next();
};

export default redirectToCommunicationThread;
