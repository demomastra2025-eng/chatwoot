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

    it('does not update current Fonoster call_status from an older call ref', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            additional_attributes: {
              fonoster_call_ref: 'current-call',
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
        fonoster_call_ref: 'current-call',
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
