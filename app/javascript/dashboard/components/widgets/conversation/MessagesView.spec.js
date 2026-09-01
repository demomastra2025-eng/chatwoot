import { describe, expect, it, vi } from 'vitest';

import MessagesView from './MessagesView.vue';

describe('MessagesView', () => {
  it('targets the typing child conversation when cancelling a thread Captain response', () => {
    const getTypingUsers = conversationId =>
      conversationId === 22 ? [{ type: 'captain_assistant' }] : [];

    expect(
      MessagesView.computed.captainResponseConversationId.call({
        currentChat: {
          id: 7,
          is_communication_thread: true,
          channels: [{ conversation_id: 11 }, { conversation_id: 22 }],
        },
        $store: {
          getters: {
            'conversationTypingStatus/getUserList': getTypingUsers,
          },
        },
      })
    ).toBe(22);
  });

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
      preserveOpenedUnreadMessages: vi.fn(),
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

    it('marks messages read after opening at the newest mounted message', () => {
      const context = buildContext({
        isNearConversationBottom: vi.fn(() => true),
        scrollToBottom: vi.fn(() => false),
      });

      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.scrollToBottom).toHaveBeenCalled();
      expect(context.makeMessagesRead).toHaveBeenCalled();
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

    it('opens at the newest message even when unread messages are mounted', () => {
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
      expect(panel.scrollTop).toBe(1500);
      expect(context.isProgrammaticScroll).toBe(true);
    });

    it('opens at the newest message when unread DOM is not mounted', () => {
      const panel = buildPanel();
      const context = {
        conversationPanel: panel,
        unreadMessageCount: 2,
        isProgrammaticScroll: false,
      };

      expect(MessagesView.methods.scrollToBottom.call(context)).toBe(true);
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

  describe('opened unread navigation', () => {
    it('preserves the unread marker before the read state is cleared', () => {
      const context = {
        unreadMessageIds: [101, 102],
        unreadMessageCount: 2,
        openedUnreadMessageIds: [],
        openedUnreadMessageCount: 0,
        showUnreadJumpButton: false,
      };

      MessagesView.methods.preserveOpenedUnreadMessages.call(context);

      expect(context.openedUnreadMessageIds).toEqual([101, 102]);
      expect(context.openedFirstUnreadMessageId).toBe(101);
      expect(context.openedUnreadMessageCount).toBe(2);
      expect(context.showUnreadJumpButton).toBe(true);
    });

    it('preserves an unread target that is outside the latest loaded page', () => {
      const context = {
        currentChat: { meta: { first_unread_message_id: 77 } },
        unreadMessageIds: [101],
        unreadMessageCount: 3,
        openedUnreadMessageIds: [],
        openedUnreadMessageCount: 0,
        openedFirstUnreadMessageId: null,
        showUnreadJumpButton: false,
      };

      MessagesView.methods.preserveOpenedUnreadMessages.call(context);

      expect(context.openedUnreadMessageIds).toEqual([77, 101]);
      expect(context.openedFirstUnreadMessageId).toBe(77);
      expect(context.openedUnreadMessageCount).toBe(3);
      expect(context.showUnreadJumpButton).toBe(true);
    });

    it('moves to the preserved unread marker only after an explicit click', () => {
      const unreadMessage = {
        getBoundingClientRect: () => ({ top: 350, bottom: 430, height: 80 }),
      };
      const panel = {
        scrollHeight: 3000,
        clientHeight: 500,
        scrollTop: 1500,
        getBoundingClientRect: () => ({ top: 100, bottom: 600 }),
        querySelector: vi.fn(() => unreadMessage),
      };
      const context = {
        visibleUnreadMessageIds: [101],
        conversationPanel: panel,
        isProgrammaticScroll: false,
        showUnreadJumpButton: true,
      };

      MessagesView.methods.scrollToFirstOpenedUnread.call(context);

      expect(panel.querySelector).toHaveBeenCalledWith('#message101');
      expect(panel.scrollTop).toBe(1726);
      expect(context.isProgrammaticScroll).toBe(true);
      expect(context.showUnreadJumpButton).toBe(false);
    });

    it('loads the unread range only after an explicit click', async () => {
      const unreadMessage = {
        getBoundingClientRect: () => ({ top: 350, bottom: 430, height: 80 }),
      };
      const panel = {
        scrollHeight: 3000,
        clientHeight: 500,
        scrollTop: 1500,
        getBoundingClientRect: () => ({ top: 100, bottom: 600 }),
        querySelector: vi
          .fn()
          .mockReturnValueOnce(null)
          .mockReturnValueOnce(unreadMessage),
      };
      const dispatch = vi.fn().mockResolvedValue();
      const context = {
        openedFirstUnreadMessageId: 101,
        visibleUnreadMessageIds: [],
        currentChat: {
          id: 7,
          is_communication_thread: true,
          messages: [{ id: 300 }],
        },
        conversationPanel: panel,
        isProgrammaticScroll: false,
        isLoadingOpenedUnread: false,
        showUnreadJumpButton: true,
        $store: { dispatch },
        $nextTick: callback => callback(),
      };

      await MessagesView.methods.scrollToFirstOpenedUnread.call(context);

      expect(dispatch).toHaveBeenCalledWith('fetchPreviousMessages', {
        conversationId: 7,
        conversationType: 'communication_thread',
        after: 101,
        before: 300,
      });
      expect(panel.scrollTop).toBe(1726);
      expect(context.showUnreadJumpButton).toBe(false);
      expect(context.isLoadingOpenedUnread).toBe(false);
    });
  });

  describe('currentChat watcher', () => {
    it('refreshes chat-scoped state when direct and thread ids collide', () => {
      const context = {
        fetchSuggestions: vi.fn(),
        messageSentSinceOpened: true,
        resetReplyEditorHeight: vi.fn(),
        conversationHistoryGeneration: 0,
      };

      MessagesView.watch.currentChat.call(
        context,
        { id: 987, communication_thread_id: 321 },
        { id: 987 }
      );

      expect(context.fetchSuggestions).toHaveBeenCalled();
      expect(context.messageSentSinceOpened).toBe(false);
      expect(context.resetReplyEditorHeight).toHaveBeenCalled();
      expect(context.conversationHistoryGeneration).toBe(1);
    });
  });

  describe('#fetchPreviousMessages', () => {
    it('loads the previous page and preserves the visible scroll anchor', async () => {
      const conversationPanel = {
        scrollHeight: 1000,
        scrollTop: 40,
      };
      const dispatch = vi.fn(async () => {
        conversationPanel.scrollHeight = 1450;
      });
      const context = {
        conversationPanel,
        currentChat: {
          id: 987,
          dataFetched: true,
          messages: [{ id: 101 }, { id: 102 }],
        },
        listLoadingStatus: false,
        isLoadingPrevious: false,
        heightBeforeLoad: null,
        scrollTopBeforeLoad: null,
        $store: { dispatch },
        $nextTick: vi.fn(callback => {
          callback();
          return Promise.resolve();
        }),
        setScrollParams() {
          MessagesView.methods.setScrollParams.call(this);
        },
      };

      await MessagesView.methods.fetchPreviousMessages.call(context, 40);

      expect(dispatch).toHaveBeenCalledWith('fetchPreviousMessages', {
        conversationId: 987,
        before: 101,
      });
      expect(context.$nextTick).toHaveBeenCalled();
      expect(conversationPanel.scrollTop).toBe(490);
      expect(context.isLoadingPrevious).toBe(false);
    });

    it('ignores duplicate observer callbacks while a history page is pending', async () => {
      const conversationPanel = {
        scrollHeight: 1000,
        scrollTop: 40,
      };
      let resolveRequest;
      const dispatch = vi.fn(
        () =>
          new Promise(resolve => {
            resolveRequest = () => {
              conversationPanel.scrollHeight = 1450;
              resolve();
            };
          })
      );
      const context = {
        conversationPanel,
        currentChat: {
          id: 987,
          dataFetched: true,
          messages: [{ id: 101 }],
        },
        listLoadingStatus: false,
        isLoadingPrevious: false,
        heightBeforeLoad: null,
        scrollTopBeforeLoad: null,
        $store: { dispatch },
        $nextTick: vi.fn(callback => callback()),
        setScrollParams() {
          MessagesView.methods.setScrollParams.call(this);
        },
      };

      const pendingRequest = MessagesView.methods.fetchPreviousMessages.call(
        context,
        40
      );
      conversationPanel.scrollHeight = 1100;
      conversationPanel.scrollTop = 10;

      await MessagesView.methods.fetchPreviousMessages.call(context, 10);

      expect(dispatch).toHaveBeenCalledTimes(1);
      expect(context.heightBeforeLoad).toBe(1000);
      expect(context.scrollTopBeforeLoad).toBe(40);

      resolveRequest();
      await pendingRequest;

      expect(conversationPanel.scrollTop).toBe(490);
      expect(context.isLoadingPrevious).toBe(false);
    });

    it('does not adjust a thread with the same id after a direct history request resolves', async () => {
      const conversationPanel = {
        scrollHeight: 1000,
        scrollTop: 40,
      };
      let context;
      const dispatch = vi.fn(async () => {
        context.currentChat = {
          id: 987,
          communication_thread_id: 321,
          dataFetched: true,
          messages: [{ id: 201 }],
        };
        conversationPanel.scrollHeight = 1450;
      });
      context = {
        conversationPanel,
        currentChat: {
          id: 987,
          dataFetched: true,
          messages: [{ id: 101 }],
        },
        listLoadingStatus: false,
        isLoadingPrevious: false,
        heightBeforeLoad: null,
        scrollTopBeforeLoad: null,
        $store: { dispatch },
        $nextTick: vi.fn(),
        setScrollParams() {
          MessagesView.methods.setScrollParams.call(this);
        },
      };

      await MessagesView.methods.fetchPreviousMessages.call(context, 40);

      expect(dispatch).toHaveBeenCalledWith('fetchPreviousMessages', {
        conversationId: 987,
        before: 101,
      });
      expect(context.$nextTick).not.toHaveBeenCalled();
      expect(conversationPanel.scrollTop).toBe(40);
      expect(context.isLoadingPrevious).toBe(false);
    });

    it('stops an in-flight history request after unmount invalidation', async () => {
      const conversationPanel = {
        scrollHeight: 1000,
        scrollTop: 40,
      };
      let context;
      const dispatch = vi.fn(async () => {
        context.conversationHistoryGeneration += 1;
        conversationPanel.scrollHeight = 1450;
      });
      context = {
        conversationPanel,
        currentChat: {
          id: 987,
          dataFetched: true,
          messages: [{ id: 101 }],
        },
        listLoadingStatus: false,
        isLoadingPrevious: false,
        heightBeforeLoad: null,
        scrollTopBeforeLoad: null,
        conversationHistoryGeneration: 0,
        $store: { dispatch },
        $nextTick: vi.fn(),
        setScrollParams() {
          MessagesView.methods.setScrollParams.call(this);
        },
      };

      await MessagesView.methods.fetchPreviousMessages.call(context, 40);

      expect(context.$nextTick).not.toHaveBeenCalled();
      expect(conversationPanel.scrollTop).toBe(40);
      expect(context.isLoadingPrevious).toBe(false);
    });

    it('rechecks the active chat inside the next tick callback', async () => {
      const conversationPanel = {
        scrollHeight: 1000,
        scrollTop: 40,
      };
      const dispatch = vi.fn(async () => {
        conversationPanel.scrollHeight = 1450;
      });
      const context = {
        conversationPanel,
        currentChat: {
          id: 987,
          dataFetched: true,
          messages: [{ id: 101 }],
        },
        listLoadingStatus: false,
        isLoadingPrevious: false,
        heightBeforeLoad: null,
        scrollTopBeforeLoad: null,
        $store: { dispatch },
        $nextTick: vi.fn(callback => {
          context.currentChat = {
            id: 110,
            dataFetched: true,
            messages: [{ id: 201 }],
          };
          callback();
        }),
        setScrollParams() {
          MessagesView.methods.setScrollParams.call(this);
        },
      };

      await MessagesView.methods.fetchPreviousMessages.call(context, 40);

      expect(context.$nextTick).toHaveBeenCalled();
      expect(conversationPanel.scrollTop).toBe(40);
      expect(context.isLoadingPrevious).toBe(false);
    });

    it('does not request history after all messages are loaded', async () => {
      const dispatch = vi.fn();
      const context = {
        conversationPanel: { scrollHeight: 1000, scrollTop: 0 },
        currentChat: {
          id: 110,
          dataFetched: true,
          messages: [{ id: 201 }],
        },
        listLoadingStatus: true,
        isLoadingPrevious: false,
        $store: { dispatch },
        setScrollParams: vi.fn(),
      };

      await MessagesView.methods.fetchPreviousMessages.call(context, 0);

      expect(dispatch).not.toHaveBeenCalled();
    });

    it('keeps loading until the history fills the viewport', async () => {
      const conversationPanel = {
        scrollHeight: 400,
        clientHeight: 500,
        scrollTop: 0,
      };
      const currentChat = {
        id: 987,
        dataFetched: true,
        messages: [{ id: 101 }],
      };
      const dispatch = vi.fn().mockImplementationOnce(async () => {
        currentChat.messages.unshift({ id: 91 });
        conversationPanel.scrollHeight = 450;
      });
      dispatch.mockImplementationOnce(async () => {
        currentChat.messages.unshift({ id: 81 });
        conversationPanel.scrollHeight = 650;
      });
      const context = {
        conversationPanel,
        currentChat,
        listLoadingStatus: false,
        isLoadingPrevious: false,
        heightBeforeLoad: null,
        scrollTopBeforeLoad: null,
        $store: { dispatch },
        $nextTick: vi.fn(callback => {
          callback();
          return Promise.resolve();
        }),
        setScrollParams() {
          MessagesView.methods.setScrollParams.call(this);
        },
        fetchPreviousMessages(scrollTop) {
          return MessagesView.methods.fetchPreviousMessages.call(
            this,
            scrollTop
          );
        },
      };

      await MessagesView.methods.fetchPreviousMessages.call(context, 0);

      expect(dispatch).toHaveBeenNthCalledWith(1, 'fetchPreviousMessages', {
        conversationId: 987,
        before: 101,
      });
      expect(dispatch).toHaveBeenNthCalledWith(2, 'fetchPreviousMessages', {
        conversationId: 987,
        before: 91,
      });
    });
  });

  describe('#canObservePreviousMessages', () => {
    it('observes the top sentinel while older messages can be loaded', () => {
      expect(
        MessagesView.computed.canObservePreviousMessages.call({
          conversationPanel: {},
          currentChat: { dataFetched: true, messages: [{ id: 1 }] },
          listLoadingStatus: false,
        })
      ).toBe(true);
    });

    it('stops observing after reaching the beginning of history', () => {
      expect(
        MessagesView.computed.canObservePreviousMessages.call({
          conversationPanel: {},
          currentChat: { dataFetched: true, messages: [{ id: 1 }] },
          listLoadingStatus: true,
        })
      ).toBe(false);
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
