import { afterEach, describe, expect, it, vi } from 'vitest';

import { mutations } from '../index';
import types from '../../../mutation-types';
import { BUS_EVENTS } from '../../../../../shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

describe('#mutations', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('#UPDATE_CONVERSATION', () => {
    it('updates selected conversation metadata without forcing the message list to bottom', () => {
      const emitSpy = vi.spyOn(emitter, 'emit');
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            updated_at: 1,
            messages: [],
            channels: [],
          },
        ],
      };

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 7,
        is_communication_thread: true,
        updated_at: 2,
        unread_count: 0,
      });

      expect(state.allConversations[0].unread_count).toBe(0);
      expect(emitSpy).not.toHaveBeenCalledWith(BUS_EVENTS.SCROLL_TO_MESSAGE);
    });

    it('does not scroll a selected communication thread for same-id child conversation messages', () => {
      const emitSpy = vi.spyOn(emitter, 'emit');
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [
          {
            id: 7,
            messages: [],
          },
        ],
      };

      mutations[types.ADD_MESSAGE](state, {
        id: 99,
        conversation_id: 7,
        created_at: 2,
        conversation: { unread_count: 1 },
      });

      expect(emitSpy).not.toHaveBeenCalledWith(BUS_EVENTS.SCROLL_TO_MESSAGE);
    });

    it('preserves communication thread assignee when realtime meta omits assignee', () => {
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            updated_at: 1,
            meta: {
              sender: { id: 42, name: 'Old customer' },
              assignee: { id: 179, name: 'John' },
              team: { id: 5, name: 'Sales' },
            },
            messages: [],
            channels: [{ conversation_id: 11, inbox_id: 101 }],
          },
        ],
      };

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        updated_at: 2,
        source_event: 'message.created',
        meta: {
          sender: { id: 42, name: 'New customer' },
          channel: 'CommunicationThread',
        },
        channels: [{ conversation_id: 11, inbox_id: 101 }],
      });

      expect(state.allConversations[0].meta).toMatchObject({
        sender: { id: 42, name: 'New customer' },
        assignee: { id: 179, name: 'John' },
        team: { id: 5, name: 'Sales' },
      });
    });

    it('replaces and clears communication thread assignment from realtime meta', () => {
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            updated_at: 1,
            meta: {
              sender: { id: 42, name: 'Customer' },
              assignee: { id: 179, name: 'John' },
              assignee_type: 'User',
              team: { id: 5, name: 'Sales' },
            },
            messages: [],
            channels: [{ conversation_id: 11, inbox_id: 101 }],
          },
        ],
      };

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        updated_at: 2,
        source_event: 'conversation.assignee_changed',
        meta: {
          assignee: { id: 87, name: 'Жандаулет Гусман' },
          assignee_type: 'User',
          channel: 'CommunicationThread',
          team: { id: 9, name: 'Support' },
        },
        channels: [{ conversation_id: 11, inbox_id: 101 }],
      });

      expect(state.allConversations[0].meta).toMatchObject({
        assignee: { id: 87, name: 'Жандаулет Гусман' },
        assignee_type: 'User',
        team: { id: 9, name: 'Support' },
      });

      mutations[types.UPDATE_CONVERSATION](state, {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        updated_at: 3,
        source_event: 'conversation.assignee_changed',
        meta: {
          assignee: null,
          assignee_type: null,
          channel: 'CommunicationThread',
          team: null,
        },
        channels: [{ conversation_id: 11, inbox_id: 101 }],
      });

      expect(state.allConversations[0].meta).toMatchObject({
        assignee: null,
        assignee_type: null,
        team: null,
      });
    });
  });

  describe('#ADD_MESSAGE', () => {
    it('keeps direct conversation messages ordered and deduplicated for mixed id types', () => {
      const state = {
        selectedChatId: null,
        selectedChatType: null,
        allConversations: [
          {
            id: 11,
            timestamp: 1710000020,
            messages: [{ id: 2, conversation_id: 11, created_at: 1710000020 }],
          },
        ],
      };

      mutations[types.ADD_MESSAGE](state, {
        id: 1,
        conversation_id: 11,
        created_at: 1710000010,
      });
      mutations[types.ADD_MESSAGE](state, {
        id: '1',
        conversation_id: 11,
        created_at: 1710000010,
      });

      expect(
        state.allConversations[0].messages.map(message => message.id)
      ).toEqual(['1', 2]);
      expect(state.allConversations[0].timestamp).toBe(1710000020);
    });

    it('orders ISO and epoch timestamps without poisoning the conversation timestamp', () => {
      const state = {
        selectedChatId: null,
        selectedChatType: null,
        allConversations: [
          {
            id: 11,
            timestamp: '2024-03-09T16:00:20.000Z',
            last_incoming_message_at: '2024-03-09T16:00:20.000Z',
            messages: [
              {
                id: 2,
                conversation_id: 11,
                created_at: '2024-03-09T16:00:20.000Z',
              },
            ],
          },
        ],
      };

      mutations[types.ADD_MESSAGE](state, {
        id: 1,
        conversation_id: 11,
        created_at: 1710000010,
        message_type: 0,
      });

      expect(
        state.allConversations[0].messages.map(message => message.id)
      ).toEqual([1, 2]);
      expect(state.allConversations[0].timestamp).toBe(1710000020);
      expect(state.allConversations[0].last_incoming_message_at).toBe(
        1710000020
      );
      expect(Number.isNaN(state.allConversations[0].timestamp)).toBe(false);
    });
  });

  describe('#ADD_MESSAGE_TO_CHAT', () => {
    it('does not duplicate the same realtime message when native and thread events both arrive', () => {
      const message = {
        id: 99,
        conversation_id: 11,
        communication_thread_id: 7,
        inbox_id: 101,
        message_type: 0,
        created_at: 1710000001,
      };
      const state = {
        selectedChatId: null,
        selectedChatType: null,
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            conversation_ids: [11],
            channels: [{ conversation_id: 11, inbox_id: 101 }],
            messages: [],
          },
        ],
        attachments: {},
      };

      mutations[types.ADD_MESSAGE_TO_CHAT](state, { chatId: 7, message });
      mutations[types.ADD_MESSAGE_TO_CHAT](state, { chatId: 7, message });

      expect(state.allConversations[0].messages).toHaveLength(1);
      expect(state.allConversations[0].messages[0]).toEqual(message);
    });

    it('normalizes ISO channel activity when adding a thread message', () => {
      const message = {
        id: 100,
        conversation_id: 11,
        communication_thread_id: 7,
        inbox_id: 101,
        message_type: 0,
        created_at: 1710000030,
      };
      const state = {
        selectedChatId: null,
        selectedChatType: null,
        allConversations: [
          {
            id: 7,
            timestamp: '2024-03-09T16:00:20.000Z',
            is_communication_thread: true,
            conversation_ids: [11],
            channels: [
              {
                conversation_id: 11,
                inbox_id: 101,
                last_activity_at: '2024-03-09T16:00:20.000Z',
              },
            ],
            messages: [],
          },
        ],
        attachments: {},
      };

      mutations[types.ADD_MESSAGE_TO_CHAT](state, { chatId: 7, message });

      expect(state.allConversations[0].timestamp).toBe(1710000030);
      expect(state.allConversations[0].channels[0].last_activity_at).toBe(
        1710000030
      );
    });
  });

  describe('#DELETE_COMMUNICATION_THREAD_CONVERSATIONS', () => {
    it('removes only the selected child channels from a communication thread', () => {
      const state = {
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            conversation_ids: [11, 12],
            channels: [
              { conversation_id: 11, inbox_id: 101, primary: true },
              { conversation_id: 12, inbox_id: 102 },
            ],
          },
        ],
      };

      mutations[types.DELETE_COMMUNICATION_THREAD_CONVERSATIONS](state, {
        threadId: 7,
        conversationIds: [12],
      });

      expect(state.allConversations).toHaveLength(1);
      expect(state.allConversations[0].conversation_ids).toEqual([11]);
      expect(state.allConversations[0].channels).toEqual([
        { conversation_id: 11, inbox_id: 101, primary: true },
      ]);
    });

    it('removes the aggregate thread when its last selected channel is removed', () => {
      const state = {
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            conversation_ids: [11],
            channels: [{ conversation_id: 11, inbox_id: 101 }],
          },
          { id: 7, is_communication_thread: false },
        ],
      };

      mutations[types.DELETE_COMMUNICATION_THREAD_CONVERSATIONS](state, {
        threadId: 7,
        conversationIds: [11],
      });

      expect(state.allConversations).toEqual([
        { id: 7, is_communication_thread: false },
      ]);
    });

    it('clears the selected chat when the selected aggregate thread loses its last channel', () => {
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            conversation_ids: [11],
            channels: [{ conversation_id: 11, inbox_id: 101 }],
          },
        ],
      };

      mutations[types.DELETE_COMMUNICATION_THREAD_CONVERSATIONS](state, {
        threadId: 7,
        conversationIds: [11],
      });

      expect(state.allConversations).toEqual([]);
      expect(state.selectedChatId).toBeNull();
      expect(state.selectedChatType).toBeNull();
    });
  });

  describe('#UPDATE_CONVERSATION_CALL_STATUS', () => {
    it('does nothing if conversation is not found', () => {
      const state = { allConversations: [] };
      mutations[types.UPDATE_CONVERSATION_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'ringing',
      });
      expect(state.allConversations).toEqual([]);
    });

    it('updates call_status preserving existing additional_attributes', () => {
      const state = {
        allConversations: [
          { id: 1, additional_attributes: { other_attr: 'value' } },
        ],
      };
      mutations[types.UPDATE_CONVERSATION_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'in-progress',
      });
      expect(state.allConversations[0].additional_attributes).toEqual({
        other_attr: 'value',
        call_status: 'in-progress',
      });
    });

    it('creates additional_attributes if it does not exist', () => {
      const state = { allConversations: [{ id: 1 }] };
      mutations[types.UPDATE_CONVERSATION_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'completed',
      });
      expect(state.allConversations[0].additional_attributes).toEqual({
        call_status: 'completed',
      });
    });

    it('does not update current telephony call_status from an older call ref', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            additional_attributes: {
              telephony_call_ref: 'current-call',
              call_status: 'ringing',
            },
          },
        ],
      };
      mutations[types.UPDATE_CONVERSATION_CALL_STATUS](state, {
        conversationId: 1,
        callSid: 'old-call',
        callStatus: 'completed',
      });
      expect(state.allConversations[0].additional_attributes).toEqual({
        telephony_call_ref: 'current-call',
        call_status: 'ringing',
      });
    });
  });

  describe('#UPDATE_MESSAGE_CALL_STATUS', () => {
    it('does nothing if conversation is not found', () => {
      const state = { allConversations: [] };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'ringing',
      });
      expect(state.allConversations).toEqual([]);
    });

    it('does nothing if no voice call message exists', () => {
      const state = {
        allConversations: [
          { id: 1, messages: [{ id: 1, content_type: 'text' }] },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'ringing',
      });
      expect(state.allConversations[0].messages[0]).toEqual({
        id: 1,
        content_type: 'text',
      });
    });

    it('updates the last voice call message status', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                id: 1,
                content_type: 'voice_call',
                content_attributes: { data: { status: 'ringing' } },
              },
              {
                id: 2,
                content_type: 'voice_call',
                content_attributes: { data: { status: 'ringing' } },
              },
            ],
          },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'in-progress',
      });
      expect(
        state.allConversations[0].messages[0].content_attributes.data.status
      ).toBe('ringing');
      expect(
        state.allConversations[0].messages[1].content_attributes.data.status
      ).toBe('in-progress');
    });

    it('updates only the voice call message matching callSid', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                id: 1,
                source_id: 'voice_call:old-call',
                content_type: 'voice_call',
                content_attributes: {
                  data: { call_sid: 'old-call', status: 'ringing' },
                },
              },
              {
                id: 2,
                source_id: 'voice_call:current-call',
                content_type: 'voice_call',
                content_attributes: {
                  data: { call_sid: 'current-call', status: 'ringing' },
                },
              },
            ],
          },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callSid: 'old-call',
        callStatus: 'no_answer',
      });
      expect(
        state.allConversations[0].messages[0].content_attributes.data.status
      ).toBe('no_answer');
      expect(
        state.allConversations[0].messages[1].content_attributes.data.status
      ).toBe('ringing');
    });

    it('does not update another voice call message when callSid is unknown', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                id: 1,
                content_type: 'voice_call',
                content_attributes: {
                  data: { call_sid: 'current-call', status: 'ringing' },
                },
              },
            ],
          },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callSid: 'old-call',
        callStatus: 'completed',
      });
      expect(
        state.allConversations[0].messages[0].content_attributes.data.status
      ).toBe('ringing');
    });

    it('creates content_attributes.data if it does not exist', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [{ id: 1, content_type: 'voice_call' }],
          },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'completed',
      });
      expect(
        state.allConversations[0].messages[0].content_attributes.data.status
      ).toBe('completed');
    });

    it('preserves existing data in content_attributes.data', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                id: 1,
                content_type: 'voice_call',
                content_attributes: {
                  data: { call_sid: 'CA123', status: 'ringing' },
                },
              },
            ],
          },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'in-progress',
      });
      expect(
        state.allConversations[0].messages[0].content_attributes.data
      ).toEqual({
        call_sid: 'CA123',
        status: 'in-progress',
      });
    });

    it('merges terminal voice call data so recordings appear without a reload', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                id: 1,
                source_id: 'voice_call:sipuni:call-1',
                content_type: 'voice_call',
                content_attributes: {
                  data: {
                    call_sid: 'sipuni:call-1',
                    status: 'ringing',
                    provider: 'sipuni',
                  },
                },
              },
            ],
          },
        ],
      };

      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callSid: 'sipuni:call-1',
        callStatus: 'completed',
        callData: {
          status: 'completed',
          duration: 6,
          recording_url:
            '/api/v1/accounts/530/telephony/calls/sipuni%3Acall-1/recording?recording_token=token',
          recording: {
            content_type: 'audio/mpeg',
          },
        },
      });

      expect(
        state.allConversations[0].messages[0].content_attributes.data
      ).toEqual({
        call_sid: 'sipuni:call-1',
        status: 'completed',
        provider: 'sipuni',
        duration: 6,
        recording_url:
          '/api/v1/accounts/530/telephony/calls/sipuni%3Acall-1/recording?recording_token=token',
        recording: {
          content_type: 'audio/mpeg',
        },
      });
    });

    it('handles empty messages array', () => {
      const state = {
        allConversations: [{ id: 1, messages: [] }],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'ringing',
      });
      expect(state.allConversations[0].messages).toEqual([]);
    });
  });
});
