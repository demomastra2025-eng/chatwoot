import { afterEach, describe, expect, it, vi } from 'vitest';

import CommunicationThreadApi from '../../../../api/inbox/communicationThread';
import ConversationApi from '../../../../api/inbox/conversation';
import types from '../../../mutation-types';
import actions from '../actions';
import { mutations } from '../index';

describe('conversation actions', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('#updateCommunicationThreadRealtime', () => {
    it('commits realtime thread events as partial patches so assignee tab membership is preserved', () => {
      const commit = vi.fn();
      const dispatch = vi.fn();
      const payload = {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        source_event: 'message.created',
        meta: {
          sender: { id: 42, name: 'Customer' },
          channel: 'CommunicationThread',
        },
        channels: [{ conversation_id: 11, inbox_id: 101 }],
        messages: [{ id: 99, conversation_id: 11, content: 'new' }],
        updated_at: 1710000000.25,
      };

      actions.updateCommunicationThreadRealtime({ commit, dispatch }, payload);

      expect(commit).toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.objectContaining({
          id: 7,
          communication_thread_id: 7,
          is_communication_thread: true,
          meta: {
            sender: { id: 42, name: 'Customer' },
            channel: 'CommunicationThread',
          },
        })
      );
      expect(commit.mock.calls[0][1].meta).not.toHaveProperty('assignee');
      expect(dispatch).toHaveBeenCalledWith('contacts/setContact', {
        id: 42,
        name: 'Customer',
      });
    });
    it('commits realtime thread messages so aggregate windows do not depend only on child-channel message.created', () => {
      const commit = vi.fn();
      const dispatch = vi.fn();
      const message = {
        id: 99,
        conversation_id: 11,
        communication_thread_id: 7,
        inbox_id: 101,
        inbox_name: 'WhatsApp',
        channel: 'Channel::Whatsapp',
        message_type: 0,
        created_at: 1710000001,
      };
      const payload = {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        source_event: 'message.created',
        meta: { sender: { id: 42, name: 'Customer' } },
        channels: [{ conversation_id: 11, inbox_id: 101 }],
        message,
        updated_at: 1710000001.25,
      };

      actions.updateCommunicationThreadRealtime({ commit, dispatch }, payload);

      expect(commit).toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.objectContaining({ id: 7, is_communication_thread: true })
      );
      const [, threadPatch] = commit.mock.calls.find(
        ([type]) => type === types.UPDATE_CONVERSATION
      );
      expect(threadPatch).not.toHaveProperty('message');
      expect(threadPatch).not.toHaveProperty('messages');
      expect(commit).toHaveBeenCalledWith(types.ADD_MESSAGE_TO_CHAT, {
        chatId: 7,
        message,
      });
    });
  });

  describe('#markCommunicationThreadRead', () => {
    it('marks the thread read without committing a full thread update that would retrigger scroll/read loop', async () => {
      const commit = vi.fn();
      const dispatch = vi.fn();
      vi.spyOn(Date, 'now').mockReturnValue(1712345678000);
      vi.spyOn(CommunicationThreadApi, 'markMessageRead').mockResolvedValue({
        data: {
          id: 7,
          unread_count: 0,
          messages: [],
          channels: [{ conversation_id: 11, inbox_id: 101 }],
          meta: { sender: { id: 42 } },
        },
      });

      await actions.markCommunicationThreadRead(
        { commit, dispatch },
        { id: 7 }
      );

      expect(CommunicationThreadApi.markMessageRead).toHaveBeenCalledWith({
        id: 7,
      });
      expect(commit).toHaveBeenCalledWith(types.UPDATE_MESSAGE_UNREAD_COUNT, {
        id: 7,
        lastSeen: 1712345678,
        unreadCount: 0,
        conversationType: 'communication_thread',
        channels: [{ conversation_id: 11, inbox_id: 101 }],
      });
      expect(commit).not.toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.anything()
      );
      expect(dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    });

    it('coalesces concurrent read requests for the same thread', async () => {
      const commit = vi.fn();
      const dispatch = vi.fn();
      let resolveRequest;
      const request = new Promise(resolve => {
        resolveRequest = resolve;
      });
      vi.spyOn(CommunicationThreadApi, 'markMessageRead').mockReturnValue(
        request
      );

      const firstCall = actions.markCommunicationThreadRead(
        { commit, dispatch },
        { id: 7 }
      );
      const secondCall = actions.markCommunicationThreadRead(
        { commit, dispatch },
        { id: 7 }
      );

      expect(CommunicationThreadApi.markMessageRead).toHaveBeenCalledTimes(1);
      resolveRequest({
        data: { id: 7, agent_last_seen_at: 1712345678, unread_count: 0 },
      });
      await Promise.all([firstCall, secondCall]);

      expect(commit).toHaveBeenCalledTimes(1);
      expect(dispatch).toHaveBeenCalledTimes(1);
    });
  });

  describe('#markMessagesUnread', () => {
    it('uses the communication-thread unread endpoint when explicitly targeting a thread', async () => {
      const commit = vi.fn();
      const dispatch = vi.fn();
      vi.spyOn(CommunicationThreadApi, 'markMessagesUnread').mockResolvedValue({
        data: {
          id: 7,
          agent_last_seen_at: 1712345600,
          unread_count: 2,
        },
      });

      await actions.markMessagesUnread(
        { commit, dispatch, state: { allConversations: [] } },
        { id: 7, conversationType: 'communication_thread' }
      );

      expect(CommunicationThreadApi.markMessagesUnread).toHaveBeenCalledWith({
        id: 7,
      });
      expect(commit).toHaveBeenCalledWith(types.UPDATE_MESSAGE_UNREAD_COUNT, {
        id: 7,
        lastSeen: 1712345600,
        unreadCount: 2,
        conversationType: 'communication_thread',
      });
      expect(dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    });
  });

  describe('#deleteCommunicationThreadConversations', () => {
    it('uses the communication-thread endpoint and removes selected child channels locally', async () => {
      const commit = vi.fn();
      const dispatch = vi.fn();
      vi.spyOn(CommunicationThreadApi, 'deleteConversations').mockResolvedValue(
        {
          data: { deleted_conversation_ids: [12] },
        }
      );

      await actions.deleteCommunicationThreadConversations(
        { commit, dispatch },
        { threadId: 7, conversationIds: [12] }
      );

      expect(CommunicationThreadApi.deleteConversations).toHaveBeenCalledWith(
        7,
        [12]
      );
      expect(commit).toHaveBeenCalledWith(
        types.DELETE_COMMUNICATION_THREAD_CONVERSATIONS,
        {
          threadId: 7,
          conversationIds: [12],
        }
      );
      expect(dispatch).toHaveBeenCalledWith(
        'conversationStats/get',
        { communicationThreadMode: true },
        { root: true }
      );
    });
  });

  describe('#fetchPreviousMessages', () => {
    it('keeps full communication-thread history available while paginating backwards', async () => {
      const commit = vi.fn();
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [
          {
            id: 7,
            is_communication_thread: true,
            unread_count: 0,
            messages: [],
            channels: [],
            meta: {},
          },
        ],
      };
      vi.spyOn(CommunicationThreadApi, 'messages').mockResolvedValue({
        data: {
          meta: { channels: [] },
          payload: [{ id: 180, created_at: 180 }],
        },
      });

      await actions.fetchPreviousMessages(
        { commit, state },
        {
          conversationId: 7,
          conversationType: 'communication_thread',
          before: 200,
        }
      );

      expect(CommunicationThreadApi.messages).toHaveBeenCalledWith(7, {
        after: undefined,
        before: 200,
        include_history: true,
      });
      expect(commit).toHaveBeenCalledWith(types.SET_PREVIOUS_CONVERSATIONS, {
        id: 7,
        conversationType: 'communication_thread',
        data: [{ id: 180, created_at: 180 }],
      });
    });
  });

  describe('#setCommunicationThreadPinned', () => {
    it('updates thread pin state through the communication-thread update endpoint', async () => {
      const commit = vi.fn();
      vi.spyOn(CommunicationThreadApi, 'update').mockResolvedValue({
        data: {
          id: 7,
          is_communication_thread: true,
          custom_attributes: { pinned: true },
          channels: [],
          messages: [],
          meta: { sender: { id: 42 } },
        },
      });

      await actions.setCommunicationThreadPinned(
        { commit },
        { conversationId: 7, pinned: true }
      );

      expect(CommunicationThreadApi.update).toHaveBeenCalledWith(7, {
        custom_attributes: { pinned: true },
      });
      expect(commit).toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.objectContaining({
          id: 7,
          is_communication_thread: true,
          custom_attributes: { pinned: true },
        })
      );
    });
  });

  describe('#fetchAllAttachments', () => {
    it('uses the communication thread attachments endpoint for thread records', async () => {
      const commit = vi.fn();
      vi.spyOn(CommunicationThreadApi, 'attachments').mockResolvedValue({
        data: { payload: [{ id: 99, file_type: 'image' }] },
      });
      const conversationAttachmentsSpy = vi
        .spyOn(ConversationApi, 'getAllAttachments')
        .mockResolvedValue({ data: { payload: [] } });

      await actions.fetchAllAttachments(
        {
          commit,
          state: {
            allConversations: [{ id: 7, is_communication_thread: true }],
          },
        },
        7
      );

      expect(CommunicationThreadApi.attachments).toHaveBeenCalledWith(7);
      expect(conversationAttachmentsSpy).not.toHaveBeenCalled();
      expect(commit).toHaveBeenCalledWith(types.SET_ALL_ATTACHMENTS, {
        id: 7,
        data: [{ id: 99, file_type: 'image' }],
      });
    });

    it('uses an explicit communication thread attachment payload to avoid id collisions with native conversations', async () => {
      const commit = vi.fn();
      vi.spyOn(CommunicationThreadApi, 'attachments').mockResolvedValue({
        data: { payload: [{ id: 100, file_type: 'file' }] },
      });
      const conversationAttachmentsSpy = vi
        .spyOn(ConversationApi, 'getAllAttachments')
        .mockResolvedValue({ data: { payload: [] } });

      await actions.fetchAllAttachments(
        {
          commit,
          state: {
            allConversations: [
              { id: 7, is_communication_thread: false },
              { id: 7, is_communication_thread: true },
            ],
          },
        },
        { conversationId: 7, isCommunicationThread: true }
      );

      expect(CommunicationThreadApi.attachments).toHaveBeenCalledWith(7);
      expect(conversationAttachmentsSpy).not.toHaveBeenCalled();
      expect(commit).toHaveBeenCalledWith(types.SET_ALL_ATTACHMENTS, {
        id: 7,
        data: [{ id: 100, file_type: 'file' }],
      });
    });
  });

  describe('#toggleStatus', () => {
    it('targets the native conversation when its id collides with a communication thread', async () => {
      const nativeConversation = {
        id: 7,
        status: 'open',
        meta: {},
        is_communication_thread: false,
      };
      const communicationThread = {
        id: 7,
        status: 'open',
        is_communication_thread: true,
        channels: [{ conversation_id: 7, status: 'open' }],
      };
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [nativeConversation, communicationThread],
      };
      const commit = vi.fn((type, payload) => mutations[type](state, payload));
      const conversationToggleSpy = vi
        .spyOn(ConversationApi, 'toggleStatus')
        .mockResolvedValue({
          data: {
            payload: {
              current_status: 'pending',
              snoozed_until: null,
            },
          },
        });
      const threadUpdateSpy = vi.spyOn(CommunicationThreadApi, 'update');

      await actions.toggleStatus(
        {
          commit,
          state,
        },
        {
          conversationId: 7,
          conversationType: 'conversation',
          status: 'pending',
        }
      );

      expect(conversationToggleSpy).toHaveBeenCalledWith({
        conversationId: 7,
        status: 'pending',
        snoozedUntil: null,
        statusReason: null,
      });
      expect(threadUpdateSpy).not.toHaveBeenCalled();
      expect(commit).toHaveBeenCalledWith(types.CHANGE_CONVERSATION_STATUS, {
        conversationId: 7,
        conversationType: 'conversation',
        status: 'pending',
        snoozedUntil: null,
      });
      expect(nativeConversation.status).toBe('pending');
      expect(communicationThread.status).toBe('open');
      expect(communicationThread.channels[0].status).toBe('pending');
    });
  });

  describe('#assignAgent', () => {
    it('targets the native conversation when its id collides with a communication thread', async () => {
      const commit = vi.fn();
      const assignment = { id: 9, name: 'Agent' };
      const nativeConversation = {
        id: 7,
        meta: { assignee: null },
        is_communication_thread: false,
      };
      const communicationThread = {
        id: 7,
        meta: { assignee: { id: 3, name: 'Thread agent' } },
        is_communication_thread: true,
      };
      const state = {
        selectedChatId: 7,
        selectedChatType: 'communication_thread',
        allConversations: [nativeConversation, communicationThread],
      };
      const dispatch = vi.fn((type, payload) => {
        if (type === 'setCurrentChatAssignee') {
          mutations[types.ASSIGN_AGENT](state, payload);
        }
      });
      const conversationAssignmentSpy = vi
        .spyOn(ConversationApi, 'assignAgent')
        .mockResolvedValue({ data: assignment });
      const threadUpdateSpy = vi.spyOn(CommunicationThreadApi, 'update');

      await actions.assignAgent(
        {
          commit,
          dispatch,
          state,
        },
        {
          conversationId: 7,
          conversationType: 'conversation',
          agentId: 9,
        }
      );

      expect(conversationAssignmentSpy).toHaveBeenCalledWith({
        conversationId: 7,
        agentId: 9,
      });
      expect(threadUpdateSpy).not.toHaveBeenCalled();
      expect(dispatch).toHaveBeenCalledWith('setCurrentChatAssignee', {
        conversationId: 7,
        assignee: assignment,
      });
      expect(nativeConversation.meta.assignee).toEqual(assignment);
      expect(communicationThread.meta.assignee).toEqual({
        id: 3,
        name: 'Thread agent',
      });
    });

    it('rethrows assignment failures when the caller requests fail-fast behavior', async () => {
      const error = new Error('assignment failed');
      vi.spyOn(ConversationApi, 'assignAgent').mockRejectedValue(error);

      await expect(
        actions.assignAgent(
          {
            commit: vi.fn(),
            dispatch: vi.fn(),
            state: { allConversations: [] },
          },
          {
            conversationId: 7,
            conversationType: 'conversation',
            agentId: 9,
            throwOnError: true,
          }
        )
      ).rejects.toThrow('assignment failed');
    });
  });
});
