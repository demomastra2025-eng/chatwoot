import types from '../../../mutation-types';
import PersonDialogApi from '../../../../api/personDialog';
import { MESSAGE_STATUS } from 'shared/constants/messages';
import {
  buildCommunicationThreadConversation,
  personDialogChatId,
} from 'dashboard/helper/communicationThreadHelper';

// The dialog of a person who has none yet lives only here, in the screen. Opening it, browsing it and leaving it store nothing on
// the server; the first message, call or note makes the dialog, and the draft turns into the real thread in one step.
let openPersonDialogRequestId = 0;

const sameDraft = (state, contactId) =>
  Boolean(state.personDialog) &&
  String(state.personDialog.contactId) === String(contactId);

const withoutDuplicates = messages => {
  const seen = new Set();
  return messages.filter(message => {
    if (!message || seen.has(String(message.id))) return false;
    seen.add(String(message.id));
    return true;
  });
};

// The key of the bubble a message of the server was made from (a message that is read back carries it in its attributes).
const echoIdOf = message =>
  message?.echo_id || message?.additional_attributes?.echo_id;

// The bubbles of the draft that are still on their way (or failed) when it becomes the dialog: they stay on the screen as they
// were, and the answer of the server replaces each one by its echo_id. A bubble whose message the server already made, and that
// is among the loaded messages, is that message: it does not stay as a second copy.
const bubblesStillOpen = (draft, loadedMessages = []) => {
  const loadedEchoIds = new Set(
    loadedMessages.map(echoIdOf).filter(Boolean).map(String)
  );
  return (draft.messages || []).filter(
    bubble =>
      bubble.status !== MESSAGE_STATUS.SENT &&
      !loadedEchoIds.has(String(bubble.echo_id))
  );
};

// A thread payload of the server (the answer of a first message, or of reading the thread) as the chat the screen shows.
const buildPromotedThread = ({ thread, message, draft }) => {
  const loaded = [...(thread.messages || []), message].filter(Boolean);
  return buildCommunicationThreadConversation({
    ...thread,
    id: thread.communication_thread_id || thread.id,
    messages: withoutDuplicates([
      ...loaded,
      ...bubblesStillOpen(draft, loaded),
    ]),
  });
};

const personDialogActions = {
  // Opens the dialog of a person. Resolves { communicationThreadId } when the person already has a dialog (the caller opens it)
  // and { communicationThreadId: null } when a draft was opened. A newer call makes an older answer stale.
  openPersonDialog: async ({ commit, state }, { contactId } = {}) => {
    if (!contactId) return null;

    openPersonDialogRequestId += 1;
    const requestId = openPersonDialogRequestId;
    const { data } = await PersonDialogApi.show(contactId);
    if (requestId !== openPersonDialogRequestId) return null;

    if (data.communication_thread_id) {
      return { communicationThreadId: data.communication_thread_id };
    }

    commit(types.SET_PERSON_DIALOG, {
      contactId: Number(contactId),
      contact: data.contact,
      channels: data.channels || [],
      sharedPhoneHolder: data.shared_phone_holder || null,
      blocked: Boolean(data.blocked),
      // A draft that is opened again keeps the bubbles that failed to send.
      messages: sameDraft(state, contactId) ? state.personDialog.messages : [],
    });
    commit(`contacts/${types.SET_CONTACT_ITEM}`, data.contact);
    return { communicationThreadId: null };
  },

  // The draft becomes the real dialog: the thread joins the store, is selected, and the draft goes, all in one step so the screen
  // never shows an empty moment. With { thread, message } (the answer of the first message) the thread is complete; with
  // { communicationThreadId } (a call, a colleague who wrote first, the person who wrote) it is read first.
  promotePersonDialog: async (
    { commit, dispatch, state },
    { contactId, thread, message, communicationThreadId } = {}
  ) => {
    if (!state.personDialog) return null;
    const draftContactId = state.personDialog.contactId;
    if (contactId && String(contactId) !== String(draftContactId)) return null;

    let promotedThread = null;
    if (thread) {
      promotedThread = buildPromotedThread({
        thread,
        message,
        draft: state.personDialog,
      });
    } else if (communicationThreadId) {
      const read = await dispatch('getCommunicationThread', {
        conversationId: communicationThreadId,
      });
      // The screen may have moved on while the thread was read; the bubbles are those of the draft as it is now.
      if (!read || !sameDraft(state, draftContactId)) return null;

      promotedThread = {
        ...read,
        messages: withoutDuplicates([
          ...(read.messages || []),
          ...bubblesStillOpen(state.personDialog, read.messages || []),
        ]),
      };
    }
    if (!promotedThread || !sameDraft(state, draftContactId)) return null;

    commit(types.SET_ALL_CONVERSATION, [promotedThread]);
    commit(types.SET_CURRENT_CHAT_WINDOW, promotedThread);
    commit(types.CLEAR_PERSON_DIALOG);
    commit(`contacts/${types.SET_CONTACT_ITEM}`, promotedThread.meta?.sender);
    // Loads the history of the other channels: it merges into the messages by id and keeps the ones already on the screen.
    await dispatch('setActiveChat', { data: promotedThread });
    return promotedThread;
  },

  // Sends the first message (or note) of a draft. The bubble stays in the draft while it is pending and when it failed; a retry has
  // the same echo_id, so the server answers it with the message it already made.
  sendPersonDialogMessage: async ({ commit, dispatch }, pendingMessage) => {
    const contactId = pendingMessage.person_contact_id;
    commit(types.UPSERT_PERSON_DIALOG_MESSAGE, {
      ...pendingMessage,
      status: MESSAGE_STATUS.PROGRESS,
    });

    try {
      const { data } = await PersonDialogApi.createMessage(
        contactId,
        pendingMessage
      );
      // The answer to a retry may not carry the echo_id, but it answers this bubble.
      const sentMessage = {
        ...data,
        echo_id: data.echo_id || pendingMessage.echo_id,
        status: MESSAGE_STATUS.SENT,
      };
      const promoted = await dispatch('promotePersonDialog', {
        contactId,
        thread: data.communication_thread,
        message: sentMessage,
      });
      // An earlier message of the same send (a text and its attachments go as several) already made the dialog: this one joins it.
      if (!promoted && data.communication_thread_id) {
        commit(types.ADD_MESSAGE_TO_CHAT, {
          chatId: data.communication_thread_id,
          message: sentMessage,
        });
      }
      return data;
    } catch (error) {
      commit(types.UPSERT_PERSON_DIALOG_MESSAGE, {
        ...pendingMessage,
        meta: { error: error.response?.data?.error },
        status: MESSAGE_STATUS.FAILED,
      });
      throw error;
    }
  },

  clearPersonDialog({ commit }) {
    commit(types.CLEAR_PERSON_DIALOG);
  },
};

export { personDialogChatId };
export default personDialogActions;
