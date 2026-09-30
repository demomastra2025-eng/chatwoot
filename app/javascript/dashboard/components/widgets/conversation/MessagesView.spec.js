import { describe, expect, it, vi } from 'vitest';

import ConversationApi from 'dashboard/api/inbox/conversation';
import MessagesView from './MessagesView.vue';

describe('MessagesView', () => {
  describe('cancelling a Captain response', () => {
    const typingStore = typingByConversationId => ({
      getters: {
        'conversationTypingStatus/getUserList': conversationId =>
          typingByConversationId[conversationId] || [],
      },
    });
    const captainTyping = [{ id: 3, type: 'captain_assistant' }];
    const agentTyping = [{ id: 9, type: 'user' }];

    it('targets the channel conversation where Captain types, not the thread id', () => {
      expect(
        MessagesView.computed.captainResponseConversationId.call({
          currentChat: {
            id: 7,
            is_communication_thread: true,
            conversation_ids: [11, 22],
            channels: [{ conversation_id: 11 }, { conversation_id: 22 }],
          },
          $store: typingStore({
            7: captainTyping,
            11: agentTyping,
            22: captainTyping,
          }),
        })
      ).toBe(22);
    });

    it('also finds the channel conversation from the thread channels', () => {
      expect(
        MessagesView.computed.captainResponseConversationId.call({
          currentChat: {
            id: 7,
            is_communication_thread: true,
            channels: [{ conversation_id: 31 }, { conversation_id: 32 }],
          },
          $store: typingStore({ 31: captainTyping }),
        })
      ).toBe(31);
    });

    it('has no target when Captain types in none of the thread channels', () => {
      expect(
        MessagesView.computed.captainResponseConversationId.call({
          currentChat: {
            id: 7,
            is_communication_thread: true,
            conversation_ids: [11],
          },
          $store: typingStore({ 7: captainTyping, 11: agentTyping }),
        })
      ).toBeUndefined();
    });

    it('targets the open conversation outside a thread', () => {
      expect(
        MessagesView.computed.captainResponseConversationId.call({
          currentChat: { id: 987, communication_thread_id: 321 },
          $store: typingStore({}),
        })
      ).toBe(987);
    });

    it('sends the channel conversation id to the cancel endpoint', async () => {
      const cancel = vi
        .spyOn(ConversationApi, 'cancelCaptainResponse')
        .mockResolvedValue({});
      const context = {
        captainResponseConversationId: 22,
        currentChat: { id: 7, is_communication_thread: true },
        isCancellingCaptainResponse: false,
      };

      await MessagesView.methods.cancelCaptainResponse.call(context);

      expect(cancel).toHaveBeenCalledTimes(1);
      expect(cancel).toHaveBeenCalledWith({ conversationId: 22 });
      expect(context.isCancellingCaptainResponse).toBe(false);
      cancel.mockRestore();
    });

    it('does not call the endpoint without a channel conversation', async () => {
      const cancel = vi
        .spyOn(ConversationApi, 'cancelCaptainResponse')
        .mockResolvedValue({});

      await MessagesView.methods.cancelCaptainResponse.call({
        captainResponseConversationId: undefined,
        currentChat: { id: 7, is_communication_thread: true },
        isCancellingCaptainResponse: false,
      });

      expect(cancel).not.toHaveBeenCalled();
      cancel.mockRestore();
    });
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
      currentChat: { id: 7, dataFetched: true },
      fetchPreviousMessages: vi.fn(),
      isNearConversationBottom: vi.fn(() => false),
      makeMessagesRead: vi.fn(),
      scrollToBottom: vi.fn(),
      preserveOpenedUnreadMessages: vi.fn(),
      hideUnreadJumpWhenVisible: vi.fn(),
      hasUserScrolled: true,
      ...overrides,
    });

    it('does not force-scroll or mark read when the agent is reading older history', () => {
      const context = buildContext();

      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.scrollToBottom).not.toHaveBeenCalled();
      expect(context.makeMessagesRead).not.toHaveBeenCalled();
      expect(context.preserveOpenedUnreadMessages).not.toHaveBeenCalled();
    });

    it('snapshots the unread state before opening at the newest message and marking it read', () => {
      const calls = [];
      const context = buildContext({
        hasUserScrolled: false,
        preserveOpenedUnreadMessages: vi.fn(() => calls.push('preserve')),
        scrollToBottom: vi.fn(() => calls.push('scroll')),
        makeMessagesRead: vi.fn(() => calls.push('read')),
      });

      MessagesView.methods.onScrollToMessage.call(context);

      expect(calls).toEqual(['preserve', 'scroll', 'read']);
      expect(context.hideUnreadJumpWhenVisible).toHaveBeenCalled();
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

    it('marks messages read when a stale unread count has no mounted message', () => {
      const context = buildContext({
        isNearConversationBottom: vi.fn(() => true),
        scrollToBottom: vi.fn(() => false),
      });

      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.scrollToBottom).toHaveBeenCalled();
      expect(context.makeMessagesRead).toHaveBeenCalled();
    });

    it('does not mark read while the newest page of the opened chat is loading', () => {
      const context = buildContext({
        hasUserScrolled: false,
        currentChat: { id: 7, is_communication_thread: true },
      });

      // e.g. a delivery receipt for the open thread during setActiveChat
      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.scrollToBottom).toHaveBeenCalled();
      expect(context.makeMessagesRead).not.toHaveBeenCalled();
    });
  });

  describe('unread snapshot while the newest page loads', () => {
    const openedContext = () => {
      const context = {
        $nextTick: callback => callback(),
        currentChat: {
          id: 7,
          is_communication_thread: true,
          unread_count: 6,
          meta: {},
          messages: [{ id: 150 }],
        },
        getMessages: [{ id: 150 }],
        unreadMessageIds: [150],
        unreadMessageCount: 6,
        hasUserScrolled: false,
        hasOpenedUnreadSnapshot: false,
        openedUnreadMessageIds: [],
        openedUnreadMessageCount: 0,
        openedFirstUnreadMessageId: null,
        showUnreadJumpButton: false,
        isNearConversationBottom: () => true,
        scrollToBottom: vi.fn(),
        makeMessagesRead: vi.fn(),
        hideUnreadJumpWhenVisible: vi.fn(),
      };
      context.openedFirstUnreadCandidate = () =>
        MessagesView.methods.openedFirstUnreadCandidate.call(context);
      context.preserveOpenedUnreadMessages = () =>
        MessagesView.methods.preserveOpenedUnreadMessages.call(context);
      return context;
    };

    it('takes the snapshot from the loaded page, not from an early realtime event', () => {
      const context = openedContext();

      // realtime event while only the list preview message is known
      MessagesView.methods.onScrollToMessage.call(context);
      expect(context.hasOpenedUnreadSnapshot).toBe(false);
      expect(context.showUnreadJumpButton).toBe(false);
      expect(context.makeMessagesRead).not.toHaveBeenCalled();

      // setActiveChat finished: newest page and server cursor are loaded
      const page = [145, 146, 147, 148, 149, 150].map(id => ({ id }));
      context.currentChat = {
        ...context.currentChat,
        dataFetched: true,
        meta: { first_unread_message_id: 145 },
        messages: page,
      };
      context.getMessages = page;
      context.unreadMessageIds = page.map(({ id }) => id);
      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.openedFirstUnreadMessageId).toBe(145);
      expect(context.openedUnreadMessageIds).toEqual([
        145, 146, 147, 148, 149, 150,
      ]);
      expect(context.openedUnreadMessageCount).toBe(6);
      expect(context.showUnreadJumpButton).toBe(true);
      expect(context.makeMessagesRead).toHaveBeenCalledTimes(1);
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
      expect(panel.querySelector).not.toHaveBeenCalledWith('.message--unread');
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
    const snapshotContext = overrides => {
      const context = {
        currentChat: { dataFetched: true, meta: {} },
        getMessages: [],
        unreadMessageIds: [],
        unreadMessageCount: 0,
        hasOpenedUnreadSnapshot: false,
        openedUnreadMessageIds: [],
        openedUnreadMessageCount: 0,
        openedFirstUnreadMessageId: null,
        showUnreadJumpButton: false,
        ...overrides,
      };
      context.openedFirstUnreadCandidate = () =>
        MessagesView.methods.openedFirstUnreadCandidate.call(context);
      return context;
    };

    it('preserves the unread marker before the read state is cleared', () => {
      const context = snapshotContext({
        getMessages: [{ id: 101 }, { id: 102 }],
        unreadMessageIds: [101, 102],
        unreadMessageCount: 2,
      });

      MessagesView.methods.preserveOpenedUnreadMessages.call(context);

      expect(context.openedUnreadMessageIds).toEqual([101, 102]);
      expect(context.openedFirstUnreadMessageId).toBe(101);
      expect(context.openedUnreadMessageCount).toBe(2);
      expect(context.showUnreadJumpButton).toBe(true);
    });

    it('uses the server cursor when the first unread is outside the loaded page', () => {
      const context = snapshotContext({
        currentChat: {
          dataFetched: true,
          meta: { first_unread_message_id: 77 },
        },
        getMessages: [{ id: 101 }],
        unreadMessageIds: [101],
        unreadMessageCount: 3,
      });

      MessagesView.methods.preserveOpenedUnreadMessages.call(context);

      expect(context.openedUnreadMessageIds).toEqual([77, 101]);
      expect(context.openedFirstUnreadMessageId).toBe(77);
      expect(context.openedUnreadMessageCount).toBe(3);
      expect(context.showUnreadJumpButton).toBe(true);
    });

    it('ignores a stale cursor that points to an already read loaded message', () => {
      const context = snapshotContext({
        currentChat: {
          dataFetched: true,
          meta: { first_unread_message_id: 90 },
        },
        getMessages: [{ id: 90 }, { id: 150 }],
        unreadMessageIds: [150],
        unreadMessageCount: 1,
      });

      MessagesView.methods.preserveOpenedUnreadMessages.call(context);

      expect(context.openedFirstUnreadMessageId).toBe(150);
      expect(context.openedUnreadMessageIds).toEqual([150]);
    });

    it('does not snapshot messages that arrive after the conversation was opened', () => {
      const context = snapshotContext({
        getMessages: [{ id: 150 }],
        unreadMessageIds: [],
        unreadMessageCount: 0,
      });

      MessagesView.methods.preserveOpenedUnreadMessages.call(context);
      context.unreadMessageIds = [150];
      context.unreadMessageCount = 1;
      MessagesView.methods.preserveOpenedUnreadMessages.call(context);

      expect(context.openedUnreadMessageIds).toEqual([]);
      expect(context.showUnreadJumpButton).toBe(false);
    });

    it('resets the snapshot when another conversation is opened', () => {
      const context = snapshotContext({
        hasOpenedUnreadSnapshot: true,
        openedUnreadMessageIds: [1],
        openedUnreadMessageCount: 1,
        openedFirstUnreadMessageId: 1,
        showUnreadJumpButton: true,
        isLoadingOpenedUnread: true,
      });

      MessagesView.methods.resetOpenedUnreadMessages.call(context);

      expect(context).toMatchObject({
        hasOpenedUnreadSnapshot: false,
        openedUnreadMessageIds: [],
        openedUnreadMessageCount: 0,
        openedFirstUnreadMessageId: null,
        showUnreadJumpButton: false,
        isLoadingOpenedUnread: false,
      });
    });

    const visibleUnread = context => {
      const withComputed = {
        ...context,
        unreadMessageIdsAfterOpen:
          MessagesView.computed.unreadMessageIdsAfterOpen.call(context),
      };
      return {
        ids: MessagesView.computed.visibleUnreadMessageIds.call(withComputed),
        count:
          MessagesView.computed.visibleUnreadMessageCount.call(withComputed),
      };
    };

    it('keeps the unread divider and count after the thread is marked read', () => {
      expect(
        visibleUnread({
          openedUnreadMessageIds: [101, 102],
          openedUnreadMessageCount: 2,
          unreadMessageIds: [],
          unreadMessageCount: 0,
        })
      ).toEqual({ ids: [101, 102], count: 2 });
    });

    it('adds messages that arrive while the agent is scrolled up to the opened unread', () => {
      // opened with 3 unread and marked read; 2 new incoming messages are
      // not read in place because the agent reads older history
      expect(
        visibleUnread({
          openedUnreadMessageIds: [101, 102, 103],
          openedUnreadMessageCount: 3,
          unreadMessageIds: [201, 202],
          unreadMessageCount: 2,
        })
      ).toEqual({ ids: [101, 102, 103, 201, 202], count: 5 });
    });

    it('does not count opened messages twice before the read state is updated', () => {
      expect(
        visibleUnread({
          openedUnreadMessageIds: [77, 101, 102],
          openedUnreadMessageCount: 4,
          unreadMessageIds: [101, 102, 201],
          unreadMessageCount: 5,
        })
      ).toEqual({ ids: [77, 101, 102, 201], count: 5 });
    });

    it('uses the live unread state when nothing was unread on open', () => {
      expect(
        visibleUnread({
          openedUnreadMessageIds: [],
          openedUnreadMessageCount: 0,
          unreadMessageIds: [201],
          unreadMessageCount: 1,
        })
      ).toEqual({ ids: [201], count: 1 });
    });

    it('hides the jump button when the first unread message is already visible', () => {
      const context = {
        showUnreadJumpButton: true,
        openedFirstUnreadMessageId: 101,
        conversationPanel: {
          getBoundingClientRect: () => ({ top: 100, bottom: 600 }),
          querySelector: vi.fn(() => ({
            getBoundingClientRect: () => ({ top: 350, bottom: 430 }),
          })),
        },
      };
      context.openedFirstUnreadElement = () =>
        MessagesView.methods.openedFirstUnreadElement.call(context);

      MessagesView.methods.hideUnreadJumpWhenVisible.call(context);

      expect(context.conversationPanel.querySelector).toHaveBeenCalledWith(
        '#message101'
      );
      expect(context.showUnreadJumpButton).toBe(false);
    });

    it('keeps the jump button while the first unread message is above the viewport', () => {
      const context = {
        showUnreadJumpButton: true,
        openedFirstUnreadMessageId: 101,
        conversationPanel: {
          getBoundingClientRect: () => ({ top: 100, bottom: 600 }),
          querySelector: vi.fn(() => ({
            getBoundingClientRect: () => ({ top: -900, bottom: -820 }),
          })),
        },
      };
      context.openedFirstUnreadElement = () =>
        MessagesView.methods.openedFirstUnreadElement.call(context);

      MessagesView.methods.hideUnreadJumpWhenVisible.call(context);

      expect(context.showUnreadJumpButton).toBe(true);
    });

    it('moves to the preserved unread marker only after an explicit click', async () => {
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
      const dispatch = vi.fn();
      const context = {
        openedFirstUnreadMessageId: 101,
        visibleUnreadMessageIds: [101],
        conversationPanel: panel,
        isProgrammaticScroll: false,
        isLoadingOpenedUnread: false,
        showUnreadJumpButton: true,
        $store: { dispatch },
      };

      await MessagesView.methods.scrollToFirstOpenedUnread.call(context);

      expect(panel.querySelector).toHaveBeenCalledWith('#message101');
      expect(dispatch).not.toHaveBeenCalled();
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

    it('keeps the jump button when the unread range cannot be loaded', async () => {
      const panel = {
        getBoundingClientRect: () => ({ top: 100, bottom: 600 }),
        querySelector: vi.fn(() => null),
      };
      const context = {
        openedFirstUnreadMessageId: 101,
        visibleUnreadMessageIds: [],
        currentChat: { id: 11, messages: [{ id: 300 }] },
        conversationPanel: panel,
        isProgrammaticScroll: false,
        isLoadingOpenedUnread: false,
        showUnreadJumpButton: true,
        $store: { dispatch: vi.fn().mockResolvedValue() },
        $nextTick: callback => callback(),
      };

      await MessagesView.methods.scrollToFirstOpenedUnread.call(context);

      expect(context.$store.dispatch).toHaveBeenCalledWith(
        'fetchPreviousMessages',
        expect.objectContaining({ conversationType: 'conversation' })
      );
      expect(context.showUnreadJumpButton).toBe(true);
      expect(context.isLoadingOpenedUnread).toBe(false);
    });
  });

  describe('currentChat watcher', () => {
    it('refreshes chat-scoped state when direct and thread ids collide', () => {
      const context = {
        fetchAllAttachmentsFromCurrentChat: vi.fn(),
        fetchSuggestions: vi.fn(),
        messageSentSinceOpened: true,
        resetOpenedUnreadMessages: vi.fn(),
        resetReplyEditorHeight: vi.fn(),
        conversationHistoryGeneration: 0,
        hasUserScrolled: true,
      };

      MessagesView.watch.currentChat.call(
        context,
        { id: 987, communication_thread_id: 321 },
        { id: 987 }
      );

      expect(context.fetchAllAttachmentsFromCurrentChat).toHaveBeenCalled();
      expect(context.fetchSuggestions).toHaveBeenCalled();
      expect(context.messageSentSinceOpened).toBe(false);
      expect(context.resetOpenedUnreadMessages).toHaveBeenCalled();
      expect(context.resetReplyEditorHeight).toHaveBeenCalled();
      expect(context.conversationHistoryGeneration).toBe(1);
      expect(context.hasUserScrolled).toBe(false);
    });

    it('preserves manual scroll state for updates to the active chat', () => {
      const context = {
        fetchAllAttachmentsFromCurrentChat: vi.fn(),
        fetchSuggestions: vi.fn(),
        resetReplyEditorHeight: vi.fn(),
        conversationHistoryGeneration: 0,
        hasUserScrolled: true,
      };

      MessagesView.watch.currentChat.call(
        context,
        { id: 987, is_communication_thread: true, unread_count: 1 },
        { id: 987, is_communication_thread: true, unread_count: 0 }
      );

      expect(context.hasUserScrolled).toBe(true);
      expect(context.fetchAllAttachmentsFromCurrentChat).not.toHaveBeenCalled();
      expect(context.conversationHistoryGeneration).toBe(0);
    });

    it('establishes a fresh scroll position after switching chats', () => {
      const context = {
        $nextTick: callback => callback(),
        // the chat was loaded by setActiveChat before it emits the scroll
        currentChat: {
          id: 988,
          is_communication_thread: true,
          dataFetched: true,
        },
        fetchAllAttachmentsFromCurrentChat: vi.fn(),
        fetchSuggestions: vi.fn(),
        resetOpenedUnreadMessages: vi.fn(),
        resetReplyEditorHeight: vi.fn(),
        fetchPreviousMessages: vi.fn(),
        isNearConversationBottom: vi.fn(() => false),
        preserveOpenedUnreadMessages: vi.fn(),
        hideUnreadJumpWhenVisible: vi.fn(),
        scrollToBottom: vi.fn(),
        makeMessagesRead: vi.fn(),
        conversationHistoryGeneration: 0,
        hasUserScrolled: true,
      };

      MessagesView.watch.currentChat.call(
        context,
        { id: 988, is_communication_thread: true },
        { id: 987, is_communication_thread: true }
      );
      MessagesView.methods.onScrollToMessage.call(context);

      expect(context.hasUserScrolled).toBe(false);
      expect(context.resetOpenedUnreadMessages).toHaveBeenCalledOnce();
      expect(context.preserveOpenedUnreadMessages).toHaveBeenCalledOnce();
      expect(context.scrollToBottom).toHaveBeenCalledOnce();
      expect(context.makeMessagesRead).toHaveBeenCalledOnce();
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
        isImportedHistoryMessage: MessagesView.methods.isImportedHistoryMessage,
        getMessages: [
          { id: 1, message_type: 2, private: false, created_at: 120 },
          { id: 2, message_type: 1, private: false, created_at: 120 },
          { id: 3, message_type: 0, private: true, created_at: 120 },
          { id: 4, message_type: 0, private: false, created_at: 90 },
          { id: 5, message_type: 0, private: false, created_at: 120 },
          {
            id: 6,
            message_type: 0,
            private: false,
            created_at: 120,
            content_attributes: { imported_history: true },
          },
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
          {
            id: 4,
            conversation_id: 12,
            message_type: 0,
            private: false,
            created_at: 250,
            content_attributes: { imported_history: true },
          },
        ],
      };
      context.isImportedHistoryMessage =
        MessagesView.methods.isImportedHistoryMessage;
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
