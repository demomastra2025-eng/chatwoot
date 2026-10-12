import AudioNotificationStore from '../AudioNotificationStore';
import {
  ROLES,
  CONVERSATION_PERMISSIONS,
} from 'dashboard/constants/permissions';
import { getUserPermissions } from 'dashboard/helper/permissionsHelper';
import wootConstants from 'dashboard/constants/globals';

vi.mock('dashboard/helper/permissionsHelper', () => ({
  getUserPermissions: vi.fn(),
}));

describe('AudioNotificationStore', () => {
  let store;
  let audioNotificationStore;

  beforeEach(() => {
    store = {
      getters: {
        getMineChats: vi.fn(),
        getSelectedChat: null,
        getCurrentAccountId: 1,
        getConversationById: vi.fn(),
      },
    };
    audioNotificationStore = new AudioNotificationStore(store);
  });

  describe('hasUnreadConversation', () => {
    it('should return true when there are unread conversations', () => {
      store.getters.getMineChats.mockReturnValue([
        { id: 1, unread_count: 2 },
        { id: 2, unread_count: 0 },
      ]);

      expect(audioNotificationStore.hasUnreadConversation()).toBe(true);
    });

    it('should return false when there are no unread conversations', () => {
      store.getters.getMineChats.mockReturnValue([
        { id: 1, unread_count: 0 },
        { id: 2, unread_count: 0 },
      ]);

      expect(audioNotificationStore.hasUnreadConversation()).toBe(false);
    });

    it('should return false when there are no conversations', () => {
      store.getters.getMineChats.mockReturnValue([]);

      expect(audioNotificationStore.hasUnreadConversation()).toBe(false);
    });

    it('should call getMineChats with correct parameters', () => {
      store.getters.getMineChats.mockReturnValue([]);
      audioNotificationStore.hasUnreadConversation();

      expect(store.getters.getMineChats).toHaveBeenCalledWith({
        assigneeType: 'me',
        status: 'open',
      });
    });
  });

  describe('isMessageFromPendingConversation', () => {
    it('should return true when conversation status is pending', () => {
      store.getters.getConversationById.mockReturnValue({
        id: 123,
        status: wootConstants.STATUS_TYPE.PENDING,
      });
      const message = { conversation_id: 123 };

      expect(
        audioNotificationStore.isMessageFromPendingConversation(message)
      ).toBe(true);
      expect(store.getters.getConversationById).toHaveBeenCalledWith(
        123,
        'conversation'
      );
    });

    it('should return false when conversation status is not pending', () => {
      store.getters.getConversationById.mockReturnValue({
        id: 123,
        status: wootConstants.STATUS_TYPE.OPEN,
      });
      const message = { conversation_id: 123 };

      expect(
        audioNotificationStore.isMessageFromPendingConversation(message)
      ).toBe(false);
      expect(store.getters.getConversationById).toHaveBeenCalledWith(
        123,
        'conversation'
      );
    });

    it('should return false when conversation is not found', () => {
      store.getters.getConversationById.mockReturnValue(null);
      const message = { conversation_id: 123 };

      expect(
        audioNotificationStore.isMessageFromPendingConversation(message)
      ).toBe(false);
      expect(store.getters.getConversationById).toHaveBeenCalledWith(
        123,
        'conversation'
      );
    });

    it('should return false when message has no conversation_id', () => {
      const message = {};

      expect(
        audioNotificationStore.isMessageFromPendingConversation(message)
      ).toBe(false);
      expect(store.getters.getConversationById).not.toHaveBeenCalled();
    });

    it('should return false when message is null or undefined', () => {
      expect(
        audioNotificationStore.isMessageFromPendingConversation(null)
      ).toBe(false);
      expect(
        audioNotificationStore.isMessageFromPendingConversation(undefined)
      ).toBe(false);
      expect(store.getters.getConversationById).not.toHaveBeenCalled();
    });

    describe('in communication thread mode', () => {
      const message = { conversation_id: 500, communication_thread_id: 10 };
      const buildThread = (overrides = {}) => ({
        id: 10,
        is_communication_thread: true,
        status: wootConstants.STATUS_TYPE.OPEN,
        channels: [
          { conversation_id: 500, status: wootConstants.STATUS_TYPE.PENDING },
          { conversation_id: 501, status: wootConstants.STATUS_TYPE.OPEN },
        ],
        ...overrides,
      });
      const loadThread = thread =>
        store.getters.getConversationById.mockImplementation((id, type) =>
          type === 'communication_thread' ? thread : undefined
        );

      it('uses the status of the channel the message came through', () => {
        loadThread(buildThread());

        expect(
          audioNotificationStore.isMessageFromPendingConversation(message)
        ).toBe(true);
        expect(store.getters.getConversationById).toHaveBeenCalledWith(
          10,
          'communication_thread'
        );
        expect(
          audioNotificationStore.isMessageFromPendingConversation({
            conversation_id: 501,
            communication_thread_id: 10,
          })
        ).toBe(false);
      });

      it('does not mute an open channel of a pending thread', () => {
        loadThread(
          buildThread({
            status: wootConstants.STATUS_TYPE.PENDING,
            channels: [
              { conversation_id: 500, status: wootConstants.STATUS_TYPE.OPEN },
            ],
          })
        );

        expect(
          audioNotificationStore.isMessageFromPendingConversation(message)
        ).toBe(false);
      });

      it('falls back to the thread status for an unknown channel', () => {
        loadThread(
          buildThread({
            status: wootConstants.STATUS_TYPE.PENDING,
            channels: [],
          })
        );

        expect(
          audioNotificationStore.isMessageFromPendingConversation(message)
        ).toBe(true);
      });

      describe('for a conversation created after the thread was loaded', () => {
        const loadThreadAndConversation = (thread, conversation) =>
          store.getters.getConversationById.mockImplementation((id, type) => {
            if (type === 'communication_thread') return thread;
            if (type === 'conversation') return conversation;
            return undefined;
          });

        it.each([
          ['no channel yet', []],
          ['a channel built from the message', [{ conversation_id: 500 }]],
        ])(
          'takes the pending status of the conversation record when the thread has %s',
          (_title, channels) => {
            loadThreadAndConversation(buildThread({ channels }), {
              id: 500,
              status: wootConstants.STATUS_TYPE.PENDING,
            });

            expect(
              audioNotificationStore.isMessageFromPendingConversation(message)
            ).toBe(true);
            expect(store.getters.getConversationById).toHaveBeenCalledWith(
              500,
              'conversation'
            );
          }
        );

        it('takes the open status of the conversation record over a pending thread', () => {
          loadThreadAndConversation(
            buildThread({
              status: wootConstants.STATUS_TYPE.PENDING,
              channels: [],
            }),
            { id: 500, status: wootConstants.STATUS_TYPE.OPEN }
          );

          expect(
            audioNotificationStore.isMessageFromPendingConversation(message)
          ).toBe(false);
        });

        it('prefers the status of the channel over the conversation record', () => {
          loadThreadAndConversation(buildThread(), {
            id: 500,
            status: wootConstants.STATUS_TYPE.OPEN,
          });

          expect(
            audioNotificationStore.isMessageFromPendingConversation(message)
          ).toBe(true);
        });

        it('falls back to the thread status when the record has no status', () => {
          loadThreadAndConversation(
            buildThread({
              status: wootConstants.STATUS_TYPE.PENDING,
              channels: [],
            }),
            { id: 500 }
          );

          expect(
            audioNotificationStore.isMessageFromPendingConversation(message)
          ).toBe(true);
        });
      });

      it('looks up a real conversation when the thread is not loaded', () => {
        loadThread(undefined);

        expect(
          audioNotificationStore.isMessageFromPendingConversation(message)
        ).toBe(false);
        expect(store.getters.getConversationById).toHaveBeenLastCalledWith(
          500,
          'conversation'
        );
      });
    });
  });

  describe('withVisibleAssignee', () => {
    const message = {
      conversation_id: 500,
      communication_thread_id: 10,
      conversation: { assignee_id: 2, unread_count: 1 },
    };

    it('keeps the message of a plain conversation', () => {
      const plainMessage = { conversation_id: 500, conversation: {} };

      expect(audioNotificationStore.withVisibleAssignee(plainMessage)).toBe(
        plainMessage
      );
      expect(store.getters.getConversationById).not.toHaveBeenCalled();
    });

    it('keeps the message when the thread is not loaded', () => {
      store.getters.getConversationById.mockReturnValue(undefined);

      expect(audioNotificationStore.withVisibleAssignee(message)).toBe(message);
    });

    it('takes the assignee of the thread instead of the channel one', () => {
      store.getters.getConversationById.mockReturnValue({
        id: 10,
        meta: { assignee: { id: 7 } },
      });

      expect(audioNotificationStore.withVisibleAssignee(message)).toEqual({
        ...message,
        conversation: { assignee_id: 7, unread_count: 1 },
      });
    });

    it('treats a thread without an assignee as unassigned', () => {
      store.getters.getConversationById.mockReturnValue({
        id: 10,
        meta: { assignee: null },
        assignee_id: null,
      });

      expect(
        audioNotificationStore.withVisibleAssignee(message).conversation
          .assignee_id
      ).toBeNull();
    });
  });

  describe('isMessageFromCurrentConversation', () => {
    it('should return true when message is from selected chat', () => {
      store.getters.getSelectedChat = { id: 6179 };
      const message = { conversation_id: 6179 };

      expect(
        audioNotificationStore.isMessageFromCurrentConversation(message)
      ).toBe(true);
    });

    it('should return false when message is from different chat', () => {
      store.getters.getSelectedChat = { id: 6179 };
      const message = { conversation_id: 1337 };

      expect(
        audioNotificationStore.isMessageFromCurrentConversation(message)
      ).toBe(false);
    });

    it('should return false when no chat is selected', () => {
      store.getters.getSelectedChat = null;
      const message = { conversation_id: 6179 };

      expect(
        audioNotificationStore.isMessageFromCurrentConversation(message)
      ).toBe(false);
    });

    describe('in communication thread mode', () => {
      const openThread = {
        id: 10,
        is_communication_thread: true,
        conversation_ids: [500, 501],
      };

      it('matches a message of any channel of the open thread', () => {
        store.getters.getSelectedChat = openThread;

        [500, 501].forEach(conversationId => {
          expect(
            audioNotificationStore.isMessageFromCurrentConversation({
              conversation_id: conversationId,
              communication_thread_id: 10,
            })
          ).toBe(true);
        });
      });

      it('matches by the linked conversations without a thread id', () => {
        store.getters.getSelectedChat = openThread;

        expect(
          audioNotificationStore.isMessageFromCurrentConversation({
            conversation_id: 501,
          })
        ).toBe(true);
      });

      it('does not match a message of another thread', () => {
        store.getters.getSelectedChat = openThread;

        expect(
          audioNotificationStore.isMessageFromCurrentConversation({
            conversation_id: 600,
            communication_thread_id: 11,
          })
        ).toBe(false);
      });

      it('does not mistake a thread id for a conversation id', () => {
        store.getters.getSelectedChat = { ...openThread, id: 600 };

        expect(
          audioNotificationStore.isMessageFromCurrentConversation({
            conversation_id: 600,
            communication_thread_id: 11,
          })
        ).toBe(false);
      });

      it('still matches a plain conversation opened in thread mode', () => {
        store.getters.getSelectedChat = { id: 6179 };

        expect(
          audioNotificationStore.isMessageFromCurrentConversation({
            conversation_id: 6179,
            communication_thread_id: 11,
          })
        ).toBe(true);
      });
    });
  });

  describe('hasConversationPermission', () => {
    const mockUser = { id: 'user123' };

    beforeEach(() => {
      getUserPermissions.mockReset();
    });

    it('should return true when user has a required role', () => {
      getUserPermissions.mockReturnValue([ROLES[0]]);

      expect(audioNotificationStore.hasConversationPermission(mockUser)).toBe(
        true
      );
      expect(getUserPermissions).toHaveBeenCalledWith(mockUser, 1);
    });

    it('should return true when user has a conversation permission', () => {
      getUserPermissions.mockReturnValue([CONVERSATION_PERMISSIONS[0]]);

      expect(audioNotificationStore.hasConversationPermission(mockUser)).toBe(
        true
      );
    });

    it('should return false when user has no required permissions', () => {
      getUserPermissions.mockReturnValue(['some-other-permission']);

      expect(audioNotificationStore.hasConversationPermission(mockUser)).toBe(
        false
      );
    });

    it('should return false when user has no permissions', () => {
      getUserPermissions.mockReturnValue([]);

      expect(audioNotificationStore.hasConversationPermission(mockUser)).toBe(
        false
      );
    });
  });
});
