import { describe, expect, it, vi } from 'vitest';

import MessagesView from './MessagesView.vue';

describe('MessagesView', () => {
  it('does not show the messaging-window banner for voice conversations', () => {
    expect(
      MessagesView.computed.shouldShowReplyWindowBanner.call({
        currentChat: { can_reply: false },
        isAVoiceChannel: true,
        hasCommunicationThreadReplyableChannel: false,
      })
    ).toBe(false);
  });

  it('does not show the messaging-window banner for replyable communication threads', () => {
    expect(
      MessagesView.computed.hasCommunicationThreadReplyableChannel.call({
        currentChat: {
          is_communication_thread: true,
          can_reply: false,
          channels: [
            {
              inbox_id: 4674,
              channel: 'Channel::Voice',
              can_reply: false,
              disabled: false,
            },
          ],
        },
      })
    ).toBe(true);

    expect(
      MessagesView.computed.shouldShowReplyWindowBanner.call({
        currentChat: {
          is_communication_thread: true,
          can_reply: false,
          channels: [
            {
              inbox_id: 4674,
              channel: 'Channel::Voice',
              can_reply: false,
              disabled: false,
            },
          ],
        },
        isAVoiceChannel: false,
        hasCommunicationThreadReplyableChannel: true,
      })
    ).toBe(false);
  });

  it('shows the messaging-window banner for restricted non-voice conversations', () => {
    expect(
      MessagesView.computed.shouldShowReplyWindowBanner.call({
        currentChat: { can_reply: false },
        isAVoiceChannel: false,
        hasCommunicationThreadReplyableChannel: false,
      })
    ).toBe(true);
  });

  describe('#onScrollToMessage', () => {
    const buildContext = overrides => ({
      $nextTick: callback => callback(),
      fetchPreviousMessages: vi.fn(),
      isNearConversationBottom: vi.fn(() => false),
      makeMessagesRead: vi.fn(),
      scrollToBottom: vi.fn(),
      hasUserScrolled: true,
      ...overrides,
    });

    it('does not force-scroll or mark read when the agent is reading older history', () => {
      const context = buildContext();

      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.scrollToBottom).not.toHaveBeenCalled();
      expect(context.makeMessagesRead).not.toHaveBeenCalled();
    });

    it('force-scrolls after an agent sends a message', () => {
      const context = buildContext();

      MessagesView.methods.onScrollToMessage.call(context, { force: true });

      expect(context.scrollToBottom).toHaveBeenCalled();
      expect(context.makeMessagesRead).toHaveBeenCalled();
    });

    it('keeps auto-scroll for agents already near the bottom', () => {
      const context = buildContext({
        isNearConversationBottom: vi.fn(() => true),
      });

      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.scrollToBottom).toHaveBeenCalled();
      expect(context.makeMessagesRead).toHaveBeenCalled();
    });

    it('does not mark messages read when unread messages are not mounted yet', () => {
      const context = buildContext({
        isNearConversationBottom: vi.fn(() => true),
        scrollToBottom: vi.fn(() => false),
      });

      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.scrollToBottom).toHaveBeenCalled();
      expect(context.makeMessagesRead).not.toHaveBeenCalled();
    });
  });

  describe('#scrollToBottom', () => {
    const buildPanel = ({
      unreadMessage = null,
      labelSuggestion = null,
    } = {}) => {
      const panel = {
        scrollHeight: 2000,
        clientHeight: 500,
        scrollTop: 300,
        getBoundingClientRect: () => ({ top: 100, bottom: 600 }),
        querySelector: vi.fn(selector => {
          if (selector === '.message--unread') return unreadMessage;
          if (selector === '.label-suggestion') return labelSuggestion;
          return null;
        }),
      };
      return panel;
    };

    it('scrolls to the first unread DOM message when unread messages are mounted', () => {
      const unreadMessage = {
        getBoundingClientRect: () => ({ top: 350, bottom: 430, height: 80 }),
      };
      const panel = buildPanel({ unreadMessage });
      const context = {
        conversationPanel: panel,
        unreadMessageCount: 2,
        isProgrammaticScroll: false,
      };

      expect(MessagesView.methods.scrollToBottom.call(context)).toBe(true);
      expect(panel.querySelector).toHaveBeenCalledWith('.message--unread');
      expect(panel.scrollTop).toBe(526);
      expect(context.isProgrammaticScroll).toBe(true);
    });

    it('scrolls to newest mounted content but refuses read-marking if unread DOM is missing', () => {
      const panel = buildPanel();
      const context = {
        conversationPanel: panel,
        unreadMessageCount: 2,
        isProgrammaticScroll: false,
      };

      expect(MessagesView.methods.scrollToBottom.call(context)).toBe(false);
      expect(panel.scrollTop).toBe(1500);
      expect(context.isProgrammaticScroll).toBe(true);
    });

    it('scrolls to the bottom when there are no unread messages', () => {
      const panel = buildPanel();
      const context = {
        conversationPanel: panel,
        unreadMessageCount: 0,
        isProgrammaticScroll: false,
      };

      expect(MessagesView.methods.scrollToBottom.call(context)).toBe(true);
      expect(panel.scrollTop).toBe(1500);
    });
  });

  describe('unReadMessages', () => {
    it('only treats public incoming direct-conversation messages as unread', () => {
      const context = {
        currentChat: { agent_last_seen_at: 100 },
        getMessages: [
          { id: 1, message_type: 2, private: false, created_at: 120 },
          { id: 2, message_type: 1, private: false, created_at: 120 },
          { id: 3, message_type: 0, private: true, created_at: 120 },
          { id: 4, message_type: 0, private: false, created_at: 90 },
          { id: 5, message_type: 0, private: false, created_at: 120 },
        ],
      };

      expect(MessagesView.computed.unReadMessages.call(context)).toEqual([
        context.getMessages[4],
      ]);
    });

    it('uses per-channel last seen values for communication threads', () => {
      const context = {
        currentChat: {
          is_communication_thread: true,
          channels: [
            { conversation_id: 11, agent_last_seen_at: 100 },
            { conversation_id: 12, agent_last_seen_at: 200 },
          ],
        },
        getMessages: [
          {
            id: 1,
            conversation_id: 11,
            message_type: 2,
            private: false,
            created_at: 120,
          },
          {
            id: 2,
            conversation_id: 11,
            message_type: 0,
            private: false,
            created_at: 120,
          },
          {
            id: 3,
            conversation_id: 12,
            message_type: 0,
            private: false,
            created_at: 150,
          },
        ],
      };
      context.communicationThreadLastSeenByConversationId =
        MessagesView.computed.communicationThreadLastSeenByConversationId.call(
          context
        );
      context.communicationThreadMessageLastSeenAt = message =>
        MessagesView.methods.communicationThreadMessageLastSeenAt.call(
          context,
          message
        );
      context.isUnreadCommunicationThreadMessage = message =>
        MessagesView.methods.isUnreadCommunicationThreadMessage.call(
          context,
          message
        );

      expect(MessagesView.computed.unReadMessages.call(context)).toEqual([
        context.getMessages[1],
      ]);
    });
  });

  describe('#makeMessagesRead', () => {
    it('marks the communication thread read through the thread action', () => {
      const dispatch = vi.fn();

      MessagesView.methods.makeMessagesRead.call({
        currentChat: {
          id: 7,
          is_communication_thread: true,
          conversation_ids: [11, 12],
        },
        $store: { dispatch },
      });

      expect(dispatch).toHaveBeenCalledWith('markCommunicationThreadRead', {
        id: 7,
      });
      expect(dispatch).not.toHaveBeenCalledWith('markMessagesRead', {
        id: 11,
      });
    });

    it('marks a direct conversation read through the conversation action', () => {
      const dispatch = vi.fn();

      MessagesView.methods.makeMessagesRead.call({
        currentChat: { id: 11 },
        $store: { dispatch },
      });

      expect(dispatch).toHaveBeenCalledWith('markMessagesRead', { id: 11 });
    });
  });
});
