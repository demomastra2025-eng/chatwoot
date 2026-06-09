import { afterEach, describe, expect, it, vi } from 'vitest';

import CommunicationThreadApi from '../../../../api/inbox/communicationThread';
import ConversationApi from '../../../../api/inbox/conversation';
import types from '../../../mutation-types';
import actions from '../actions';

describe('conversation actions', () => {
  afterEach(() => {
    vi.restoreAllMocks();
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
