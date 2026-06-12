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
