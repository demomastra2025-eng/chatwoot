import { afterEach, describe, expect, it, vi } from 'vitest';

import CommunicationThreadApi from '../../../../api/inbox/communicationThread';
import ConversationApi from '../../../../api/inbox/conversation';
import types from '../../../mutation-types';
import actions from '../actions';

describe('conversation actions', () => {
  afterEach(() => {
    vi.restoreAllMocks();
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
      });
      expect(commit).not.toHaveBeenCalledWith(
        types.UPDATE_CONVERSATION,
        expect.anything()
      );
      expect(dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
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
});
