import axios from 'axios';
import MessageApi from 'dashboard/api/inbox/message';
import CommunicationThreadApi from 'dashboard/api/inbox/communicationThread';
import actions, {
  hasMessageFailedWithExternalError,
} from '../../conversations/actions';
import types from '../../../mutation-types';
const dataToSend = {
  payload: [
    {
      attribute_key: 'status',
      filter_operator: 'equal_to',
      values: ['open'],
      query_operator: null,
    },
  ],
};
import { dataReceived } from './testConversationResponse';

const commit = vi.fn();
const dispatch = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#hasMessageFailedWithExternalError', () => {
  it('returns false if message is sent', () => {
    const pendingMessage = {
      status: 'sent',
      content_attributes: {},
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(false);
  });
  it('returns false if status is not failed', () => {
    const pendingMessage = {
      status: 'progress',
      content_attributes: {},
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(false);
  });

  it('returns false if status is failed but no external error', () => {
    const pendingMessage = {
      status: 'failed',
      content_attributes: {},
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(false);
  });

  it('returns true if status is failed and has external error', () => {
    const pendingMessage = {
      status: 'failed',
      content_attributes: {
        external_error: 'error',
      },
    };
    expect(hasMessageFailedWithExternalError(pendingMessage)).toBe(true);
  });
});

describe('#actions', () => {
  describe('#getConversation', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({
        data: { id: 1, meta: { sender: { id: 1, name: 'Contact 1' } } },
      });
      await actions.getConversation(
        { commit, state: { allConversations: [{ id: 1 }] } },
        1
      );
      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_CONVERSATION,
          { id: 1, meta: { sender: { id: 1, name: 'Contact 1' } } },
        ],
        ['contacts/SET_CONTACT_ITEM', { id: 1, name: 'Contact 1' }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.getConversation({ commit });
      expect(commit.mock.calls).toEqual([]);
    });
  });
  describe('#muteConversation', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue(null);
      await actions.muteConversation({ commit }, 1);
      expect(commit.mock.calls).toEqual([[types.MUTE_CONVERSATION]]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.getConversation({ commit });
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#updateConversation', () => {
    it('setContact action and update_conversation mutation', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        labels: ['support'],
      };
      actions.updateConversation(
        { commit, rootState: { route: { name: 'home' } }, dispatch },
        conversation
      );
      expect(commit.mock.calls).toEqual([
        [types.UPDATE_CONVERSATION, conversation],
      ]);
      expect(dispatch.mock.calls).toEqual([
        [
          'conversationLabels/setConversationLabel',
          { id: 1, data: ['support'] },
        ],
        [
          'contacts/setContact',
          {
            id: 1,
            name: 'john-doe',
          },
        ],
      ]);
    });
  });

  describe('#updateCommunicationThreadRealtime', () => {
    it('commits partial thread realtime payload without fabricating empty meta/channels', () => {
      const payload = {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        conversation_ids: [11, 22],
        unread_count: 3,
        timestamp: 1710000000,
        updated_at: 1710000000.25,
      };

      actions.updateCommunicationThreadRealtime({ commit }, payload);

      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_CONVERSATION,
          {
            ...payload,
            display_id: 7,
          },
        ],
      ]);
    });

    it('keeps the thread label side panel in sync from realtime patches', () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      const payload = {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        labels: ['support'],
        updated_at: 1710000000.25,
      };

      actions.updateCommunicationThreadRealtime(
        { commit: localCommit, dispatch: localDispatch },
        payload
      );

      expect(localCommit).toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.objectContaining({ id: 7, labels: ['support'] })
      );
      expect(localDispatch).toHaveBeenCalledWith(
        'conversationLabels/setConversationLabel',
        { id: 7, data: ['support'] }
      );
    });

    it('stores the latest thread sender from contact-change realtime patches', () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      const sender = { id: 42, name: 'Updated customer' };
      const payload = {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        meta: { sender, channel: 'CommunicationThread' },
        updated_at: 1710000000.25,
      };

      actions.updateCommunicationThreadRealtime(
        { commit: localCommit, dispatch: localDispatch },
        payload
      );

      expect(localCommit).toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.objectContaining({
          id: 7,
          meta: expect.objectContaining(payload.meta),
        })
      );
      expect(localDispatch).toHaveBeenCalledWith('contacts/setContact', sender);
    });

    it('refreshes the thread list after contact-change patches so stale old groups are removed', () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      const payload = {
        id: 8,
        communication_thread_id: 8,
        is_communication_thread: true,
        source_event: 'conversation.contact_changed',
        meta: { sender: { id: 51, name: 'New contact' } },
        updated_at: 1710000000.25,
      };

      actions.updateCommunicationThreadRealtime(
        { commit: localCommit, dispatch: localDispatch },
        payload
      );

      expect(localDispatch).toHaveBeenCalledWith('fetchCommunicationThreads');
    });
  });

  describe('#addConversation', () => {
    it('doesnot send mutation if conversation is from a different inbox', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 2,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('doesnot send mutation if conversation filters are applied', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [{ id: 'random-filter' }] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('doesnot send mutation if the view is conversation mentions', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'conversation_mentions' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [{ id: 'random-filter' }] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('doesnot send mutation if the view is conversation folders', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'folder_conversations' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [{ id: 'random-filter' }] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });

    it('sends correct mutations', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { currentInbox: 1, appliedFilters: [] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([
        [types.ADD_CONVERSATION, conversation],
      ]);
      expect(dispatch.mock.calls).toEqual([
        [
          'contacts/setContact',
          {
            id: 1,
            name: 'john-doe',
          },
        ],
      ]);
    });

    it('sends correct mutations if inbox filter is not available', () => {
      const conversation = {
        id: 1,
        messages: [],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      };
      actions.addConversation(
        {
          commit,
          rootState: { route: { name: 'home' } },
          dispatch,
          state: { appliedFilters: [] },
        },
        conversation
      );
      expect(commit.mock.calls).toEqual([
        [types.ADD_CONVERSATION, conversation],
      ]);
      expect(dispatch.mock.calls).toEqual([
        [
          'contacts/setContact',
          {
            id: 1,
            name: 'john-doe',
          },
        ],
      ]);
    });
  });

  describe('#addMessage', () => {
    it('sends correct mutations if message is incoming', () => {
      const message = {
        id: 1,
        message_type: 0,
        conversation_id: 1,
      };
      actions.addMessage({ commit }, message);
      expect(commit.mock.calls).toEqual([
        [types.ADD_MESSAGE, message],
        [
          types.SET_CONVERSATION_CAN_REPLY,
          { conversationId: 1, canReply: true },
        ],
        [types.ADD_CONVERSATION_ATTACHMENTS, message],
      ]);
    });
    it('sends correct mutations if message is not an incoming message', () => {
      const message = {
        id: 1,
        message_type: 1,
        conversation_id: 1,
      };
      actions.addMessage({ commit }, message);
      expect(commit.mock.calls).toEqual([[types.ADD_MESSAGE, message]]);
    });

    it('updates the attachment panel for outgoing realtime messages with attachments', () => {
      const localCommit = vi.fn();
      const message = {
        id: 1,
        message_type: 1,
        conversation_id: 1,
        status: 'sent',
        attachments: [{ id: 10 }],
      };

      actions.addMessage({ commit: localCommit }, message);

      expect(localCommit.mock.calls).toEqual([
        [types.ADD_MESSAGE, message],
        [types.ADD_CONVERSATION_ATTACHMENTS, message],
      ]);
    });
  });

  describe('#fetchSidebarUnreadCounts', () => {
    it('commits sidebar unread counts from the API', async () => {
      const localCommit = vi.fn();
      const counts = { all: 2, statuses: { open: 2 } };
      axios.get.mockResolvedValue({ data: { counts } });

      await actions.fetchSidebarUnreadCounts({ commit: localCommit });

      expect(localCommit).toHaveBeenCalledWith(
        types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS,
        counts
      );
    });

    it('commits filtered sidebar unread counts from conversation meta', async () => {
      const localCommit = vi.fn();
      const counts = {
        all: 3,
        statuses: { open: 2, pending: 1 },
        inboxes: { 1: 2 },
      };
      axios.get.mockResolvedValue({
        data: { meta: { unread_counts: counts } },
      });

      await actions.fetchSidebarUnreadCounts({
        commit: localCommit,
        state: {
          conversationFilters: {
            status: 'open',
            assigneeType: 'me',
            inboxId: 1,
          },
        },
      });

      expect(localCommit).toHaveBeenCalledWith(
        types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS,
        counts
      );
    });

    it('uses communication thread meta for filtered thread unread counts', async () => {
      const localCommit = vi.fn();
      const counts = { all: 2, inboxes: { 1: 2 } };
      const metaSpy = vi
        .spyOn(CommunicationThreadApi, 'meta')
        .mockResolvedValue({ data: { meta: { unread_counts: counts } } });

      await actions.fetchSidebarUnreadCounts({
        commit: localCommit,
        state: {
          conversationFilters: {
            status: 'open',
            assigneeType: 'me',
            communicationThreadMode: true,
          },
        },
      });

      expect(metaSpy).toHaveBeenCalledWith({
        status: 'open',
        assigneeType: 'me',
        communicationThreadMode: true,
      });
      expect(localCommit).toHaveBeenCalledWith(
        types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS,
        counts
      );

      metaSpy.mockRestore();
    });

    it('ignores stale sidebar unread count responses', async () => {
      const localCommit = vi.fn();
      let resolveFirst;
      let resolveSecond;
      axios.get
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              resolveFirst = resolve;
            })
        )
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              resolveSecond = resolve;
            })
        );

      const firstRequest = actions.fetchSidebarUnreadCounts({
        commit: localCommit,
      });
      const secondRequest = actions.fetchSidebarUnreadCounts({
        commit: localCommit,
      });

      resolveSecond({ data: { counts: { all: 3 } } });
      await secondRequest;
      expect(localCommit).toHaveBeenCalledWith(
        types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS,
        { all: 3 }
      );

      resolveFirst({ data: { counts: { all: 1 } } });
      await firstRequest;
      expect(localCommit).toHaveBeenCalledTimes(1);
    });
  });

  describe('#markMessagesRead', () => {
    it('sends correct mutations if api is successful', async () => {
      const lastSeen = new Date().getTime() / 1000;
      axios.post.mockResolvedValue({
        data: { id: 1, agent_last_seen_at: lastSeen },
      });
      const refreshDispatch = vi.fn();
      await actions.markMessagesRead(
        { commit, dispatch: refreshDispatch },
        { id: 1 }
      );
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_MESSAGE_UNREAD_COUNT,
          { id: 1, lastSeen, unreadCount: 0 },
        ],
      ]);
      expect(refreshDispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    });
    it('sends correct mutations if api is unsuccessful', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await actions.markMessagesRead({ commit }, { id: 1 });
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#markCommunicationThreadRead', () => {
    it('updates the thread payload and unread count if API is successful', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      axios.post.mockResolvedValue({
        data: {
          id: 7,
          agent_last_seen_at: 123,
          unread_count: 0,
          channels: [{ conversation_id: 11, agent_last_seen_at: 123 }],
          messages: [],
          meta: { sender: { id: 1 } },
        },
      });

      await actions.markCommunicationThreadRead(
        { commit: localCommit, dispatch: localDispatch },
        { id: 7 }
      );

      expect(localCommit).toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.objectContaining({
          id: 7,
          is_communication_thread: true,
          agent_last_seen_at: 123,
          unread_count: 0,
          channels: [
            expect.objectContaining({
              conversation_id: 11,
              agent_last_seen_at: 123,
            }),
          ],
        })
      );
      expect(localCommit).toHaveBeenCalledWith(
        types.UPDATE_MESSAGE_UNREAD_COUNT,
        {
          id: 7,
          lastSeen: 123,
          unreadCount: 0,
          conversationType: 'communication_thread',
        }
      );
      expect(localDispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    });
  });

  describe('#markMessagesUnread', () => {
    it('sends correct mutations if API is successful', async () => {
      const lastSeen = new Date().getTime() / 1000;
      axios.post.mockResolvedValue({
        data: { id: 1, agent_last_seen_at: lastSeen, unread_count: 1 },
      });
      const refreshDispatch = vi.fn();
      await actions.markMessagesUnread(
        { commit, dispatch: refreshDispatch },
        { id: 1 }
      );
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_MESSAGE_UNREAD_COUNT,
          { id: 1, lastSeen, unreadCount: 1 },
        ],
      ]);
      expect(refreshDispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    });
    it('sends correct mutations if API is unsuccessful', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.markMessagesUnread({ commit }, { id: 1 })
      ).rejects.toThrow(Error);
    });
  });

  describe('#sendEmailTranscript', () => {
    it('sends correct mutations if api is successful', async () => {
      axios.post.mockResolvedValue({});
      await actions.sendEmailTranscript(
        { commit },
        { conversationId: 1, email: 'testemail@example.com' }
      );
      expect(commit).toHaveBeenCalledTimes(0);
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#assignAgent', () => {
    it('sends correct mutations if assignment is successful', async () => {
      axios.post.mockResolvedValue({
        data: { id: 1, name: 'User' },
      });
      await actions.assignAgent(
        { dispatch },
        { conversationId: 1, agentId: 1 }
      );
      expect(dispatch).toHaveBeenCalledWith('setCurrentChatAssignee', {
        conversationId: 1,
        assignee: { id: 1, name: 'User' },
      });
    });
  });

  describe('#setCurrentChatAssignee', () => {
    it('sends correct mutations if assignment is successful', async () => {
      const payload = {
        conversationId: 1,
        assignee: { id: 1, name: 'User' },
      };
      await actions.setCurrentChatAssignee({ commit }, payload);
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([['ASSIGN_AGENT', payload]]);
    });
  });

  describe('#toggleStatus', () => {
    it('sends correct mutations if toggle status is successful', async () => {
      axios.post.mockResolvedValue({
        data: {
          payload: {
            conversation_id: 1,
            current_status: 'snoozed',
            snoozed_until: null,
          },
        },
      });
      await actions.toggleStatus(
        { commit },
        { conversationId: 1, status: 'snoozed' }
      );
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        [
          'CHANGE_CONVERSATION_STATUS',
          { conversationId: 1, status: 'snoozed', snoozedUntil: null },
        ],
      ]);
    });

    it('commits server custom attributes before toggling status when provided', async () => {
      axios.post
        .mockResolvedValueOnce({
          data: {
            custom_attributes: {
              existing_key: 'existing value',
              required_key: 'new value',
            },
          },
        })
        .mockResolvedValueOnce({
          data: {
            payload: {
              conversation_id: 1,
              current_status: 'resolved',
              snoozed_until: null,
            },
          },
        });

      await actions.toggleStatus(
        { commit },
        {
          conversationId: 1,
          status: 'resolved',
          customAttributes: { required_key: 'new value' },
        }
      );

      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES,
          {
            conversationId: 1,
            customAttributes: {
              existing_key: 'existing value',
              required_key: 'new value',
            },
          },
        ],
        [
          types.CHANGE_CONVERSATION_STATUS,
          { conversationId: 1, status: 'resolved', snoozedUntil: null },
        ],
      ]);
    });
  });

  describe('#assignTeam', () => {
    it('sends correct mutations if assignment is successful', async () => {
      axios.post.mockResolvedValue({
        data: { id: 1, name: 'Team' },
      });
      await actions.assignTeam({ commit }, { conversationId: 1, teamId: 1 });
      expect(commit).toHaveBeenCalledTimes(0);
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#setCurrentChatTeam', () => {
    it('sends correct mutations if assignment is successful', async () => {
      axios.post.mockResolvedValue({
        data: { id: 1, name: 'Team' },
      });
      await actions.setCurrentChatTeam(
        { commit },
        { team: { id: 1, name: 'Team' }, conversationId: 1 }
      );
      expect(commit).toHaveBeenCalledTimes(1);
      expect(commit.mock.calls).toEqual([
        ['ASSIGN_TEAM', { team: { id: 1, name: 'Team' }, conversationId: 1 }],
      ]);
    });
  });

  describe('#fetchFilteredConversations', () => {
    it('fetches filtered conversations with a mock commit', async () => {
      axios.post.mockResolvedValue({
        data: dataReceived,
      });
      await actions.fetchFilteredConversations({ commit }, dataToSend);
      expect(commit).toHaveBeenCalledTimes(2);
      expect(commit.mock.calls).toEqual([
        ['SET_LIST_LOADING_STATUS'],
        ['SET_ALL_CONVERSATION', dataReceived.payload],
      ]);
    });
  });

  describe('#setConversationFilter', () => {
    it('commits the correct mutation and sets filter state', () => {
      const filters = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: [{ id: 'snoozed', name: 'Snoozed' }],
          query_operator: 'and',
        },
      ];
      actions.setConversationFilters({ commit }, filters);
      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_FILTERS, filters],
      ]);
    });
  });

  describe('#clearConversationFilter', () => {
    it('commits the correct mutation and clears filter state', () => {
      actions.clearConversationFilters({ commit });
      expect(commit.mock.calls).toEqual([[types.CLEAR_CONVERSATION_FILTERS]]);
    });
  });

  describe('#updateConversationLastActivity', () => {
    it('sends correct action', async () => {
      await actions.updateConversationLastActivity(
        { commit },
        { conversationId: 1, lastActivityAt: 12121212 }
      );
      expect(commit.mock.calls).toEqual([
        [
          'UPDATE_CONVERSATION_LAST_ACTIVITY',
          { conversationId: 1, lastActivityAt: 12121212 },
        ],
      ]);
    });
  });

  describe('#setChatSortFilter', () => {
    it('sends correct action', async () => {
      await actions.setChatSortFilter(
        { commit },
        { data: 'sort_on_created_at' }
      );
      expect(commit.mock.calls).toEqual([
        ['CHANGE_CHAT_SORT_FILTER', { data: 'sort_on_created_at' }],
      ]);
    });
  });
});

describe('#deleteMessage', () => {
  it('sends correct actions if API is success', async () => {
    const [conversationId, messageId] = [1, 1];
    axios.delete.mockResolvedValue({
      data: { id: 1, content: 'deleted' },
    });
    await actions.deleteMessage({ commit }, { conversationId, messageId });
    expect(commit.mock.calls).toEqual([
      [types.ADD_MESSAGE, { id: 1, content: 'deleted' }],
      [types.DELETE_CONVERSATION_ATTACHMENTS, { id: 1, content: 'deleted' }],
    ]);
  });
  it('sends no actions if API is error', async () => {
    const [conversationId, messageId] = [1, 1];
    axios.delete.mockRejectedValue({ message: 'Incorrect header' });
    await expect(
      actions.deleteMessage({ commit }, { conversationId, messageId })
    ).rejects.toThrow(Error);
    expect(commit.mock.calls).toEqual([]);
  });

  describe('#deleteConversation', () => {
    it('send correct actions if API is success', async () => {
      axios.delete.mockResolvedValue({
        data: { id: 1 },
      });
      await actions.deleteConversation({ commit, dispatch }, 1);
      expect(commit.mock.calls).toEqual([[types.DELETE_CONVERSATION, 1]]);
      expect(dispatch.mock.calls).toEqual([
        ['conversationStats/get', {}, { root: true }],
      ]);
    });

    it('send no actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.deleteConversation({ commit, dispatch }, 1)
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([]);
      expect(dispatch.mock.calls).toEqual([]);
    });
  });

  describe('#updateCustomAttributes', () => {
    it('update conversation custom attributes', async () => {
      axios.post.mockResolvedValue({
        data: { custom_attributes: { order_d: '1001', existing_key: 'value' } },
      });
      await actions.updateCustomAttributes(
        { commit },
        {
          conversationId: 1,
          customAttributes: { order_d: '1001' },
        }
      );
      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES,
          {
            conversationId: 1,
            customAttributes: { order_d: '1001', existing_key: 'value' },
          },
        ],
      ]);
    });

    it('delete conversation custom attributes', async () => {
      axios.post.mockResolvedValue({
        data: { custom_attributes: { existing_key: 'value' } },
      });
      await actions.deleteCustomAttributes(
        { commit },
        {
          conversationId: 1,
          customAttributes: ['order_d'],
        }
      );
      expect(commit.mock.calls).toEqual([
        [
          types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES,
          {
            conversationId: 1,
            customAttributes: { existing_key: 'value' },
          },
        ],
      ]);
    });
  });

  describe('#sendMessageWithData', () => {
    it('uses the communication thread endpoint when a thread id is present', async () => {
      const localCommit = vi.fn();
      const pendingMessage = {
        id: 'echo-1',
        conversation_id: 12,
        communication_thread_id: 99,
        message: 'Hello from thread',
      };
      const response = {
        data: {
          id: 501,
          conversation_id: 12,
          content: 'Hello from thread',
        },
      };
      const threadCreateSpy = vi
        .spyOn(CommunicationThreadApi, 'createMessage')
        .mockResolvedValue(response);
      const messageCreateSpy = vi
        .spyOn(MessageApi, 'create')
        .mockResolvedValue(response);

      try {
        await actions.sendMessageWithData(
          { commit: localCommit },
          pendingMessage
        );

        expect(threadCreateSpy).toHaveBeenCalledWith(99, pendingMessage);
        expect(messageCreateSpy).not.toHaveBeenCalled();
        expect(localCommit).toHaveBeenCalledWith(types.ADD_MESSAGE_TO_CHAT, {
          chatId: 99,
          message: expect.objectContaining({
            id: 'echo-1',
            status: 'progress',
          }),
        });
      } finally {
        threadCreateSpy.mockRestore();
        messageCreateSpy.mockRestore();
      }
    });
  });
});

describe('#addMentions', () => {
  it('does not send mutations if the view is not mentions', () => {
    actions.addMentions(
      { commit, dispatch, rootState: { route: { name: 'home' } } },
      { id: 1 }
    );
    expect(commit.mock.calls).toEqual([]);
    expect(dispatch.mock.calls).toEqual([]);
  });

  it('send mutations if the view is mentions', () => {
    actions.addMentions(
      {
        dispatch,
        rootState: { route: { name: 'conversation_mentions' } },
      },
      { id: 1, meta: { sender: { id: 1 } } }
    );
    expect(dispatch.mock.calls).toEqual([
      ['updateConversation', { id: 1, meta: { sender: { id: 1 } } }],
    ]);
  });

  it('#syncActiveConversationMessages', async () => {
    const conversations = [
      {
        id: 1,
        messages: [
          {
            id: 1,
            content: 'Hello',
          },
        ],
        meta: { sender: { id: 1, name: 'john-doe' } },
        inbox_id: 1,
      },
    ];
    axios.get.mockResolvedValue({
      data: {
        payload: [{ id: 2, content: 'Welcome' }],
        meta: {
          agent_last_seen_at: '2023-04-20T05:22:42.990Z',
        },
      },
    });
    await actions.syncActiveConversationMessages(
      {
        commit,
        dispatch,
        state: {
          allConversations: conversations,
          syncConversationsMessages: {
            1: 1,
          },
        },
      },
      { conversationId: 1 }
    );
    expect(commit.mock.calls).toEqual([
      [
        'conversationMetadata/SET_CONVERSATION_METADATA',
        {
          id: 1,
          data: {
            agent_last_seen_at: '2023-04-20T05:22:42.990Z',
          },
        },
      ],
      [
        types.SET_PREVIOUS_CONVERSATIONS,
        {
          id: 1,
          data: [{ id: 2, content: 'Welcome' }],
        },
      ],
      [
        'SET_LAST_MESSAGE_ID_FOR_SYNC_CONVERSATION',
        { conversationId: 1, messageId: null },
      ],
    ]);
  });

  describe('#fetchAllAttachments', () => {
    it('fetches all attachments', async () => {
      axios.get.mockResolvedValue({
        data: {
          payload: [
            {
              id: 1,
              message_id: 1,
              file_type: 'image',
              data_url: '',
              thumb_url: '',
            },
          ],
        },
      });
      await actions.fetchAllAttachments({ commit }, 1);
      expect(commit.mock.calls).toEqual([
        [
          types.SET_ALL_ATTACHMENTS,
          {
            id: 1,
            data: [
              {
                id: 1,
                message_id: 1,
                file_type: 'image',
                data_url: '',
                thumb_url: '',
              },
            ],
          },
        ],
      ]);
    });
  });

  describe('#setContextMenuChatId', () => {
    it('sets the context menu chat id', () => {
      actions.setContextMenuChatId({ commit }, 1);
      expect(commit.mock.calls).toEqual([[types.SET_CONTEXT_MENU_CHAT_ID, 1]]);
    });
  });

  describe('#setChatListFilters', () => {
    it('set chat list filters', () => {
      const filters = {
        inboxId: 1,
        assigneeType: 'me',
        status: 'open',
        sortBy: 'created_at',
        page: 1,
        labels: ['label'],
        teamId: 1,
        conversationType: 'mention',
      };
      actions.setChatListFilters({ commit }, filters);
      expect(commit.mock.calls).toEqual([
        [types.SET_CHAT_LIST_FILTERS, filters],
      ]);
    });
  });

  describe('#updateChatListFilters', () => {
    it('update chat list filters', () => {
      actions.updateChatListFilters({ commit }, { updatedWithin: 20 });
      expect(commit.mock.calls).toEqual([
        [types.UPDATE_CHAT_LIST_FILTERS, { updatedWithin: 20 }],
      ]);
    });
  });

  describe('#setActiveChat', () => {
    it('should fetch the latest page without a before cursor on normal open', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn().mockResolvedValue();
      const data = { id: 42, messages: [{ id: 100 }] };

      await actions.setActiveChat(
        { commit: localCommit, dispatch: localDispatch },
        { data }
      );

      expect(localCommit.mock.calls).toEqual([
        [types.SET_CURRENT_CHAT_WINDOW, data],
        [
          types.CLEAR_ALL_MESSAGES_LOADED,
          { id: 42, conversationType: 'conversation' },
        ],
        [
          types.SET_CHAT_DATA_FETCHED,
          { id: 42, conversationType: 'conversation' },
        ],
      ]);
      expect(localDispatch).toHaveBeenCalledWith('fetchPreviousMessages', {
        after: undefined,
        conversationId: 42,
        conversationType: 'conversation',
      });
    });

    it('should include before cursor when opening around a target message', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn().mockResolvedValue();
      const data = { id: 42, messages: [{ id: 100 }] };

      await actions.setActiveChat(
        { commit: localCommit, dispatch: localDispatch },
        { data, after: 99 }
      );

      expect(localCommit.mock.calls).toEqual([
        [types.SET_CURRENT_CHAT_WINDOW, data],
        [
          types.CLEAR_ALL_MESSAGES_LOADED,
          { id: 42, conversationType: 'conversation' },
        ],
        [
          types.SET_CHAT_DATA_FETCHED,
          { id: 42, conversationType: 'conversation' },
        ],
      ]);
      expect(localDispatch).toHaveBeenCalledWith('fetchPreviousMessages', {
        after: 99,
        before: 100,
        conversationId: 42,
        conversationType: 'conversation',
      });
    });

    it('should not dispatch fetchPreviousMessages if dataFetched is already set', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn();
      const data = { id: 42, messages: [{ id: 100 }], dataFetched: true };

      await actions.setActiveChat(
        { commit: localCommit, dispatch: localDispatch },
        { data }
      );

      expect(localCommit.mock.calls).toEqual([
        [types.SET_CURRENT_CHAT_WINDOW, data],
        [
          types.CLEAR_ALL_MESSAGES_LOADED,
          { id: 42, conversationType: 'conversation' },
        ],
      ]);
      expect(localDispatch).not.toHaveBeenCalled();
    });

    it('should commit SET_CHAT_DATA_FETCHED by ID, not mutate the data object directly (race condition fix)', async () => {
      const localCommit = vi.fn();
      const localDispatch = vi.fn().mockResolvedValue();
      const data = { id: 42, messages: [{ id: 100 }] };

      await actions.setActiveChat(
        { commit: localCommit, dispatch: localDispatch },
        { data }
      );

      // The action must NOT set dataFetched on the data object directly
      expect(data.dataFetched).toBeUndefined();

      // Instead it commits a mutation that finds the conversation by ID in the store
      expect(localCommit).toHaveBeenCalledWith(types.SET_CHAT_DATA_FETCHED, {
        id: 42,
        conversationType: 'conversation',
      });
    });
  });

  describe('#getInboxCaptainAssistantById', () => {
    it('fetches inbox assistant by id', async () => {
      axios.get.mockResolvedValue({
        data: {
          id: 1,
          name: 'Assistant',
          description: 'Assistant description',
        },
      });
      await actions.getInboxCaptainAssistantById({ commit }, 1);
      expect(commit.mock.calls).toEqual([
        [
          types.SET_INBOX_CAPTAIN_ASSISTANT,
          { id: 1, name: 'Assistant', description: 'Assistant description' },
        ],
      ]);
    });
  });

  describe('#fetchPreviousMessages first unread page', () => {
    it('loads the first unread direct-conversation page when it is outside the latest payload', async () => {
      const localCommit = vi.fn();
      axios.get.mockReset();
      const state = {
        allConversations: [
          {
            id: 1,
            unread_count: 3,
            messages: [],
          },
        ],
        selectedChatId: 1,
        selectedChatType: 'conversation',
      };
      axios.get
        .mockResolvedValueOnce({
          data: {
            meta: { first_unread_message_id: 10 },
            payload: [{ id: 30, created_at: 30 }],
          },
        })
        .mockResolvedValueOnce({
          data: {
            meta: {},
            payload: [
              { id: 10, created_at: 10 },
              { id: 20, created_at: 20 },
            ],
          },
        });

      await actions.fetchPreviousMessages(
        { commit: localCommit, state },
        { conversationId: 1, conversationType: 'conversation' }
      );

      expect(axios.get).toHaveBeenCalledTimes(2);
      expect(localCommit).toHaveBeenCalledWith(
        types.SET_PREVIOUS_CONVERSATIONS,
        {
          id: 1,
          conversationType: 'conversation',
          data: [
            { id: 10, created_at: 10 },
            { id: 20, created_at: 20 },
            { id: 30, created_at: 30 },
          ],
        }
      );
    });

    it('loads the first unread communication-thread page when it is outside the latest payload', async () => {
      const localCommit = vi.fn();
      axios.get.mockReset();
      const state = {
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            unread_count: 2,
            messages: [],
            channels: [],
            meta: {},
          },
        ],
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
      };
      axios.get
        .mockResolvedValueOnce({
          data: {
            meta: {
              contact: { id: 1 },
              channels: [],
              first_unread_message_id: 100,
            },
            payload: [{ id: 300, created_at: 300 }],
          },
        })
        .mockResolvedValueOnce({
          data: {
            meta: {},
            payload: [{ id: 100, created_at: 100 }],
          },
        });

      await actions.fetchPreviousMessages(
        { commit: localCommit, state },
        { conversationId: 7, conversationType: 'communication_thread' }
      );

      expect(axios.get).toHaveBeenCalledTimes(2);
      expect(localCommit).toHaveBeenCalledWith(
        types.SET_PREVIOUS_CONVERSATIONS,
        {
          id: 7,
          conversationType: 'communication_thread',
          data: [
            { id: 100, created_at: 100 },
            { id: 300, created_at: 300 },
          ],
        }
      );
    });
  });
});
