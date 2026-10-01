import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { differenceInSeconds } from 'date-fns';
import {
  isAConversationRoute,
  isAInboxViewRoute,
  isNotificationRoute,
} from 'dashboard/helper/routeHelpers';
import ReconnectService from 'dashboard/helper/ReconnectService';

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    on: vi.fn(),
    off: vi.fn(),
    emit: vi.fn(),
  },
}));

vi.mock('date-fns', () => ({
  differenceInSeconds: vi.fn(),
}));

vi.mock('dashboard/helper/routeHelpers', () => ({
  isAConversationRoute: vi.fn(),
  isAInboxViewRoute: vi.fn(),
  isNotificationRoute: vi.fn(),
}));

const storeMock = {
  dispatch: vi.fn(),
  getters: {
    getAppliedConversationFiltersQuery: [],
    'customViews/getActiveConversationFolder': { query: {} },
    'notifications/getNotificationFilters': {},
  },
};

const routerMock = {
  currentRoute: {
    value: {
      name: '',
      params: { conversation_id: null },
    },
  },
};

describe('ReconnectService', () => {
  let reconnectService;

  beforeEach(() => {
    window.addEventListener = vi.fn();
    window.removeEventListener = vi.fn();
    window.setInterval = vi.fn(() => 123);
    window.clearInterval = vi.fn();
    document.addEventListener = vi.fn();
    document.removeEventListener = vi.fn();
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { reload: vi.fn() },
    });
    Object.defineProperty(document, 'hidden', {
      configurable: true,
      writable: true,
      value: false,
    });
    isAConversationRoute.mockReset();
    isAInboxViewRoute.mockReset();
    isNotificationRoute.mockReset();
    routerMock.currentRoute.value = {
      name: '',
      fullPath: undefined,
      params: { conversation_id: null },
    };
    storeMock.getters.getAppliedConversationFiltersQuery = [];
    storeMock.getters.getChatListFilters = {};
    storeMock.getters.getAllConversations = [];
    storeMock.getters.getSelectedChat = null;
    storeMock.getters['customViews/getActiveConversationFolder'] = {
      query: null,
    };
    reconnectService = new ReconnectService(storeMock, routerMock);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
  });

  describe('constructor', () => {
    it('should initialize with store, router, and setup event listeners', () => {
      expect(reconnectService.store).toBe(storeMock);
      expect(reconnectService.router).toBe(routerMock);
      expect(window.addEventListener).toHaveBeenCalledWith(
        'online',
        reconnectService.handleOnlineEvent
      );
      expect(window.addEventListener).toHaveBeenCalledWith(
        'focus',
        reconnectService.handleWindowFocus
      );
      expect(document.addEventListener).toHaveBeenCalledWith(
        'visibilitychange',
        reconnectService.handleVisibilityChange
      );
      expect(emitter.on).toHaveBeenCalledWith(
        BUS_EVENTS.WEBSOCKET_RECONNECT,
        reconnectService.onReconnect
      );
      expect(emitter.on).toHaveBeenCalledWith(
        BUS_EVENTS.WEBSOCKET_DISCONNECT,
        reconnectService.onDisconnect
      );
      expect(window.setInterval).toHaveBeenCalledWith(
        reconnectService.reconcileVisibleRoute,
        30000
      );
    });
  });

  describe('disconnect', () => {
    it('should remove event listeners', () => {
      reconnectService.disconnect();
      expect(window.removeEventListener).toHaveBeenCalledWith(
        'online',
        reconnectService.handleOnlineEvent
      );
      expect(window.removeEventListener).toHaveBeenCalledWith(
        'focus',
        reconnectService.handleWindowFocus
      );
      expect(document.removeEventListener).toHaveBeenCalledWith(
        'visibilitychange',
        reconnectService.handleVisibilityChange
      );
      expect(emitter.off).toHaveBeenCalledWith(
        BUS_EVENTS.WEBSOCKET_RECONNECT,
        reconnectService.onReconnect
      );
      expect(emitter.off).toHaveBeenCalledWith(
        BUS_EVENTS.WEBSOCKET_DISCONNECT,
        reconnectService.onDisconnect
      );
      expect(window.clearInterval).toHaveBeenCalledWith(123);
    });
  });

  describe('getSecondsSinceDisconnect', () => {
    it('should return 0 if disconnectTime is null', () => {
      reconnectService.disconnectTime = null;
      expect(reconnectService.getSecondsSinceDisconnect()).toBe(0);
    });

    it('should return the number of seconds + threshold since disconnect', () => {
      reconnectService.disconnectTime = new Date();
      differenceInSeconds.mockReturnValue(100);
      expect(reconnectService.getSecondsSinceDisconnect()).toBe(100);
    });
  });

  describe('handleOnlineEvent', () => {
    it('should reload the page if disconnected for more than 3 hours', () => {
      reconnectService.getSecondsSinceDisconnect = vi
        .fn()
        .mockReturnValue(10801);
      reconnectService.handleOnlineEvent();
      expect(window.location.reload).toHaveBeenCalled();
    });

    it('should not reload the page if disconnected for less than 3 hours', () => {
      reconnectService.getSecondsSinceDisconnect = vi
        .fn()
        .mockReturnValue(10799);
      reconnectService.handleOnlineEvent();
      expect(window.location.reload).not.toHaveBeenCalled();
    });
  });

  describe('fetchConversations', () => {
    it('should refresh the full current list instead of sending a delta window', async () => {
      await reconnectService.fetchConversations();
      expect(storeMock.dispatch).toHaveBeenCalledWith('updateChatListFilters', {
        page: null,
        updatedWithin: null,
        communicationThreadMode: false,
      });
      expect(storeMock.dispatch).toHaveBeenCalledWith('fetchAllConversations', {
        expectedRouteFullPath: undefined,
      });
    });

    it('should use the communication thread list on communication thread routes', async () => {
      routerMock.currentRoute.value = {
        name: 'communication_threads_dashboard',
        fullPath: '/accounts/1/communication_threads',
        params: { accountId: '1' },
      };

      await reconnectService.fetchConversations();

      expect(storeMock.dispatch).toHaveBeenCalledWith('updateChatListFilters', {
        page: null,
        updatedWithin: null,
        communicationThreadMode: true,
      });
      expect(storeMock.dispatch).toHaveBeenCalledWith(
        'fetchCommunicationThreads',
        {
          expectedRouteFullPath: '/accounts/1/communication_threads',
        }
      );
    });
  });

  describe('fetchFilteredOrSavedConversations', () => {
    it('should dispatch the current query and communication thread mode', async () => {
      const payload = { test: 'data' };
      routerMock.currentRoute.value = {
        name: 'communication_thread_conversation',
        fullPath: '/accounts/1/communication_threads/42',
        params: {
          accountId: '1',
          communication_thread_id: '42',
        },
      };

      await reconnectService.fetchFilteredOrSavedConversations(payload);

      expect(storeMock.dispatch).toHaveBeenCalledWith(
        'fetchFilteredConversations',
        {
          queryData: payload,
          page: 1,
          communicationThreadMode: true,
          expectedRouteFullPath: '/accounts/1/communication_threads/42',
        }
      );
    });
  });

  describe('fetchConversationsOnReconnect', () => {
    it('should refresh filtered conversations for the current route', async () => {
      storeMock.getters.getAppliedConversationFiltersQuery = {
        payload: [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['open'],
          },
        ],
      };
      const spy = vi.spyOn(
        reconnectService,
        'fetchFilteredOrSavedConversations'
      );

      await reconnectService.fetchConversationsOnReconnect();

      expect(spy).toHaveBeenCalledWith(
        storeMock.getters.getAppliedConversationFiltersQuery,
        expect.objectContaining({
          name: '',
          communicationThreadMode: false,
        })
      );
    });

    it('should refresh the plain list if there is no applied or saved query', async () => {
      storeMock.getters.getAppliedConversationFiltersQuery = [];
      storeMock.getters['customViews/getActiveConversationFolder'] = {
        query: null,
      };

      const spy = vi.spyOn(reconnectService, 'fetchConversations');

      await reconnectService.fetchConversationsOnReconnect();

      expect(spy).toHaveBeenCalledWith(
        expect.objectContaining({
          name: '',
          communicationThreadMode: false,
        })
      );
    });

    it('should preserve a saved-folder query and mark thread mode for thread routes', async () => {
      storeMock.getters.getAppliedConversationFiltersQuery = [];
      storeMock.getters['customViews/getActiveConversationFolder'] = {
        query: { test: 'activeFolderQuery' },
      };
      routerMock.currentRoute.value = {
        name: 'communication_thread_conversation',
        fullPath: '/accounts/1/communication_threads/42',
        params: {
          accountId: '1',
          communication_thread_id: '42',
        },
      };

      const spy = vi.spyOn(
        reconnectService,
        'fetchFilteredOrSavedConversations'
      );

      await reconnectService.fetchConversationsOnReconnect();

      expect(spy).toHaveBeenCalledWith(
        { test: 'activeFolderQuery' },
        expect.objectContaining({
          name: 'communication_thread_conversation',
          communicationThreadMode: true,
        })
      );
    });
  });

  describe('fetchConversationMessagesOnReconnect', () => {
    it('should dispatch a type-aware message sync if a conversation ID exists', async () => {
      routerMock.currentRoute.value.params.conversation_id = 1;
      await reconnectService.fetchConversationMessagesOnReconnect();
      expect(storeMock.dispatch).toHaveBeenCalledWith(
        'syncActiveConversationMessages',
        {
          conversationId: 1,
          conversationType: 'conversation',
          expectedRouteFullPath: undefined,
        }
      );
    });

    it('should not dispatch a message sync if no conversation ID exists', async () => {
      routerMock.currentRoute.value.params.conversation_id = null;
      await reconnectService.fetchConversationMessagesOnReconnect();
      expect(storeMock.dispatch).not.toHaveBeenCalledWith(
        'syncActiveConversationMessages',
        expect.anything()
      );
    });
  });

  describe('fetchNotificationsOnReconnect', () => {
    it('should dispatch notifications/index', async () => {
      const filter = { test: 'filter' };
      await reconnectService.fetchNotificationsOnReconnect(filter);
      expect(storeMock.dispatch).toHaveBeenCalledWith('notifications/index', {
        ...filter,
        page: 1,
      });
    });
  });

  describe('active conversation visibility sync', () => {
    it('should sync active conversation messages on focus when on a visible conversation route', async () => {
      routerMock.currentRoute.value.name = 'conversation_canvas';
      routerMock.currentRoute.value.params.conversation_id = 42;
      isAConversationRoute.mockReturnValue(true);

      await reconnectService.handleWindowFocus();

      expect(storeMock.dispatch).toHaveBeenCalledWith(
        'syncActiveConversationMessages',
        {
          conversationId: 42,
          conversationType: 'conversation',
          expectedRouteFullPath: undefined,
        }
      );
      expect(storeMock.dispatch).not.toHaveBeenCalledWith(
        'fetchAllConversations'
      );
      expect(storeMock.dispatch).not.toHaveBeenCalledWith(
        'updateChatListFilters',
        expect.anything()
      );
    });

    it('should sync active conversation messages on visibilitychange when tab becomes visible', async () => {
      routerMock.currentRoute.value.name = 'conversation_canvas';
      routerMock.currentRoute.value.params.conversation_id = 42;
      isAConversationRoute.mockReturnValue(true);
      document.hidden = false;

      await reconnectService.handleVisibilityChange();

      expect(storeMock.dispatch).toHaveBeenCalledWith(
        'syncActiveConversationMessages',
        {
          conversationId: 42,
          conversationType: 'conversation',
          expectedRouteFullPath: undefined,
        }
      );
    });

    it('should not sync active conversation messages when tab is hidden', async () => {
      routerMock.currentRoute.value.name = 'conversation_canvas';
      routerMock.currentRoute.value.params.conversation_id = 42;
      isAConversationRoute.mockReturnValue(true);
      document.hidden = true;

      await reconnectService.handleVisibilityChange();

      expect(storeMock.dispatch).not.toHaveBeenCalledWith(
        'syncActiveConversationMessages',
        expect.anything()
      );
    });

    it('should not sync active conversation messages outside conversation routes', async () => {
      routerMock.currentRoute.value.name = 'dashboard_home';
      routerMock.currentRoute.value.params.conversation_id = 42;
      isAConversationRoute.mockReturnValue(false);

      await reconnectService.handleWindowFocus();

      expect(storeMock.dispatch).not.toHaveBeenCalledWith(
        'syncActiveConversationMessages',
        expect.anything()
      );
    });

    it('should debounce duplicate active conversation sync triggers', async () => {
      routerMock.currentRoute.value.name = 'conversation_canvas';
      routerMock.currentRoute.value.params.conversation_id = 42;
      isAConversationRoute.mockReturnValue(true);
      document.hidden = false;

      await reconnectService.handleVisibilityChange();
      await reconnectService.handleWindowFocus();

      const activeMessageSyncCalls = storeMock.dispatch.mock.calls.filter(
        ([action]) => action === 'syncActiveConversationMessages'
      );
      expect(activeMessageSyncCalls).toEqual([
        [
          'syncActiveConversationMessages',
          {
            conversationId: 42,
            conversationType: 'conversation',
            expectedRouteFullPath: undefined,
          },
        ],
      ]);
    });
  });

  describe('revalidateCaches', () => {
    it('should dispatch revalidate actions for labels, inboxes, and teams', async () => {
      storeMock.dispatch.mockResolvedValueOnce({
        label: 'labelKey',
        inbox: 'inboxKey',
        team: 'teamKey',
      });
      await reconnectService.revalidateCaches();
      expect(storeMock.dispatch).toHaveBeenCalledWith('accounts/getCacheKeys');
      expect(storeMock.dispatch).toHaveBeenCalledWith('labels/revalidate', {
        newKey: 'labelKey',
      });
      expect(storeMock.dispatch).toHaveBeenCalledWith('inboxes/revalidate', {
        newKey: 'inboxKey',
      });
      expect(storeMock.dispatch).toHaveBeenCalledWith('teams/revalidate', {
        newKey: 'teamKey',
      });
    });
  });

  describe('handleRouteSpecificFetch', () => {
    it('should fetch conversations and messages if current route is a conversation route', async () => {
      isAConversationRoute.mockReturnValue(true);
      routerMock.currentRoute.value = {
        name: 'conversation_through_inbox',
        fullPath: '/accounts/1/inbox/2/conversations/42',
        params: {
          accountId: '1',
          inbox_id: '2',
          conversation_id: '42',
        },
      };
      reconnectService.fetchConversationsOnReconnect = vi.fn();
      reconnectService.restoreActiveConversationOnReconnect = vi
        .fn()
        .mockResolvedValue({ id: 42, is_communication_thread: false });
      reconnectService.fetchConversationMessagesOnReconnect = vi.fn();

      await reconnectService.handleRouteSpecificFetch();

      expect(reconnectService.fetchConversationsOnReconnect).toHaveBeenCalled();
      expect(storeMock.dispatch).toHaveBeenCalledWith('setActiveChat', {
        data: { id: 42, is_communication_thread: false },
        expectedRouteFullPath: '/accounts/1/inbox/2/conversations/42',
        resumeActiveConversation: true,
      });
      expect(
        reconnectService.fetchConversationMessagesOnReconnect
      ).toHaveBeenCalled();
    });

    it('should fetch notifications if current route is an inbox view route', async () => {
      isAInboxViewRoute.mockReturnValue(true);
      const spy = vi.spyOn(reconnectService, 'fetchNotificationsOnReconnect');
      await reconnectService.handleRouteSpecificFetch();
      expect(spy).toHaveBeenCalled();
    });

    it('should fetch notifications if current route is a notification route', async () => {
      isNotificationRoute.mockReturnValue(true);
      const spy = vi.spyOn(reconnectService, 'fetchNotificationsOnReconnect');
      await reconnectService.handleRouteSpecificFetch();
      expect(spy).toHaveBeenCalled();
    });
  });

  describe('setConversationLastMessageId', () => {
    it('should pass the current conversation type when a route ID exists', async () => {
      routerMock.currentRoute.value.params.conversation_id = 1;
      await reconnectService.setConversationLastMessageId();
      expect(storeMock.dispatch).toHaveBeenCalledWith(
        'setConversationLastMessageId',
        { conversationId: 1, conversationType: 'conversation' }
      );
    });

    it('should not dispatch when no conversation ID exists', async () => {
      routerMock.currentRoute.value.params.conversation_id = null;
      await reconnectService.setConversationLastMessageId();
      expect(storeMock.dispatch).not.toHaveBeenCalledWith(
        'setConversationLastMessageId',
        expect.anything()
      );
    });
  });

  describe('onDisconnect', () => {
    it('should set disconnectTime and call setConversationLastMessageId', () => {
      reconnectService.setConversationLastMessageId = vi.fn();
      reconnectService.onDisconnect();
      expect(reconnectService.disconnectTime).toBeInstanceOf(Date);
      expect(reconnectService.setConversationLastMessageId).toHaveBeenCalled();
    });
  });

  describe('onReconnect', () => {
    it('should handle route-specific fetch, revalidate caches, and emit WEBSOCKET_RECONNECT_COMPLETED event', async () => {
      reconnectService.handleRouteSpecificFetch = vi.fn();
      reconnectService.revalidateCaches = vi.fn();
      await reconnectService.onReconnect();
      expect(reconnectService.handleRouteSpecificFetch).toHaveBeenCalled();
      expect(reconnectService.revalidateCaches).toHaveBeenCalled();
      expect(emitter.emit).toHaveBeenCalledWith(
        BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED
      );
    });
  });
});
