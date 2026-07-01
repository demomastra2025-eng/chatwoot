import { describe } from 'vitest';
import types from '../../../mutation-types';
import { mutations } from '../../conversations';

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    emit: vi.fn(),
    on: vi.fn(),
    off: vi.fn(),
  },
}));

import { emitter } from 'shared/helpers/mitt';

describe('#mutations', () => {
  describe('#EMPTY_ALL_CONVERSATION', () => {
    it('empty conversations', () => {
      const state = { allConversations: [{ id: 1 }], selectedChatId: 1 };
      mutations[types.EMPTY_ALL_CONVERSATION](state);
      expect(state.allConversations).toEqual([]);
      expect(state.selectedChatId).toEqual(null);
    });
  });

  describe('#UPDATE_MESSAGE_UNREAD_COUNT', () => {
    it('mark conversation as read', () => {
      const state = { allConversations: [{ id: 1 }] };
      const lastSeen = new Date().getTime() / 1000;
      mutations[types.UPDATE_MESSAGE_UNREAD_COUNT](state, { id: 1, lastSeen });
      expect(state.allConversations).toEqual([
        { id: 1, agent_last_seen_at: lastSeen, unread_count: 0 },
      ]);
    });

    it('doesnot send any mutation if chat doesnot exist', () => {
      const state = { allConversations: [] };
      const lastSeen = new Date().getTime() / 1000;
      mutations[types.UPDATE_MESSAGE_UNREAD_COUNT](state, { id: 1, lastSeen });
      expect(state.allConversations).toEqual([]);
    });
    it('updates communication thread channel unread metadata', () => {
      const state = {
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            channels: [
              { conversation_id: 11, agent_last_seen_at: 1, unread_count: 3 },
              { conversation_id: 12, agent_last_seen_at: 1, unread_count: 4 },
            ],
          },
        ],
      };

      mutations[types.UPDATE_MESSAGE_UNREAD_COUNT](state, {
        id: 7,
        lastSeen: 123,
        unreadCount: 1,
        conversationType: 'communication_thread',
        channels: [
          { conversation_id: 11, agent_last_seen_at: 123, unread_count: 0 },
        ],
      });

      expect(state.allConversations[0]).toEqual({
        id: 7,
        is_communication_thread: true,
        agent_last_seen_at: 123,
        unread_count: 1,
        channels: [
          { conversation_id: 11, agent_last_seen_at: 123, unread_count: 0 },
          { conversation_id: 12, agent_last_seen_at: 1, unread_count: 4 },
        ],
      });
    });
  });

  describe('#CLEAR_CURRENT_CHAT_WINDOW', () => {
    it('clears current chat window', () => {
      const state = { selectedChatId: 1 };
      mutations[types.CLEAR_CURRENT_CHAT_WINDOW](state);
      expect(state.selectedChatId).toEqual(null);
    });
  });

  describe('#ASSIGN_TEAM', () => {
    it('clears current chat window', () => {
      const state = { allConversations: [{ id: 1, meta: {} }] };
      mutations[types.UPDATE_CONVERSATION_LAST_ACTIVITY](state, {
        lastActivityAt: 1602256198,
        conversationId: 1,
      });

      expect(state.allConversations).toEqual([
        { id: 1, meta: {}, last_activity_at: 1602256198 },
      ]);
    });
  });
  describe('#UPDATE_CONVERSATION_LAST_ACTIVITY', () => {
    it('update conversation last activity', () => {
      const state = { allConversations: [{ id: 1, meta: {} }] };
      mutations[types.ASSIGN_TEAM](state, {
        team: { id: 1, name: 'Team 1' },
        conversationId: 1,
      });
      expect(state.allConversations).toEqual([
        { id: 1, meta: { team: { id: 1, name: 'Team 1' } } },
      ]);
    });
  });

  describe('#CHANGE_CHAT_SORT_FILTER', () => {
    it('update conversation sort filter', () => {
      const state = { chatSortFilter: 'latest' };
      mutations[types.CHANGE_CHAT_SORT_FILTER](state, {
        data: 'sort_on_created_at',
      });
      expect(state.chatSortFilter).toEqual({ data: 'sort_on_created_at' });
    });
  });

  describe('#SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS', () => {
    it('keeps CRM and appointment sidebar counts in state', () => {
      const state = { sidebarUnreadCounts: {} };

      mutations[types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS](state, {
        all: 5,
        statuses: { open: 2 },
        inboxes: { 10: 1 },
        teams: { 20: 2 },
        labels: { vip: 3 },
        pipelines: { 30: 4 },
        stages: { 40: 5 },
        appointment_statuses: { confirmed: 6 },
      });

      expect(state.sidebarUnreadCounts).toEqual({
        all: 5,
        statuses: { open: 2 },
        inboxes: { 10: 1 },
        teams: { 20: 2 },
        labels: { vip: 3 },
        pipelines: { 30: 4 },
        stages: { 40: 5 },
        appointment_statuses: { confirmed: 6 },
      });
    });
  });

  describe('#SET_CURRENT_CHAT_WINDOW', () => {
    it('set current chat window', () => {
      const state = { selectedChatId: 1 };
      mutations[types.SET_CURRENT_CHAT_WINDOW](state, { id: 2 });
      expect(state.selectedChatId).toEqual(2);
      expect(state.selectedChatType).toEqual('conversation');
    });

    it('does not set current chat window', () => {
      const state = { selectedChatId: 1, selectedChatType: 'conversation' };
      mutations[types.SET_CURRENT_CHAT_WINDOW](state);
      expect(state.selectedChatId).toEqual(1);
      expect(state.selectedChatType).toEqual('conversation');
    });

    it('stores communication thread selection type separately from conversation ids', () => {
      const state = { selectedChatId: 1, selectedChatType: 'conversation' };
      mutations[types.SET_CURRENT_CHAT_WINDOW](state, {
        id: 2,
        is_communication_thread: true,
      });
      expect(state.selectedChatId).toEqual(2);
      expect(state.selectedChatType).toEqual('communication_thread');
    });
  });

  describe('#SET_CONVERSATION_CAN_REPLY', () => {
    it('set canReply flag', () => {
      const state = { allConversations: [{ id: 1, can_reply: false }] };
      mutations[types.SET_CONVERSATION_CAN_REPLY](state, {
        conversationId: 1,
        canReply: true,
      });
      expect(state.allConversations[0].can_reply).toEqual(true);
    });
  });

  describe('#ADD_MESSAGE', () => {
    it('does not add message to the store if conversation does not exist', () => {
      const state = { allConversations: [] };
      mutations[types.ADD_MESSAGE](state, { conversationId: 1 });
      expect(state.allConversations).toEqual([]);
    });

    it('does not add an unrelated child conversation message to a same-id communication thread', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            is_communication_thread: true,
            conversation_ids: [99],
            messages: [],
          },
        ],
        selectedChatId: -1,
      };

      mutations[types.ADD_MESSAGE](state, {
        id: 10,
        conversation_id: 1,
        content: 'Wrong namespace',
        created_at: 1602256198,
      });

      expect(state.allConversations[0].messages).toEqual([]);
    });

    it('updates the concrete conversation when a same-id communication thread is also cached', () => {
      const thread = {
        id: 1,
        is_communication_thread: true,
        conversation_ids: [99],
        messages: [],
      };
      const conversation = { id: 1, messages: [] };
      const state = {
        allConversations: [thread, conversation],
        selectedChatId: 1,
        selectedChatType: 'communication_thread',
      };

      mutations[types.ADD_MESSAGE](state, {
        id: 20,
        conversation_id: 1,
        content: 'Concrete child conversation',
        created_at: 1602256199,
      });

      expect(thread.messages).toEqual([]);
      expect(conversation.messages).toEqual([
        {
          id: 20,
          conversation_id: 1,
          content: 'Concrete child conversation',
          created_at: 1602256199,
        },
      ]);
    });

    it('add message to the conversation if it does not exist in the store', () => {
      global.bus = { $emit: vi.fn() };
      const state = {
        allConversations: [{ id: 1, messages: [] }],
        selectedChatId: -1,
      };
      mutations[types.ADD_MESSAGE](state, {
        conversation_id: 1,
        content: 'Test message',
        created_at: 1602256198,
      });
      expect(state.allConversations).toEqual([
        {
          id: 1,
          messages: [
            {
              conversation_id: 1,
              content: 'Test message',
              created_at: 1602256198,
            },
          ],
          unread_count: 0,
          timestamp: 1602256198,
        },
      ]);
      expect(emitter.emit).not.toHaveBeenCalled();
    });

    it('add message to the conversation and emit scrollToMessage if it does not exist in the store', () => {
      global.bus = { $emit: vi.fn() };
      const state = {
        allConversations: [{ id: 1, messages: [] }],
        selectedChatId: 1,
      };
      mutations[types.ADD_MESSAGE](state, {
        conversation_id: 1,
        content: 'Test message',
        created_at: 1602256198,
      });
      expect(state.allConversations).toEqual([
        {
          id: 1,
          messages: [
            {
              conversation_id: 1,
              content: 'Test message',
              created_at: 1602256198,
            },
          ],
          unread_count: 0,
          timestamp: 1602256198,
        },
      ]);
      expect(emitter.emit).toHaveBeenCalledWith('SCROLL_TO_MESSAGE');
    });

    it('update message if it exist in the store', () => {
      global.bus = { $emit: vi.fn() };
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                conversation_id: 1,
                content: 'Test message',
                created_at: 1602256198,
              },
            ],
          },
        ],
        selectedChatId: 1,
      };
      mutations[types.ADD_MESSAGE](state, {
        conversation_id: 1,
        content: 'Test message 1',
        created_at: 1602256198,
      });
      expect(state.allConversations).toEqual([
        {
          id: 1,
          messages: [
            {
              conversation_id: 1,
              content: 'Test message 1',
              created_at: 1602256198,
            },
          ],
        },
      ]);
      expect(emitter.emit).not.toHaveBeenCalled();
    });

    it('updates directional activity timestamps from realtime conversation messages', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [],
            last_incoming_message_at: 100,
            last_outgoing_message_at: 200,
          },
        ],
        selectedChatId: -1,
      };

      mutations[types.ADD_MESSAGE](state, {
        id: 10,
        conversation_id: 1,
        message_type: 0,
        created_at: 300,
      });
      mutations[types.ADD_MESSAGE](state, {
        id: 11,
        conversation_id: 1,
        message_type: 1,
        created_at: 400,
      });

      expect(state.allConversations[0].last_incoming_message_at).toBe(300);
      expect(state.allConversations[0].last_outgoing_message_at).toBe(400);
    });
  });

  describe('#ADD_MESSAGE_TO_CHAT', () => {
    it('keeps communication thread reply state on the latest incoming channel', () => {
      const state = {
        allConversations: [
          {
            id: 3,
            is_communication_thread: true,
            conversation_ids: [3508],
            messages: [],
            channels: [
              {
                conversation_id: 3508,
                inbox_id: 4674,
                channel: 'Channel::Telegram',
                can_reply: false,
                can_send_text: false,
                can_send_attachments: false,
                reply_window_open: false,
                disabled: true,
                disabled_reason: 'not_replyable',
                last_activity_at: 100,
                channel_key: 'conversation:3508',
              },
            ],
            meta: { sender: { id: 42, name: 'Customer' } },
            inbox_id: null,
            active_reply_channel: null,
            can_reply: false,
          },
        ],
        selectedChatId: 3,
        selectedChatType: 'communication_thread',
      };

      mutations[types.ADD_MESSAGE_TO_CHAT](state, {
        chatId: 3,
        message: {
          id: 10,
          conversation_id: 3508,
          inbox_id: 4674,
          message_type: 0,
          created_at: 200,
        },
      });

      const thread = state.allConversations[0];
      expect(thread.meta.sender).toEqual({ id: 42, name: 'Customer' });
      expect(thread.last_incoming_message_at).toBe(200);
      expect(thread.can_reply).toBe(true);
      expect(thread.inbox_id).toBe(4674);
      expect(thread.active_reply_channel).toMatchObject({
        conversation_id: 3508,
        inbox_id: 4674,
        channel: 'Channel::Telegram',
        can_reply: true,
        disabled: false,
      });
    });

    it('updates the communication thread when a same-id conversation is also cached', () => {
      const conversation = { id: 3, messages: [] };
      const thread = {
        id: 3,
        is_communication_thread: true,
        conversation_ids: [3508],
        messages: [],
        channels: [
          {
            conversation_id: 3508,
            inbox_id: 4674,
            channel: 'Channel::Telegram',
            channel_key: 'conversation:3508',
          },
        ],
      };
      const state = {
        allConversations: [conversation, thread],
        selectedChatId: 3,
        selectedChatType: 'communication_thread',
        attachments: {},
      };

      mutations[types.ADD_MESSAGE_TO_CHAT](state, {
        chatId: 3,
        message: {
          id: 30,
          conversation_id: 3508,
          inbox_id: 4674,
          message_type: 0,
          created_at: 201,
        },
      });

      expect(conversation.messages).toEqual([]);
      expect(thread.messages).toEqual([
        {
          id: 30,
          conversation_id: 3508,
          inbox_id: 4674,
          message_type: 0,
          created_at: 201,
        },
      ]);
    });

    it('updates thread-scoped attachment cache from linked child messages', () => {
      const state = {
        allConversations: [
          {
            id: 3,
            is_communication_thread: true,
            conversation_ids: [3508],
            messages: [],
            channels: [{ conversation_id: 3508, inbox_id: 4674 }],
          },
        ],
        attachments: { 3: [{ id: 1 }] },
      };
      const message = {
        id: 30,
        conversation_id: 3508,
        inbox_id: 4674,
        message_type: 1,
        status: 'sent',
        attachments: [{ id: 2 }],
        created_at: 201,
      };

      mutations[types.ADD_MESSAGE_TO_CHAT](state, { chatId: 3, message });

      expect(state.attachments[3]).toEqual([{ id: 1 }, { id: 2 }]);
    });
  });

  describe('#CHANGE_CONVERSATION_STATUS', () => {
    it('updates the conversation status correctly', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [],
            status: 'open',
          },
        ],
      };

      mutations[types.CHANGE_CONVERSATION_STATUS](state, {
        conversationId: '1',
        status: 'resolved',
      });

      expect(state.allConversations).toEqual([
        {
          id: 1,
          messages: [],
          status: 'resolved',
        },
      ]);
    });

    describe('#UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES', () => {
      it('update conversation custom attributes', () => {
        const custom_attributes = { order_id: 1001 };
        const state = { allConversations: [{ id: 1, custom_attributes: {} }] };
        mutations[types.UPDATE_CONVERSATION_CUSTOM_ATTRIBUTES](state, {
          conversationId: 1,
          customAttributes: custom_attributes,
        });
        expect(state.allConversations[0].custom_attributes).toEqual(
          custom_attributes
        );
      });
    });
  });

  describe('#SET_CONVERSATION_FILTERS', () => {
    it('set conversation filter', () => {
      const appliedFilters = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: [{ id: 'snoozed', name: 'Snoozed' }],
          query_operator: 'and',
        },
      ];
      mutations[types.SET_CONVERSATION_FILTERS](appliedFilters);
      expect(appliedFilters).toEqual([
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: [{ id: 'snoozed', name: 'Snoozed' }],
          query_operator: 'and',
        },
      ]);
    });
  });

  describe('#CLEAR_CONVERSATION_FILTERS', () => {
    it('clears applied conversation filters', () => {
      const state = {
        appliedFilters: [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: [{ id: 'snoozed', name: 'Snoozed' }],
            query_operator: 'and',
          },
        ],
      };
      mutations[types.CLEAR_CONVERSATION_FILTERS](state);
      expect(state.appliedFilters).toEqual([]);
    });
  });

  describe('#SET_ALL_CONVERSATION', () => {
    it('set all conversation', () => {
      const state = { allConversations: [{ id: 1 }] };
      const data = [{ id: 1, name: 'test' }];
      mutations[types.SET_ALL_CONVERSATION](state, data);
      expect(state.allConversations).toEqual(data);
    });

    it('keeps communication threads and conversations in separate id namespaces', () => {
      const conversation = { id: 3, messages: [], meta: { sender: { id: 1 } } };
      const thread = {
        id: 3,
        is_communication_thread: true,
        messages: [],
        meta: { sender: { id: 2 } },
      };
      const state = { allConversations: [conversation] };

      mutations[types.SET_ALL_CONVERSATION](state, [thread]);

      expect(state.allConversations).toEqual([conversation, thread]);
    });

    it('set all conversation in reconnect if selected chat id and conversation id is the same', () => {
      const state = {
        allConversations: [{ id: 1, status: 'open' }],
        selectedChatId: 1,
      };
      const data = [{ id: 1, name: 'test', status: 'resolved' }];
      mutations[types.SET_ALL_CONVERSATION](state, data);
      expect(state.allConversations).toEqual(data);
    });

    it('set all conversation in reconnect if selected chat id and conversation id is the same then do not update messages, attachments, dataFetched, allMessagesLoaded', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [{ id: 1, content: 'test' }],
            dataFetched: true,
            allMessagesLoaded: true,
          },
        ],
        selectedChatId: 1,
      };
      const data = [
        {
          id: 1,
          name: 'test',
          messages: [{ id: 1, content: 'updated message' }],
          dataFetched: true,
          allMessagesLoaded: true,
        },
      ];
      const expected = [
        {
          id: 1,
          name: 'test',
          messages: [{ id: 1, content: 'test' }],
          dataFetched: true,
          allMessagesLoaded: true,
        },
      ];
      mutations[types.SET_ALL_CONVERSATION](state, data);
      expect(state.allConversations).toEqual(expected);
    });

    it('set all conversation in reconnect if selected chat id and conversation id is not the same', () => {
      const state = {
        allConversations: [{ id: 1, status: 'open' }],
        selectedChatId: 2,
      };
      const data = [{ id: 1, name: 'test', status: 'resolved' }];
      mutations[types.SET_ALL_CONVERSATION](state, data);
      expect(state.allConversations).toEqual(data);
    });

    it('set all conversation in reconnect if selected chat id and conversation id is not the same then update messages', () => {
      const state = {
        allConversations: [{ id: 1, messages: [{ id: 1, content: 'test' }] }],
        selectedChatId: 2,
      };
      const data = [
        { id: 1, name: 'test', messages: [{ id: 1, content: 'tested' }] },
      ];
      mutations[types.SET_ALL_CONVERSATION](state, data);
      expect(state.allConversations).toEqual(data);
    });
  });

  describe('#SET_ALL_ATTACHMENTS', () => {
    it('set all attachments', () => {
      const state = {
        allConversations: [{ id: 1 }],
        attachments: {},
      };
      const data = [{ id: 1, name: 'test' }];
      mutations[types.SET_ALL_ATTACHMENTS](state, { id: 1, data });
      expect(state.attachments[1]).toEqual(data);
    });
    it('set attachments key even if the attachments are empty', () => {
      const state = {
        allConversations: [{ id: 1 }],
        attachments: {},
      };
      const data = [];
      mutations[types.SET_ALL_ATTACHMENTS](state, { id: 1, data });
      expect(state.attachments[1]).toEqual([]);
    });
  });

  describe('#ADD_CONVERSATION_ATTACHMENTS', () => {
    it('add conversation attachments', () => {
      const state = {
        allConversations: [{ id: 1 }],
        attachments: {},
      };
      const message = {
        conversation_id: 1,
        status: 'sent',
        attachments: [{ id: 1, name: 'test' }],
      };

      mutations[types.ADD_CONVERSATION_ATTACHMENTS](state, message);
      expect(state.attachments[1]).toEqual(message.attachments);
    });

    it('should not add duplicate attachments', () => {
      const state = {
        allConversations: [{ id: 1 }],
        attachments: { 1: [{ id: 1, name: 'existing' }] },
      };
      const message = {
        conversation_id: 1,
        status: 'sent',
        attachments: [
          { id: 1, name: 'existing' },
          { id: 2, name: 'new' },
        ],
      };

      mutations[types.ADD_CONVERSATION_ATTACHMENTS](state, message);
      expect(state.attachments[1]).toHaveLength(2);
      expect(state.attachments[1]).toContainEqual({
        id: 1,
        name: 'existing',
      });
      expect(state.attachments[1]).toContainEqual({
        id: 2,
        name: 'new',
      });
    });

    it('should not add attachments if chat not found', () => {
      const state = {
        allConversations: [{ id: 1, attachments: [] }],
        attachments: {
          1: [],
        },
      };
      const message = {
        conversation_id: 2,
        status: 'sent',
        attachments: [{ id: 1, name: 'test' }],
      };

      mutations[types.ADD_CONVERSATION_ATTACHMENTS](state, message);
      expect(state.attachments[1]).toHaveLength(0);
    });
  });

  describe('#DELETE_CONVERSATION_ATTACHMENTS', () => {
    it('delete conversation attachments', () => {
      const state = {
        allConversations: [{ id: 1 }],
        attachments: {
          1: [{ id: 1, message_id: 1 }],
        },
      };
      const message = {
        conversation_id: 1,
        status: 'sent',
        id: 1,
      };

      mutations[types.DELETE_CONVERSATION_ATTACHMENTS](state, message);
      expect(state.attachments[1]).toHaveLength(0);
    });

    it('should not delete attachments for non-matching message id', () => {
      const state = {
        allConversations: [{ id: 1 }],
        attachments: {
          1: [{ id: 1, message_id: 1 }],
        },
      };
      const message = {
        conversation_id: 1,
        status: 'sent',
        id: 2,
      };

      mutations[types.DELETE_CONVERSATION_ATTACHMENTS](state, message);
      expect(state.attachments[1]).toHaveLength(1);
    });

    it('should not delete attachments if chat not found', () => {
      const state = {
        allConversations: [{ id: 1 }],
        attachments: { 1: [{ id: 1, message_id: 1 }] },
      };
      const message = {
        conversation_id: 2,
        status: 'sent',
        id: 1,
      };

      mutations[types.DELETE_CONVERSATION_ATTACHMENTS](state, message);
      expect(state.attachments[1]).toHaveLength(1);
    });
  });

  describe('#SET_CONTEXT_MENU_CHAT_ID', () => {
    it('sets the context menu chat id', () => {
      const state = {
        contextMenuChatId: 1,
        contextMenuChatType: 'conversation',
      };
      mutations[types.SET_CONTEXT_MENU_CHAT_ID](state, 2);
      expect(state.contextMenuChatId).toEqual(2);
      expect(state.contextMenuChatType).toBeNull();
    });

    it('sets the context menu chat type from object payload', () => {
      const state = { contextMenuChatId: 1, contextMenuChatType: null };
      mutations[types.SET_CONTEXT_MENU_CHAT_ID](state, {
        id: 2,
        conversationType: 'communication_thread',
      });
      expect(state.contextMenuChatId).toEqual(2);
      expect(state.contextMenuChatType).toEqual('communication_thread');
    });
  });

  describe('#SET_CHAT_LIST_FILTERS', () => {
    it('set chat list filters', () => {
      const conversationFilters = {
        inboxId: 1,
        assigneeType: 'me',
        status: 'open',
        sortBy: 'created_at',
        page: 1,
        labels: ['label'],
        teamId: 1,
        conversationType: 'mention',
      };
      const state = { conversationFilters: conversationFilters };
      mutations[types.SET_CHAT_LIST_FILTERS](state, conversationFilters);
      expect(state.conversationFilters).toEqual(conversationFilters);
    });
  });

  describe('#UPDATE_CHAT_LIST_FILTERS', () => {
    it('update chat list filters', () => {
      const conversationFilters = {
        inboxId: 1,
        assigneeType: 'me',
        status: 'open',
        sortBy: 'created_at',
        page: 1,
        labels: ['label'],
        teamId: 1,
        conversationType: 'mention',
      };
      const state = { conversationFilters: conversationFilters };
      mutations[types.UPDATE_CHAT_LIST_FILTERS](state, {
        inboxId: 2,
        updatedWithin: 20,
        assigneeType: 'all',
      });
      expect(state.conversationFilters).toEqual({
        inboxId: 2,
        assigneeType: 'all',
        status: 'open',
        sortBy: 'created_at',
        page: 1,
        labels: ['label'],
        teamId: 1,
        conversationType: 'mention',
        updatedWithin: 20,
      });
    });
  });

  describe('#SET_INBOX_CAPTAIN_ASSISTANT', () => {
    it('set inbox captain assistant', () => {
      const state = { copilotAssistant: {} };
      const data = {
        assistant: {
          id: 1,
          name: 'Assistant',
          description: 'Assistant description',
        },
      };
      mutations[types.SET_INBOX_CAPTAIN_ASSISTANT](state, data);
      expect(state.copilotAssistant).toEqual(data.assistant);
    });
  });

  describe('#SET_CHAT_DATA_FETCHED', () => {
    it('should set dataFetched to true on the conversation by ID', () => {
      const state = {
        allConversations: [{ id: 1 }, { id: 2 }],
      };
      mutations[types.SET_CHAT_DATA_FETCHED](state, 1);
      expect(state.allConversations[0].dataFetched).toBe(true);
      expect(state.allConversations[1].dataFetched).toBeUndefined();
    });

    it('should do nothing if conversation is not found', () => {
      const state = { allConversations: [{ id: 1 }] };
      mutations[types.SET_CHAT_DATA_FETCHED](state, 999);
      expect(state.allConversations[0].dataFetched).toBeUndefined();
    });

    it('should survive the race: SET_ALL_CONVERSATION replaces the object, then SET_CHAT_DATA_FETCHED still works', () => {
      // 1. Initial state: conversation exists with dataFetched undefined
      const state = {
        allConversations: [{ id: 1, messages: [{ id: 'm1' }] }],
        selectedChatId: 1,
      };
      const originalRef = state.allConversations[0];

      // 2. Simulate SET_ALL_CONVERSATION replacing the object (WebSocket/polling)
      //    This copies dataFetched from the old object (still undefined)
      mutations[types.SET_ALL_CONVERSATION](state, [
        { id: 1, name: 'refreshed', messages: [{ id: 'm2' }] },
      ]);

      // The store now holds a NEW object, old reference is detached
      const newRef = state.allConversations[0];
      expect(newRef).not.toBe(originalRef);
      expect(newRef.dataFetched).toBeUndefined();

      // 3. SET_CHAT_DATA_FETCHED finds by ID — works on the current store object
      mutations[types.SET_CHAT_DATA_FETCHED](state, 1);
      expect(state.allConversations[0].dataFetched).toBe(true);

      // Old detached reference is unaffected
      expect(originalRef.dataFetched).toBeUndefined();
    });
  });

  describe('#SET_ALL_MESSAGES_LOADED', () => {
    it('should set allMessagesLoaded to true on the conversation by ID', () => {
      const state = {
        allConversations: [{ id: 1, allMessagesLoaded: false }, { id: 2 }],
      };
      mutations[types.SET_ALL_MESSAGES_LOADED](state, 1);
      expect(state.allConversations[0].allMessagesLoaded).toBe(true);
      expect(state.allConversations[1].allMessagesLoaded).toBeUndefined();
    });

    it('should do nothing if conversation is not found', () => {
      const state = { allConversations: [{ id: 1 }] };
      mutations[types.SET_ALL_MESSAGES_LOADED](state, 999);
      expect(state.allConversations[0].allMessagesLoaded).toBeUndefined();
    });
  });

  describe('#CLEAR_ALL_MESSAGES_LOADED', () => {
    it('should set allMessagesLoaded to false on the conversation by ID', () => {
      const state = {
        allConversations: [
          { id: 1, allMessagesLoaded: true },
          { id: 2, allMessagesLoaded: true },
        ],
      };
      mutations[types.CLEAR_ALL_MESSAGES_LOADED](state, 1);
      expect(state.allConversations[0].allMessagesLoaded).toBe(false);
      expect(state.allConversations[1].allMessagesLoaded).toBe(true);
    });

    it('should do nothing if conversation is not found', () => {
      const state = { allConversations: [{ id: 1, allMessagesLoaded: true }] };
      mutations[types.CLEAR_ALL_MESSAGES_LOADED](state, 999);
      expect(state.allConversations[0].allMessagesLoaded).toBe(true);
    });
  });

  describe('#SET_PREVIOUS_CONVERSATIONS', () => {
    it('should prepend messages to conversation messages array', () => {
      const state = {
        allConversations: [{ id: 1, messages: [{ id: 'msg2' }] }],
      };
      const payload = { id: 1, data: [{ id: 'msg1' }] };

      mutations[types.SET_PREVIOUS_CONVERSATIONS](state, payload);
      expect(state.allConversations[0].messages).toEqual([
        { id: 'msg1' },
        { id: 'msg2' },
      ]);
    });

    it('should not modify messages if data is empty', () => {
      const state = {
        allConversations: [{ id: 1, messages: [{ id: 'msg2' }] }],
      };
      const payload = { id: 1, data: [] };

      mutations[types.SET_PREVIOUS_CONVERSATIONS](state, payload);
      expect(state.allConversations[0].messages).toEqual([{ id: 'msg2' }]);
    });

    it('should merge messages by id and keep chronological order', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              { id: 2, content: 'stale latest', created_at: 20 },
              { id: 3, content: 'local newest', created_at: 30 },
            ],
          },
        ],
      };
      const payload = {
        id: 1,
        data: [
          { id: 1, content: 'older', created_at: 10 },
          { id: 2, content: 'fresh latest', created_at: 20 },
        ],
      };

      mutations[types.SET_PREVIOUS_CONVERSATIONS](state, payload);

      expect(state.allConversations[0].messages).toEqual([
        { id: 1, content: 'older', created_at: 10 },
        { id: 2, content: 'fresh latest', created_at: 20 },
        { id: 3, content: 'local newest', created_at: 30 },
      ]);
    });

    it('replaces a pending communication thread message when fetched server message has the same echo_id', () => {
      const state = {
        allConversations: [
          {
            id: 321,
            is_communication_thread: true,
            messages: [
              {
                id: 'temp-echo-id',
                echo_id: 'temp-echo-id',
                status: 'progress',
                content: 'hello',
                created_at: 10,
              },
            ],
            channels: [],
          },
        ],
      };

      mutations[types.SET_PREVIOUS_CONVERSATIONS](state, {
        id: 321,
        conversationType: 'communication_thread',
        data: [
          {
            id: 393095,
            echo_id: 'temp-echo-id',
            status: 'read',
            content: 'hello',
            created_at: 10,
            source_id: 'wamid.example',
          },
        ],
      });

      expect(state.allConversations[0].messages).toEqual([
        {
          id: 393095,
          echo_id: 'temp-echo-id',
          status: 'read',
          content: 'hello',
          created_at: 10,
          source_id: 'wamid.example',
        },
      ]);
    });

    it('replaces a stale pending communication thread message when fetched server message has no echo_id', () => {
      const state = {
        allConversations: [
          {
            id: 321,
            is_communication_thread: true,
            messages: [
              {
                id: 'temp-local-id',
                echo_id: 'temp-local-id',
                status: 'progress',
                message_type: 1,
                conversation_id: 22,
                content: 'Здравствуйте',
                created_at: 100,
              },
            ],
            channels: [],
          },
        ],
      };

      mutations[types.SET_PREVIOUS_CONVERSATIONS](state, {
        id: 321,
        conversationType: 'communication_thread',
        data: [
          {
            id: 393095,
            status: 'delivered',
            message_type: 1,
            conversation_id: 22,
            content: 'Здравствуйте',
            created_at: 104,
            source_id: 'wamid.example',
          },
        ],
      });

      expect(state.allConversations[0].messages).toEqual([
        {
          id: 393095,
          status: 'delivered',
          message_type: 1,
          conversation_id: 22,
          content: 'Здравствуйте',
          created_at: 104,
          source_id: 'wamid.example',
        },
      ]);
    });

    it('updates the typed communication thread when a same-id conversation is present first', () => {
      const conversation = { id: 3, messages: [{ id: 'conversation-old' }] };
      const thread = {
        id: 3,
        is_communication_thread: true,
        messages: [{ id: 'thread-old', created_at: 2 }],
        channels: [],
      };
      const state = {
        allConversations: [conversation, thread],
      };

      mutations[types.SET_PREVIOUS_CONVERSATIONS](state, {
        id: 3,
        conversationType: 'communication_thread',
        data: [{ id: 'thread-new', created_at: 1 }],
      });

      expect(conversation.messages).toEqual([{ id: 'conversation-old' }]);
      expect(thread.messages).toEqual([
        { id: 'thread-new', created_at: 1 },
        { id: 'thread-old', created_at: 2 },
      ]);
    });
  });

  describe('#SET_MISSING_MESSAGES', () => {
    it('should replace message array with new data', () => {
      const state = {
        allConversations: [{ id: 1, messages: [{ id: 'old' }] }],
      };
      const payload = { id: 1, data: [{ id: 'new' }] };

      mutations[types.SET_MISSING_MESSAGES](state, payload);
      expect(state.allConversations[0].messages).toEqual([{ id: 'new' }]);
    });

    it('should do nothing if conversation is not found', () => {
      const state = {
        allConversations: [],
      };
      const payload = { id: 1, data: [{ id: 'new' }] };

      mutations[types.SET_MISSING_MESSAGES](state, payload);
      expect(state.allConversations).toEqual([]);
    });

    it('replaces messages on the typed communication thread when ids collide', () => {
      const conversation = { id: 3, messages: [{ id: 'conversation-old' }] };
      const thread = {
        id: 3,
        is_communication_thread: true,
        messages: [{ id: 'thread-old' }],
        channels: [],
      };
      const state = {
        allConversations: [conversation, thread],
      };
      const payload = {
        id: 3,
        conversationType: 'communication_thread',
        data: [{ id: 'thread-new' }],
      };

      mutations[types.SET_MISSING_MESSAGES](state, payload);

      expect(conversation.messages).toEqual([{ id: 'conversation-old' }]);
      expect(thread.messages).toEqual([{ id: 'thread-new' }]);
    });
  });

  describe('#ASSIGN_AGENT', () => {
    it('should assign agent to the correct conversation by ID', () => {
      const assignee = { id: 1, name: 'Agent' };
      const state = {
        allConversations: [
          { id: 1, meta: {} },
          { id: 2, meta: {} },
        ],
        selectedChatId: 2,
      };

      mutations[types.ASSIGN_AGENT](state, {
        conversationId: 1,
        assignee,
      });
      expect(state.allConversations[0].meta.assignee).toEqual(assignee);
      expect(state.allConversations[1].meta.assignee).toBeUndefined();
    });
  });

  describe('#ASSIGN_PRIORITY', () => {
    it('should assign priority to conversation', () => {
      const priority = { title: 'Urgent', value: 'urgent' };
      const state = {
        allConversations: [{ id: 1 }],
      };

      mutations[types.ASSIGN_PRIORITY](state, {
        priority,
        conversationId: 1,
      });
      expect(state.allConversations[0].priority).toEqual(priority);
    });
  });

  describe('#MUTE_CONVERSATION', () => {
    it('should mute selected conversation', () => {
      const state = {
        allConversations: [{ id: 1, muted: false }],
        selectedChatId: 1,
      };

      mutations[types.MUTE_CONVERSATION](state);
      expect(state.allConversations[0].muted).toBe(true);
    });
  });

  describe('#UNMUTE_CONVERSATION', () => {
    it('should unmute selected conversation', () => {
      const state = {
        allConversations: [{ id: 1, muted: true }],
        selectedChatId: 1,
      };

      mutations[types.UNMUTE_CONVERSATION](state);
      expect(state.allConversations[0].muted).toBe(false);
    });
  });

  describe('#UPDATE_CONVERSATION', () => {
    it('should update existing conversation', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            status: 'open',
            updated_at: 100,
            messages: [{ id: 'msg1' }],
          },
        ],
      };

      const conversation = {
        id: 1,
        status: 'resolved',
        updated_at: 200,
        messages: [{ id: 'msg2' }],
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations[0]).toEqual({
        id: 1,
        status: 'resolved',
        updated_at: 200,
        messages: [{ id: 'msg1' }],
      });
    });

    it('merges partial communication thread realtime updates without wiping detail state', () => {
      const state = {
        allConversations: [
          {
            id: 3,
            is_communication_thread: true,
            status: 'pending',
            updated_at: 100,
            unread_count: 0,
            conversation_ids: [3508],
            channels: [
              {
                conversation_id: 3508,
                inbox_id: 4674,
                channel: 'Channel::Telegram',
                can_reply: true,
                can_send_text: true,
                last_activity_at: 100,
                channel_key: 'conversation:3508',
              },
            ],
            active_reply_channel: {
              conversation_id: 3508,
              inbox_id: 4674,
              channel: 'Channel::Telegram',
              can_reply: true,
              channel_key: 'conversation:3508',
            },
            inbox_id: 4674,
            can_reply: true,
            messages: [{ id: 1, conversation_id: 3508, created_at: 100 }],
            meta: { sender: { id: 42, name: 'Customer' } },
          },
        ],
        selectedChatId: 3,
        selectedChatType: 'communication_thread',
      };

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 3,
        communication_thread_id: 3,
        is_communication_thread: true,
        status: 'open',
        unread_count: 1,
        updated_at: 200,
        timestamp: 200,
        source_event: 'message.created',
      });

      expect(state.allConversations[0]).toMatchObject({
        id: 3,
        is_communication_thread: true,
        status: 'open',
        unread_count: 1,
        updated_at: 200,
        inbox_id: 4674,
        can_reply: true,
        meta: { sender: { id: 42, name: 'Customer' } },
        active_reply_channel: {
          conversation_id: 3508,
          inbox_id: 4674,
          channel: 'Channel::Telegram',
          can_reply: true,
        },
      });
      expect(state.allConversations[0].channels).toHaveLength(1);
      expect(state.allConversations[0].messages).toEqual([
        { id: 1, conversation_id: 3508, created_at: 100 },
      ]);
    });

    it('merges new linked child channels from partial thread realtime patches', () => {
      const state = {
        allConversations: [
          {
            id: 3,
            is_communication_thread: true,
            status: 'open',
            updated_at: 100,
            conversation_ids: [3508],
            channels: [
              {
                conversation_id: 3508,
                inbox_id: 4674,
                channel: 'Channel::Telegram',
                channel_key: 'conversation:3508',
                last_activity_at: 100,
              },
            ],
            messages: [],
            meta: {
              sender: { id: 42, name: 'Customer' },
              channel: 'CommunicationThread',
              assignee: { id: 9, name: 'Agent' },
            },
          },
        ],
      };

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 3,
        communication_thread_id: 3,
        is_communication_thread: true,
        conversation_id: 630,
        conversation_ids: [3508, 630],
        inbox_id: 4675,
        inbox_name: 'WhatsApp',
        channel: 'Channel::Whatsapp',
        contact_inbox_id: 880,
        can_reply: true,
        meta: {
          sender: { id: 43, name: 'Merged customer' },
          channel: 'CommunicationThread',
        },
        updated_at: 200,
        timestamp: 200,
      });

      expect(state.allConversations[0].conversation_ids).toEqual([3508, 630]);
      expect(state.allConversations[0].channels).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            conversation_id: 630,
            inbox_id: 4675,
            inbox_name: 'WhatsApp',
            channel: 'Channel::Whatsapp',
            can_reply: true,
          }),
        ])
      );
      expect(state.allConversations[0].meta).toEqual({
        sender: { id: 43, name: 'Merged customer' },
        channel: 'CommunicationThread',
        assignee: { id: 9, name: 'Agent' },
      });
    });

    it('replaces stale channels with the server channel list from full realtime patches', () => {
      const state = {
        allConversations: [
          {
            id: 3,
            is_communication_thread: true,
            updated_at: 100,
            conversation_ids: [3508, 630],
            channels: [
              {
                conversation_id: 3508,
                inbox_id: 4674,
                channel: 'Channel::Telegram',
                channel_key: 'conversation:3508',
              },
              {
                conversation_id: 630,
                inbox_id: 4675,
                channel: 'Channel::Whatsapp',
                channel_key: 'conversation:630',
              },
            ],
            messages: [],
            meta: { sender: { id: 42, name: 'Customer' } },
          },
        ],
      };

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 3,
        communication_thread_id: 3,
        is_communication_thread: true,
        conversation_id: 630,
        conversation_ids: [630],
        inbox_id: 4675,
        inbox_name: 'WhatsApp',
        channel: 'Channel::Whatsapp',
        can_reply: false,
        can_send_text: false,
        requires_template: true,
        disabled: false,
        channels: [
          {
            conversation_id: 630,
            inbox_id: 4675,
            inbox_name: 'WhatsApp',
            channel: 'Channel::Whatsapp',
            can_reply: false,
            can_send_text: false,
            requires_template: true,
            disabled: false,
            channel_key: 'conversation:630',
          },
        ],
        updated_at: 200,
        timestamp: 200,
      });

      expect(state.allConversations[0].conversation_ids).toEqual([630]);
      expect(state.allConversations[0].channels).toHaveLength(1);
      expect(state.allConversations[0].channels[0]).toMatchObject({
        conversation_id: 630,
        inbox_id: 4675,
        requires_template: true,
      });
      expect(state.allConversations[0].channels).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({ conversation_id: 3508 }),
        ])
      );
      expect(state.allConversations[0].can_reply).toBe(true);
    });

    it('does not replace a same-display-id communication thread with a child conversation update', () => {
      const thread = {
        id: 3,
        is_communication_thread: true,
        status: 'pending',
        updated_at: 100,
        conversation_ids: [3508],
        channels: [],
        messages: [],
        meta: { sender: { id: 42, name: 'Customer' } },
      };
      const state = {
        allConversations: [thread],
        selectedChatId: 3,
        selectedChatType: 'communication_thread',
      };

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 3,
        status: 'open',
        updated_at: 200,
        inbox_id: 4674,
        can_reply: false,
        meta: { sender: { id: 999, name: 'Unknown subscriber' } },
      });

      expect(state.allConversations).toEqual([thread]);
    });

    it('should add conversation if not found on normal view', () => {
      const state = {
        allConversations: [],
        conversationFilters: {},
      };

      const conversation = {
        id: 1,
        status: 'open',
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations).toEqual([conversation]);
    });

    it('should not add conversation if not found on participating view', () => {
      const state = {
        allConversations: [],
        conversationFilters: { conversationType: 'participating' },
      };

      const conversation = {
        id: 1,
        status: 'open',
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations).toEqual([]);
    });

    it('should not add conversation if not found on mention view', () => {
      const state = {
        allConversations: [],
        conversationFilters: { conversationType: 'mention' },
      };

      const conversation = {
        id: 1,
        status: 'open',
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations).toEqual([]);
    });

    it('should add conversation if not found on unattended view', () => {
      const state = {
        allConversations: [],
        conversationFilters: { conversationType: 'unattended' },
      };

      const conversation = {
        id: 1,
        status: 'open',
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations).toEqual([conversation]);
    });

    it('should not emit scroll events for selected conversation metadata updates', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            status: 'open',
            updated_at: 100,
          },
        ],
        selectedChatId: 1,
      };

      const conversation = {
        id: 1,
        status: 'resolved',
        updated_at: 200,
      };

      emitter.emit.mockClear();
      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(emitter.emit).not.toHaveBeenCalledWith('SCROLL_TO_MESSAGE');
    });

    it('should ignore updates with older timestamps', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            status: 'open',
            updated_at: 200,
          },
        ],
      };

      const conversation = {
        id: 1,
        status: 'resolved',
        updated_at: 100,
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations[0].status).toEqual('open');
    });

    it('should allow updates with same timestamps', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            status: 'open',
            updated_at: 100,
          },
        ],
      };

      const conversation = {
        id: 1,
        status: 'resolved',
        updated_at: 100,
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations[0].status).toEqual('resolved');
    });

    it('should preserve dataFetched and allMessagesLoaded during update', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            status: 'open',
            updated_at: 100,
            messages: [{ id: 'msg1' }],
            dataFetched: true,
            allMessagesLoaded: true,
          },
        ],
      };

      const conversation = {
        id: 1,
        status: 'resolved',
        updated_at: 200,
        messages: [{ id: 'msg2' }],
      };

      mutations[types.UPDATE_CONVERSATION](state, conversation);
      expect(state.allConversations[0].status).toEqual('resolved');
      expect(state.allConversations[0].dataFetched).toBe(true);
      expect(state.allConversations[0].allMessagesLoaded).toBe(true);
      expect(state.allConversations[0].messages).toEqual([{ id: 'msg1' }]);
    });
  });

  describe('#UPDATE_CONVERSATION_CONTACT', () => {
    it('should update conversation contact data', () => {
      const state = {
        allConversations: [
          { id: 1, meta: { sender: { id: 1, name: 'Old Name' } } },
        ],
      };

      const payload = {
        conversationId: 1,
        id: 1,
        name: 'New Name',
      };

      mutations[types.UPDATE_CONVERSATION_CONTACT](state, payload);
      // The mutation extracts all properties except conversationId
      const { conversationId, ...contact } = payload;
      expect(state.allConversations[0].meta.sender).toEqual(contact);
    });

    it('should do nothing if conversation is not found', () => {
      const state = {
        allConversations: [],
      };

      const payload = {
        conversationId: 1,
        id: 1,
        name: 'New Name',
      };

      mutations[types.UPDATE_CONVERSATION_CONTACT](state, payload);
      expect(state.allConversations).toEqual([]);
    });
  });

  describe('#UPDATE_CONTACT_IN_CONVERSATIONS', () => {
    it('updates loaded direct conversations and communication threads for a contact update', () => {
      const state = {
        allConversations: [
          { id: 1, meta: { sender: { id: 42, name: 'Old direct' } } },
          {
            id: 3,
            is_communication_thread: true,
            meta: {
              sender: { id: 42, name: 'Old thread', phone_number: '+7700' },
            },
          },
          { id: 9, meta: { sender: { id: 99, name: 'Other' } } },
        ],
      };

      mutations[types.UPDATE_CONTACT_IN_CONVERSATIONS](state, {
        id: 42,
        name: 'Updated customer',
      });

      expect(state.allConversations[0].meta.sender).toEqual({
        id: 42,
        name: 'Updated customer',
      });
      expect(state.allConversations[1].meta.sender).toEqual({
        id: 42,
        name: 'Updated customer',
        phone_number: '+7700',
      });
      expect(state.allConversations[2].meta.sender).toEqual({
        id: 99,
        name: 'Other',
      });
    });
  });

  describe('#SET_ACTIVE_INBOX', () => {
    it('should set current inbox as integer', () => {
      const state = {
        currentInbox: null,
      };

      mutations[types.SET_ACTIVE_INBOX](state, '1');
      expect(state.currentInbox).toBe(1);
    });

    it('should set null if no inbox ID provided', () => {
      const state = {
        currentInbox: 1,
      };

      mutations[types.SET_ACTIVE_INBOX](state, null);
      expect(state.currentInbox).toBe(null);
    });
  });

  describe('#CLEAR_CONTACT_CONVERSATIONS', () => {
    it('should remove all conversations with matching contact ID', () => {
      const state = {
        allConversations: [
          { id: 1, meta: { sender: { id: 1 } } },
          { id: 2, meta: { sender: { id: 2 } } },
          { id: 3, meta: { sender: { id: 1 } } },
        ],
      };

      mutations[types.CLEAR_CONTACT_CONVERSATIONS](state, 1);
      expect(state.allConversations).toHaveLength(1);
      expect(state.allConversations[0].id).toBe(2);
    });
  });

  describe('#ADD_CONVERSATION', () => {
    it('should add a new conversation', () => {
      const state = {
        allConversations: [],
      };

      const conversation = { id: 1, messages: [] };
      mutations[types.ADD_CONVERSATION](state, conversation);
      expect(state.allConversations).toEqual([conversation]);
    });

    it('should not add a duplicate conversation', () => {
      const conversation = { id: 1, messages: [] };
      const state = {
        allConversations: [conversation],
      };

      mutations[types.ADD_CONVERSATION](state, { id: 1, messages: [] });
      expect(state.allConversations).toHaveLength(1);
    });
  });

  describe('#DELETE_CONVERSATION', () => {
    it('should delete a conversation', () => {
      const state = {
        allConversations: [{ id: 1, messages: [] }],
      };

      mutations[types.DELETE_CONVERSATION](state, 1);
      expect(state.allConversations).toEqual([]);
    });

    it('does not delete a same-id communication thread when deleting a concrete conversation', () => {
      const thread = {
        id: 1,
        is_communication_thread: true,
        messages: [],
      };
      const state = {
        allConversations: [{ id: 1, messages: [] }, thread],
      };

      mutations[types.DELETE_CONVERSATION](state, 1);

      expect(state.allConversations).toEqual([thread]);
    });
  });

  describe('#SET_LIST_LOADING_STATUS', () => {
    it('should set listLoadingStatus to true', () => {
      const state = {
        listLoadingStatus: false,
      };

      mutations[types.SET_LIST_LOADING_STATUS](state);
      expect(state.listLoadingStatus).toBe(true);
    });
  });

  describe('#CLEAR_LIST_LOADING_STATUS', () => {
    it('should set listLoadingStatus to false', () => {
      const state = {
        listLoadingStatus: true,
      };

      mutations[types.CLEAR_LIST_LOADING_STATUS](state);
      expect(state.listLoadingStatus).toBe(false);
    });
  });

  describe('#CHANGE_CHAT_STATUS_FILTER', () => {
    it('should update chat status filter', () => {
      const state = {
        chatStatusFilter: 'open',
      };

      mutations[types.CHANGE_CHAT_STATUS_FILTER](state, 'resolved');
      expect(state.chatStatusFilter).toBe('resolved');
    });
  });

  describe('#UPDATE_ASSIGNEE', () => {
    it('should update assignee on conversation', () => {
      const state = {
        allConversations: [{ id: 1, meta: { assignee: null } }],
      };

      const payload = {
        id: 1,
        assignee: { id: 1, name: 'Agent' },
      };

      mutations[types.UPDATE_ASSIGNEE](state, payload);
      expect(state.allConversations[0].meta.assignee).toEqual(payload.assignee);
    });
  });

  describe('#SET_LAST_MESSAGE_ID_IN_SYNC_CONVERSATION', () => {
    it('should update the sync conversation message ID', () => {
      const state = {
        syncConversationsMessages: {},
      };

      mutations[types.SET_LAST_MESSAGE_ID_IN_SYNC_CONVERSATION](state, {
        conversationId: 1,
        messageId: 100,
      });

      expect(state.syncConversationsMessages[1]).toBe(100);
    });

    it('keeps sync cursors separate for typed communication threads', () => {
      const state = {
        syncConversationsMessages: {},
      };

      mutations[types.SET_LAST_MESSAGE_ID_IN_SYNC_CONVERSATION](state, {
        conversationId: 1,
        conversationType: 'communication_thread',
        messageId: 100,
      });

      expect(state.syncConversationsMessages['communication_thread:1']).toBe(
        100
      );
      expect(state.syncConversationsMessages[1]).toBeUndefined();
    });
  });
});
