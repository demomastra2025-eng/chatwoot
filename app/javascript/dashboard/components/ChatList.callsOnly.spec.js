import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { reactive, ref } from 'vue';

import ChatList from './ChatList.vue';
import ChatListHeader from './ChatListHeader.vue';
import { buildCommunicationThreadConversation } from 'dashboard/helper/communicationThreadHelper';

const mocks = vi.hoisted(() => ({
  route: null,
  router: null,
  uiSettings: null,
  updateUISettings: null,
  bulkActions: null,
}));

vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => mocks.route,
  useRouter: () => mocks.router,
}));

vi.mock('dashboard/composables/useUISettings', async importOriginal => ({
  ...(await importOriginal()),
  useUISettings: () => ({
    uiSettings: mocks.uiSettings,
    updateUISettings: updates => mocks.updateUISettings(updates),
  }),
}));

vi.mock(
  'dashboard/composables/chatlist/useBulkActions',
  async importOriginal => ({
    ...(await importOriginal()),
    useBulkActions: () => mocks.bulkActions,
  })
);

vi.mock(
  'dashboard/composables/chatlist/useChatListKeyboardEvents',
  async importOriginal => ({
    ...(await importOriginal()),
    useChatListKeyboardEvents: () => {},
  })
);

vi.mock('shared/composables/useFilter', async importOriginal => ({
  ...(await importOriginal()),
  useFilter: () => ({
    initializeStatusAndAssigneeFilterToModal: () => null,
    initializeInboxTeamAndLabelFilterToModal: () => [],
  }),
}));

vi.mock(
  'dashboard/composables/useConversationRequiredAttributes',
  async importOriginal => ({
    ...(await importOriginal()),
    useConversationRequiredAttributes: () => ({
      checkMissingAttributes: () => ({ hasMissing: false, missing: [] }),
    }),
  })
);

vi.mock('dashboard/stores/crm/references', async importOriginal => ({
  ...(await importOriginal()),
  useCrmReferencesStore: () => ({
    pipelines: [],
    ui: {},
    loadPipelines: () => Promise.resolve(),
  }),
}));

const buildStore = ({ chats = [] } = {}) => ({
  state: {},
  getters: reactive({
    getCurrentUser: { id: 1, name: 'Agent' },
    getFilteredConversations: [],
    getMineChats: () => chats,
    getAllStatusChats: () => chats,
    getUnAssignedChats: () => chats,
    getParticipatingChats: () => chats,
    getChatListLoadingStatus: false,
    getChatListLoadingError: false,
    getSelectedInbox: null,
    'conversationStats/getStats': {},
    getAppliedConversationFiltersV2: [],
    'customViews/getConversationCustomViews': [],
    'agents/getAgents': [],
    'teams/getTeams': [],
    'inboxes/getInboxes': [],
    'campaigns/getAllCampaigns': [],
    'labels/getLabels': [],
    getCurrentAccountId: 1,
    'accounts/getAccount': () => ({ id: 1, settings: {} }),
    'accounts/isFeatureEnabledonAccount': () => false,
    'contacts/getContact': () => ({}),
    'teams/getTeam': () => ({}),
    getConversationById: () => null,
    'inboxes/getInbox': () => ({}),
    'conversationPage/getCurrentPageFilter': () => 0,
    'conversationPage/getHasEndReached': () => false,
    'attributes/getAttributesByModel': () => [],
  }),
  dispatch: vi.fn(() => Promise.resolve()),
});

const setRoute = ({
  name = 'communication_threads_dashboard',
  params = {},
  query = {},
}) => {
  mocks.route = reactive({ name, params: { accountId: 1, ...params }, query });
};

const storePlugin = store => ({
  install(app) {
    app.config.globalProperties.$store = store;
    app.provide('store', store);
  },
});

const mountChatList = ({ store, props = {} }) =>
  shallowMount(ChatList, {
    props,
    global: { plugins: [storePlugin(store)] },
  });

const lastListFilters = store =>
  store.dispatch.mock.calls
    .filter(([action]) => action === 'updateChatListFilters')
    .at(-1)?.[1];

describe('ChatList calls_only quick filter orchestration', () => {
  beforeEach(() => {
    mocks.router = {
      push: vi.fn(() => Promise.resolve()),
      replace: vi.fn(() => Promise.resolve()),
    };
    mocks.uiSettings = ref({});
    mocks.updateUISettings = vi.fn(updates => {
      mocks.uiSettings.value = { ...mocks.uiSettings.value, ...updates };
    });
    mocks.bulkActions = {
      selectedConversations: ref([]),
      selectedCount: ref(0),
      selectedInboxes: ref([]),
      allMatchingSelection: ref(null),
      isSelectingAll: ref(false),
      selectionVersion: ref(0),
      selectConversation: () => {},
      deSelectConversation: () => {},
      selectAllConversations: () => {},
      selectAllMatching: () => {},
      setSelectionContext: vi.fn(),
      resetBulkActions: () => {},
      isConversationSelected: () => false,
      onAssignAgent: () => {},
      onAssignLabels: () => {},
      onRemoveLabels: () => {},
      onAssignTeamsForBulk: () => {},
      onUpdateConversations: () => {},
    };
  });

  it('toggles calls_only in route query when ChatListHeader emits callsOnlyFilterToggle', async () => {
    setRoute({
      query: { status: 'open', assignee_type: 'all' },
    });
    const store = buildStore();
    const wrapper = mountChatList({
      store,
      props: { communicationThreadMode: true },
    });
    await flushPromises();

    const header = wrapper.findComponent(ChatListHeader);
    expect(header.props('activeCallsOnly')).toBe(false);
    expect(lastListFilters(store)?.callsOnly).toBeUndefined();

    header.vm.$emit('callsOnlyFilterToggle');
    expect(mocks.router.push).toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'communication_threads_dashboard',
        query: expect.objectContaining({
          status: 'open',
          assignee_type: 'all',
          calls_only: 'true',
        }),
      })
    );

    mocks.router.push.mockClear();
    mocks.route.query = {
      status: 'open',
      assignee_type: 'all',
      calls_only: 'true',
    };
    await flushPromises();

    expect(header.props('activeCallsOnly')).toBe(true);
    expect(lastListFilters(store)).toMatchObject({
      callsOnly: true,
    });
    const lastSelectionContext = JSON.parse(
      mocks.bulkActions.setSelectionContext.mock.calls.at(-1)[0]
    );
    expect(lastSelectionContext.filters).toMatchObject({
      calls_only: true,
    });

    header.vm.$emit('callsOnlyFilterToggle');
    const pushedQuery = mocks.router.push.mock.calls.at(-1)[0].query;
    expect(pushedQuery.calls_only).toBeUndefined();
  });

  it('excludes text-only dialogs from conversationList while calls_only=true is active', async () => {
    const callThread = buildCommunicationThreadConversation({
      id: 11,
      record_id: 1011,
      status: 'open',
      has_calls: true,
      unread_count: 0,
    });
    const textOnlyThread = buildCommunicationThreadConversation({
      id: 22,
      record_id: 1022,
      status: 'open',
      has_calls: false,
      unread_count: 0,
    });
    setRoute({
      query: { status: 'open', assignee_type: 'all', calls_only: 'true' },
    });
    const store = buildStore({ chats: [callThread, textOnlyThread] });
    const wrapper = mountChatList({
      store,
      props: { communicationThreadMode: true },
    });
    await flushPromises();

    expect(wrapper.vm.conversationList.map(item => item.id)).toEqual([11]);
  });
});
