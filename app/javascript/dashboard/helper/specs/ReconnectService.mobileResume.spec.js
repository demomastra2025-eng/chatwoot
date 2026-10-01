import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createStore } from 'vuex';

import CommunicationThreadApi from 'dashboard/api/inbox/communicationThread';
import ConversationApi from 'dashboard/api/inbox/conversation';
import MessageApi from 'dashboard/api/inbox/message';
import ReconnectService from 'dashboard/helper/ReconnectService';
import conversationsModule from 'dashboard/store/modules/conversations';
import types from 'dashboard/store/mutation-types';

const routeHelperMocks = vi.hoisted(() => ({
  isAConversationRoute: vi.fn(() => true),
  isAInboxViewRoute: vi.fn(() => false),
  isNotificationRoute: vi.fn(() => false),
}));
const emitterMocks = vi.hoisted(() => ({
  on: vi.fn(),
  off: vi.fn(),
  emit: vi.fn(),
}));

vi.mock('dashboard/helper/routeHelpers', () => routeHelperMocks);
vi.mock('shared/helpers/mitt', () => ({ emitter: emitterMocks }));

const clone = value => JSON.parse(JSON.stringify(value));
const noOpActions = names =>
  Object.fromEntries(names.map(name => [name, () => Promise.resolve()]));

const createHarness = ({
  route,
  initialChats = [],
  selectedChat = null,
  savedFolderQuery = null,
  chatListFilters = { page: 1 },
}) => {
  const router = { currentRoute: { value: clone(route) } };
  const conversationState = () => {
    const state = clone(conversationsModule.state);
    state.allConversations = clone(initialChats);
    state.selectedChatId = selectedChat?.id ?? null;
    state.selectedChatType = null;
    if (selectedChat) {
      state.selectedChatType = selectedChat.is_communication_thread
        ? 'communication_thread'
        : 'conversation';
    }
    state.appliedFilters = [];
    state.conversationFilters = clone(chatListFilters);
    state.syncConversationsMessages = {};
    return state;
  };

  const store = createStore({
    modules: {
      route: {
        namespaced: true,
        state: () => ({ fullPath: route.fullPath }),
      },
      conversations: {
        ...conversationsModule,
        state: conversationState,
      },
      contacts: {
        namespaced: true,
        state: () => ({ items: [] }),
        mutations: {
          [types.SET_CONTACTS](state, items) {
            state.items = items;
          },
          [types.SET_CONTACT_ITEM](state, item) {
            state.items = [
              ...state.items.filter(contact => contact.id !== item?.id),
              item,
            ];
          },
        },
      },
      conversationPage: {
        namespaced: true,
        actions: noOpActions(['setCurrentPage', 'setEndReached']),
      },
      conversationStats: {
        namespaced: true,
        actions: noOpActions(['set']),
      },
      conversationLabels: {
        namespaced: true,
        actions: noOpActions(['setBulkConversationLabels']),
      },
      conversationMetadata: {
        namespaced: true,
        state: () => ({}),
        mutations: {
          [types.SET_CONVERSATION_METADATA](state, { id, data }) {
            state[id] = data;
          },
        },
      },
      customViews: {
        namespaced: true,
        state: () => ({
          activeFolder: savedFolderQuery
            ? { query: savedFolderQuery }
            : { query: null },
        }),
        getters: {
          getActiveConversationFolder: state => state.activeFolder,
        },
      },
      accounts: {
        namespaced: true,
        actions: {
          getCacheKeys: async () => ({
            label: 'label-key',
            inbox: 'inbox-key',
            team: 'team-key',
          }),
        },
      },
      labels: {
        namespaced: true,
        actions: noOpActions(['revalidate']),
      },
      inboxes: {
        namespaced: true,
        actions: noOpActions(['revalidate']),
      },
      teams: {
        namespaced: true,
        actions: noOpActions(['revalidate']),
      },
    },
    actions: {
      markMessagesRead: async () => undefined,
    },
  });

  const reconnectService = new ReconnectService(store, router);
  return { reconnectService, router, store };
};

const conversation = (id, overrides = {}) => ({
  id,
  status: 'open',
  messages: [],
  dataFetched: true,
  allMessagesLoaded: true,
  meta: { sender: { id: id + 1000, name: `Contact ${id}` } },
  ...overrides,
});

const pageResponse = payload => ({
  data: { data: { payload, meta: {} } },
});

const apiResponse = data => ({ data });

const makeRoute = ({
  name = 'conversation_through_inbox',
  accountId = '1',
  conversationId = '42',
  inboxId = '2',
  fullPath = `/app/accounts/${accountId}/inbox/${inboxId}/conversations/${conversationId}`,
} = {}) => ({
  name,
  fullPath,
  params: {
    accountId,
    inbox_id: inboxId,
    ...(name === 'communication_thread_conversation'
      ? { communication_thread_id: conversationId }
      : { conversation_id: conversationId }),
  },
});

const thread = (id, overrides = {}) => ({
  id,
  is_communication_thread: true,
  channels: [],
  conversation_ids: [],
  messages: [],
  dataFetched: true,
  allMessagesLoaded: true,
  meta: { sender: { id: id + 2000, name: `Thread contact ${id}` } },
  ...overrides,
});

describe('ReconnectService mobile resume', () => {
  let services = [];

  beforeEach(() => {
    window.addEventListener = vi.fn();
    window.removeEventListener = vi.fn();
    window.setInterval = vi.fn(() => 123);
    window.clearInterval = vi.fn();
    document.addEventListener = vi.fn();
    document.removeEventListener = vi.fn();

    routeHelperMocks.isAConversationRoute.mockReset().mockReturnValue(true);
    routeHelperMocks.isAInboxViewRoute.mockReset().mockReturnValue(false);
    routeHelperMocks.isNotificationRoute.mockReset().mockReturnValue(false);
    Object.values(emitterMocks).forEach(mock => mock.mockReset());
  });

  afterEach(() => {
    services.forEach(service => service.disconnect());
    services = [];
    vi.restoreAllMocks();
  });

  it('restores a quiet active conversation omitted from page one and preserves loaded messages', async () => {
    const loadedMessage = {
      id: 501,
      conversation_id: 42,
      content: 'already loaded',
      message_type: 0,
    };
    const activeConversation = conversation(42, {
      messages: [loadedMessage],
      dataFetched: true,
      allMessagesLoaded: true,
      meta: {
        sender: { id: 1042, name: 'Contact 42' },
        first_unread_message_id: loadedMessage.id,
      },
    });
    const { reconnectService, store } = createHarness({
      route: makeRoute(),
      initialChats: [activeConversation],
      selectedChat: activeConversation,
    });
    services.push(reconnectService);

    vi.spyOn(ConversationApi, 'get').mockResolvedValue(
      pageResponse([conversation(7)])
    );
    vi.spyOn(ConversationApi, 'show').mockResolvedValue(
      apiResponse(
        conversation(42, {
          messages: [],
          dataFetched: false,
          allMessagesLoaded: false,
        })
      )
    );
    vi.spyOn(MessageApi, 'getPreviousMessages').mockResolvedValue({
      data: { meta: {}, payload: [] },
    });

    await reconnectService.onReconnect();

    const restored = store.state.conversations.allConversations.find(
      chat => chat.id === 42
    );

    expect(ConversationApi.show).toHaveBeenCalledWith('42');
    expect(restored).toMatchObject({
      id: 42,
      messages: [loadedMessage],
      dataFetched: true,
      allMessagesLoaded: true,
      meta: expect.objectContaining({
        first_unread_message_id: loadedMessage.id,
      }),
    });
    expect(store.state.conversations.selectedChatId).toBe(42);
    expect(store.state.conversations.selectedChatType).toBe('conversation');
    expect(store.state.conversations.allConversations).toContainEqual(
      expect.objectContaining({ id: 7 })
    );
  });

  it('uses the communication-thread API and saved-folder query for a thread route', async () => {
    const savedFolderQuery = {
      payload: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['open'],
        },
      ],
    };
    const loadedMessage = {
      id: 601,
      communication_thread_id: 42,
      content: 'thread history already loaded',
      message_type: 0,
    };
    const activeThread = thread(42, {
      messages: [loadedMessage],
      dataFetched: true,
      allMessagesLoaded: true,
      meta: {
        sender: { id: 2042, name: 'Thread contact 42' },
        first_unread_message_id: loadedMessage.id,
      },
    });
    const route = makeRoute({
      name: 'communication_thread_conversation',
      fullPath: '/app/accounts/1/communication_threads/42',
    });
    const { reconnectService, store } = createHarness({
      route,
      initialChats: [activeThread],
      selectedChat: activeThread,
      savedFolderQuery,
      chatListFilters: {
        page: 7,
        crmPipelineId: 17,
        crmStageId: 23,
        appointmentStatus: 'scheduled',
        labelsScope: 'all',
        teamScope: 'assigned',
        unread: true,
        sortBy: 'updated_at',
      },
    });
    services.push(reconnectService);

    vi.spyOn(CommunicationThreadApi, 'filter').mockResolvedValue(
      pageResponse([])
    );
    vi.spyOn(CommunicationThreadApi, 'show').mockResolvedValue(
      apiResponse(
        thread(42, {
          messages: [],
          dataFetched: false,
          allMessagesLoaded: false,
        })
      )
    );
    vi.spyOn(CommunicationThreadApi, 'messages').mockResolvedValue({
      data: { meta: {}, payload: [] },
    });
    vi.spyOn(
      CommunicationThreadApi,
      'filterSidebarUnreadCounts'
    ).mockResolvedValue({
      data: { counts: {} },
    });
    const conversationFilter = vi.spyOn(ConversationApi, 'filter');

    await reconnectService.onReconnect();

    const restored = store.state.conversations.allConversations.find(
      chat => chat.id === 42 && chat.is_communication_thread
    );

    expect(CommunicationThreadApi.filter).toHaveBeenCalledWith(
      expect.objectContaining({
        queryData: savedFolderQuery,
        page: 1,
        communicationThreadMode: true,
        crmPipelineId: 17,
        crmStageId: 23,
        appointmentStatus: 'scheduled',
        labelsScope: 'all',
        teamScope: 'assigned',
        unread: true,
        sortBy: 'updated_at',
      })
    );
    expect(CommunicationThreadApi.filter.mock.calls[0][0]).not.toHaveProperty(
      'expectedRouteFullPath'
    );
    expect(conversationFilter).not.toHaveBeenCalled();
    expect(CommunicationThreadApi.show).toHaveBeenCalledWith('42');
    expect(CommunicationThreadApi.messages).toHaveBeenCalledWith(
      42,
      expect.any(Object)
    );
    expect(restored).toMatchObject({
      id: 42,
      is_communication_thread: true,
      messages: [loadedMessage],
      dataFetched: true,
      allMessagesLoaded: true,
      meta: expect.objectContaining({
        first_unread_message_id: loadedMessage.id,
      }),
    });
    expect(store.state.conversations.selectedChatId).toBe(42);
    expect(store.state.conversations.selectedChatType).toBe(
      'communication_thread'
    );
  });

  it('does not restore a forbidden omitted conversation or sync its cached messages', async () => {
    const activeConversation = conversation(42, {
      messages: [
        {
          id: 701,
          conversation_id: 42,
          content: 'cached history',
          message_type: 0,
        },
      ],
      dataFetched: true,
      allMessagesLoaded: true,
    });
    const { reconnectService, store } = createHarness({
      route: makeRoute(),
      initialChats: [activeConversation],
      selectedChat: activeConversation,
    });
    services.push(reconnectService);

    vi.spyOn(ConversationApi, 'get').mockResolvedValue(
      pageResponse([conversation(7)])
    );
    vi.spyOn(ConversationApi, 'show').mockRejectedValue({
      response: { status: 403 },
    });
    vi.spyOn(MessageApi, 'getPreviousMessages').mockResolvedValue({
      data: { meta: {}, payload: [] },
    });
    const dispatchSpy = vi.spyOn(store, 'dispatch');

    await reconnectService.onReconnect();

    expect(ConversationApi.show).toHaveBeenCalledWith('42');
    expect(
      store.state.conversations.allConversations.some(chat => chat.id === 42)
    ).toBe(false);
    expect(store.getters.getSelectedChat).toEqual({});
    expect(dispatchSpy).not.toHaveBeenCalledWith(
      'syncActiveConversationMessages',
      expect.anything()
    );
    expect(MessageApi.getPreviousMessages).not.toHaveBeenCalled();
  });

  it('ignores a delayed detail response after the account route changes', async () => {
    let resolveDetail;
    const delayedDetail = new Promise(resolve => {
      resolveDetail = resolve;
    });
    const oldConversation = conversation(42, {
      meta: { sender: { id: 1042, name: 'Old account contact' } },
    });
    const { reconnectService, router, store } = createHarness({
      route: makeRoute(),
      initialChats: [oldConversation],
      selectedChat: oldConversation,
    });
    services.push(reconnectService);

    vi.spyOn(ConversationApi, 'get').mockResolvedValue(
      pageResponse([conversation(7)])
    );
    vi.spyOn(ConversationApi, 'show').mockReturnValue(delayedDetail);

    const reconnectPromise = reconnectService.onReconnect();
    await vi.waitFor(() => {
      expect(ConversationApi.show).toHaveBeenCalledWith('42');
    });

    const nextRoute = makeRoute({
      accountId: '2',
      conversationId: '99',
      fullPath: '/app/accounts/2/inbox/2/conversations/99',
    });
    router.currentRoute.value = nextRoute;
    store.state.route.fullPath = nextRoute.fullPath;
    resolveDetail(
      apiResponse(
        conversation(42, {
          meta: { sender: { id: 1042, name: 'Old account contact' } },
        })
      )
    );

    await reconnectPromise;

    expect(
      store.state.conversations.allConversations.some(chat => chat.id === 42)
    ).toBe(false);
    expect(store.state.conversations.selectedChatId).not.toBe(42);
    expect(
      store.state.contacts.items.some(contact => contact.id === 1042)
    ).toBe(false);
  });
});
