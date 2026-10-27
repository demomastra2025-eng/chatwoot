import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import PersonDialogApi from '../../../../api/personDialog';
import CommunicationThreadApi from '../../../../api/inbox/communicationThread';
import MessageApi from '../../../../api/inbox/message';
import types from '../../../mutation-types';
import actions from '../actions';
import getters from '../getters';
import { mutations } from '../index';
import { isDraftDialog } from 'dashboard/helper/communicationThreadHelper';

const WHATSAPP_CHANNEL = {
  conversation_id: null,
  inbox_id: 12,
  channel: 'Channel::Whatsapp',
  channel_key: 'inbox:12',
  requires_template: true,
  can_send_text: false,
  can_reply: false,
};

const DRAFT_RESPONSE = {
  communication_thread_id: null,
  contact: { id: 5, name: 'Aigul', phone_number: '+77011234567' },
  channels: [WHATSAPP_CHANNEL],
  shared_phone_holder: null,
  blocked: false,
};

// A tiny store: the real mutations and actions on one state, so a flow can be followed from one step to the next.
const buildStore = (initial = {}) => {
  const state = {
    allConversations: [],
    selectedChatId: null,
    selectedChatType: null,
    personDialog: null,
    conversationFilters: {},
    deletionOperations: [],
    ...initial,
  };
  const context = {
    state,
    rootState: {},
    rootGetters: { getCurrentUser: { id: 1 } },
  };
  context.commit = vi.fn((type, payload) => {
    mutations[type]?.(state, payload);
  });
  // actions of other modules (contacts/…) are not part of this flow
  context.dispatch = vi.fn((name, payload) =>
    actions[name]?.(context, payload)
  );
  return context;
};

const SENT_THREAD = {
  id: 77,
  contact_id: 5,
  is_communication_thread: true,
  meta: { sender: { id: 5, name: 'Aigul' } },
  channels: [
    {
      conversation_id: 301,
      inbox_id: 12,
      channel: 'Channel::Whatsapp',
      channel_key: 'conversation:301',
      can_reply: true,
      can_send_text: false,
      requires_template: true,
    },
  ],
  messages: [],
};

describe('the dialog of a person who has none yet', () => {
  beforeEach(() => {
    vi.spyOn(PersonDialogApi, 'show');
    vi.spyOn(PersonDialogApi, 'createMessage');
    vi.spyOn(CommunicationThreadApi, 'show');
    vi.spyOn(CommunicationThreadApi, 'messages').mockResolvedValue({
      data: { meta: {}, payload: [] },
    });
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('#openPersonDialog', () => {
    it('opens a draft for a person without a dialog and stores nothing in the lists', async () => {
      PersonDialogApi.show.mockResolvedValue({ data: DRAFT_RESPONSE });
      const store = buildStore();

      const result = await actions.openPersonDialog(store, { contactId: 5 });

      expect(result).toEqual({ communicationThreadId: null });
      expect(PersonDialogApi.show).toHaveBeenCalledWith(5);
      expect(store.state.personDialog).toMatchObject({
        contactId: 5,
        contact: DRAFT_RESPONSE.contact,
        messages: [],
      });
      expect(store.state.selectedChatId).toBe('draft-5');
      expect(store.state.selectedChatType).toBe('person_dialog');
      expect(store.state.allConversations).toEqual([]);
      const chat = getters.getSelectedChat(store.state);
      expect(isDraftDialog(chat)).toBe(true);
      expect(getters.getAllConversations(store.state)).toEqual([]);
    });

    it('answers with the thread of a person who has a dialog and opens no draft', async () => {
      PersonDialogApi.show.mockResolvedValue({
        data: { communication_thread_id: 77 },
      });
      const store = buildStore();

      const result = await actions.openPersonDialog(store, { contactId: 5 });

      expect(result).toEqual({ communicationThreadId: 77 });
      expect(store.state.personDialog).toBeNull();
      expect(store.state.selectedChatId).toBeNull();
    });

    it('drops the answer that a newer opening has made stale', async () => {
      let answerFirst;
      PersonDialogApi.show
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              answerFirst = resolve;
            })
        )
        .mockResolvedValueOnce({
          data: {
            ...DRAFT_RESPONSE,
            contact: { id: 6, name: 'Other' },
          },
        });
      const store = buildStore();

      const first = actions.openPersonDialog(store, { contactId: 5 });
      await actions.openPersonDialog(store, { contactId: 6 });
      answerFirst({ data: DRAFT_RESPONSE });
      const firstResult = await first;

      expect(firstResult).toBeNull();
      expect(store.state.personDialog.contactId).toBe(6);
    });

    it('keeps the bubbles that failed when the same draft is opened again', async () => {
      PersonDialogApi.show.mockResolvedValue({ data: DRAFT_RESPONSE });
      const store = buildStore();
      await actions.openPersonDialog(store, { contactId: 5 });
      mutations[types.UPSERT_PERSON_DIALOG_MESSAGE](store.state, {
        id: 'tmp-1',
        echo_id: 'tmp-1',
        status: 'failed',
      });

      await actions.openPersonDialog(store, { contactId: 5 });

      expect(store.state.personDialog.messages).toHaveLength(1);
    });
  });

  describe('sending the first message', () => {
    const pendingMessage = {
      id: 'echo-1',
      echo_id: 'echo-1',
      message: 'Hello',
      content: 'Hello',
      person_contact_id: 5,
      channelKey: 'inbox:12',
      templateParams: { name: 'hello' },
    };

    const openDraft = async () => {
      PersonDialogApi.show.mockResolvedValue({ data: DRAFT_RESPONSE });
      const store = buildStore();
      await actions.openPersonDialog(store, { contactId: 5 });
      return store;
    };

    it('goes to the person endpoint, never to a conversation or a thread', async () => {
      const conversationCreate = vi.spyOn(MessageApi, 'create');
      const threadCreate = vi.spyOn(CommunicationThreadApi, 'createMessage');
      PersonDialogApi.createMessage.mockResolvedValue({
        data: {
          id: 900,
          content: 'Hello',
          conversation_id: 301,
          communication_thread_id: 77,
          communication_thread: SENT_THREAD,
        },
      });
      CommunicationThreadApi.show.mockResolvedValue({ data: SENT_THREAD });
      const store = await openDraft();

      await actions.sendMessageWithData(store, pendingMessage);

      expect(PersonDialogApi.createMessage).toHaveBeenCalledWith(
        5,
        pendingMessage
      );
      expect(conversationCreate).not.toHaveBeenCalled();
      expect(threadCreate).not.toHaveBeenCalled();
    });

    it('turns the draft into the thread in one step and keeps the sent message', async () => {
      PersonDialogApi.createMessage.mockResolvedValue({
        data: {
          id: 900,
          content: 'Hello',
          message_type: 1,
          conversation_id: 301,
          communication_thread_id: 77,
          communication_thread: SENT_THREAD,
        },
      });
      const store = await openDraft();

      await actions.sendMessageWithData(store, pendingMessage);

      expect(store.state.personDialog).toBeNull();
      expect(store.state.selectedChatId).toBe(77);
      expect(store.state.selectedChatType).toBe('communication_thread');
      const thread = store.state.allConversations.find(chat => chat.id === 77);
      expect(thread.messages.map(message => message.id)).toEqual([900]);
      expect(thread.messages[0].status).toBe('sent');
      // the history of the other channels is read next and merges by id
      expect(store.dispatch).toHaveBeenCalledWith(
        'setActiveChat',
        expect.objectContaining({
          data: expect.objectContaining({ id: 77 }),
        })
      );
    });

    it('marks the bubble failed in the draft and lets a retry send the same echo_id', async () => {
      PersonDialogApi.createMessage
        .mockRejectedValueOnce({
          response: { data: { error: 'no', code: 'channel_unavailable' } },
        })
        .mockResolvedValueOnce({
          data: {
            id: 900,
            conversation_id: 301,
            communication_thread: SENT_THREAD,
          },
        });
      const store = await openDraft();

      await expect(
        actions.sendMessageWithData(store, pendingMessage)
      ).rejects.toBeTruthy();

      const [failed] = store.state.personDialog.messages;
      expect(failed).toMatchObject({ echo_id: 'echo-1', status: 'failed' });
      expect(store.state.allConversations).toEqual([]);

      await actions.sendMessageWithData(store, failed);

      const secondBody = PersonDialogApi.createMessage.mock.calls[1][1];
      expect(secondBody.echo_id).toBe('echo-1');
      expect(store.state.personDialog).toBeNull();
    });
  });

  describe('several messages sent together (a text and its attachments)', () => {
    const open = async () => {
      PersonDialogApi.show.mockResolvedValue({ data: DRAFT_RESPONSE });
      const store = buildStore();
      await actions.openPersonDialog(store, { contactId: 5 });
      return store;
    };
    const answerOf = (id, echoId) => ({
      data: {
        id,
        echo_id: echoId,
        content: `m${id}`,
        conversation_id: 301,
        communication_thread_id: 77,
        communication_thread: SENT_THREAD,
      },
    });

    it('keeps the bubble that is still on its way when the first answer makes the dialog, and replaces it by its own answer', async () => {
      let answerSecond;
      PersonDialogApi.createMessage
        .mockResolvedValueOnce(answerOf(900, 'echo-1'))
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              answerSecond = resolve;
            })
        );
      const store = await open();

      const first = actions.sendMessageWithData(store, {
        id: 'echo-1',
        echo_id: 'echo-1',
        person_contact_id: 5,
      });
      const second = actions.sendMessageWithData(store, {
        id: 'echo-2',
        echo_id: 'echo-2',
        person_contact_id: 5,
      });
      await first;

      // the dialog exists; the second bubble is still shown, pending
      const during = store.state.allConversations.find(chat => chat.id === 77);
      expect(during.messages.map(message => message.id)).toEqual([
        900,
        'echo-2',
      ]);

      answerSecond(answerOf(901, 'echo-2'));
      await second;

      const after = store.state.allConversations.find(chat => chat.id === 77);
      expect(after.messages.map(message => message.id)).toEqual([900, 901]);
      expect(after.messages.every(message => message.status === 'sent')).toBe(
        true
      );
    });
  });

  describe('#promotePersonDialog', () => {
    const openDraft = async () => {
      PersonDialogApi.show.mockResolvedValue({ data: DRAFT_RESPONSE });
      const store = buildStore();
      await actions.openPersonDialog(store, { contactId: 5 });
      return store;
    };

    it('reads the thread of a call and selects it', async () => {
      CommunicationThreadApi.show.mockResolvedValue({ data: SENT_THREAD });
      const store = await openDraft();

      await actions.promotePersonDialog(store, {
        contactId: 5,
        communicationThreadId: 77,
      });

      expect(CommunicationThreadApi.show).toHaveBeenCalledWith(77);
      expect(store.state.personDialog).toBeNull();
      expect(store.state.selectedChatId).toBe(77);
    });

    it('does nothing for a draft of another person or when there is no draft', async () => {
      CommunicationThreadApi.show.mockResolvedValue({ data: SENT_THREAD });
      const store = await openDraft();

      expect(
        await actions.promotePersonDialog(store, {
          contactId: 99,
          communicationThreadId: 77,
        })
      ).toBeNull();
      expect(store.state.personDialog.contactId).toBe(5);

      const empty = buildStore();
      expect(
        await actions.promotePersonDialog(empty, { communicationThreadId: 77 })
      ).toBeNull();
    });

    it('does not take over when the screen moved to another person while the thread was read', async () => {
      let answer;
      CommunicationThreadApi.show.mockImplementation(
        () =>
          new Promise(resolve => {
            answer = resolve;
          })
      );
      const store = await openDraft();

      const promotion = actions.promotePersonDialog(store, {
        contactId: 5,
        communicationThreadId: 77,
      });
      mutations[types.CLEAR_PERSON_DIALOG](store.state);
      answer({ data: SENT_THREAD });

      expect(await promotion).toBeNull();
      expect(store.state.selectedChatId).toBeNull();
    });
  });

  describe('the realtime event of a thread', () => {
    it('promotes the open draft of the same person (the person wrote, or a colleague wrote first)', async () => {
      PersonDialogApi.show.mockResolvedValue({ data: DRAFT_RESPONSE });
      const store = buildStore();
      await actions.openPersonDialog(store, { contactId: 5 });

      await actions.updateCommunicationThreadRealtime(store, {
        id: 77,
        communication_thread_id: 77,
        contact_id: 5,
        is_communication_thread: true,
        meta: { sender: { id: 5, name: 'Aigul' } },
        channels: SENT_THREAD.channels,
        source_event: 'message.created',
        updated_at: 1710000001.25,
      });

      expect(store.dispatch).toHaveBeenCalledWith('promotePersonDialog', {
        contactId: 5,
        communicationThreadId: 77,
      });
    });

    it('leaves a draft of another person alone', async () => {
      PersonDialogApi.show.mockResolvedValue({ data: DRAFT_RESPONSE });
      const store = buildStore();
      await actions.openPersonDialog(store, { contactId: 5 });

      await actions.updateCommunicationThreadRealtime(store, {
        id: 88,
        communication_thread_id: 88,
        contact_id: 6,
        is_communication_thread: true,
        meta: { sender: { id: 6 } },
        channels: [],
        updated_at: 1710000001.25,
      });

      expect(store.dispatch).not.toHaveBeenCalledWith(
        'promotePersonDialog',
        expect.anything()
      );
    });
  });

  describe('mutations', () => {
    it('CLEAR_CURRENT_CHAT_WINDOW clears the draft with the selection', () => {
      const state = {
        selectedChatId: 'draft-5',
        selectedChatType: 'person_dialog',
        personDialog: { contactId: 5, messages: [] },
      };

      mutations[types.CLEAR_CURRENT_CHAT_WINDOW](state);

      expect(state.personDialog).toBeNull();
      expect(state.selectedChatId).toBeNull();
    });

    it('CLEAR_PERSON_DIALOG keeps a selection that already moved to a thread', () => {
      const state = {
        selectedChatId: 77,
        selectedChatType: 'communication_thread',
        personDialog: { contactId: 5, messages: [] },
      };

      mutations[types.CLEAR_PERSON_DIALOG](state);

      expect(state.personDialog).toBeNull();
      expect(state.selectedChatId).toBe(77);
    });

    it('UPSERT_PERSON_DIALOG_MESSAGE replaces the bubble of the same echo_id', () => {
      const state = {
        personDialog: { contactId: 5, messages: [] },
      };

      mutations[types.UPSERT_PERSON_DIALOG_MESSAGE](state, {
        id: 'a',
        echo_id: 'a',
        status: 'progress',
      });
      mutations[types.UPSERT_PERSON_DIALOG_MESSAGE](state, {
        id: 'a',
        echo_id: 'a',
        status: 'failed',
      });

      expect(state.personDialog.messages).toEqual([
        { id: 'a', echo_id: 'a', status: 'failed' },
      ]);
    });
  });
});
