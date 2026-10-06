import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { reactive, ref } from 'vue';

import ChatList from './ChatList.vue';
import ChatListHeader from './ChatListHeader.vue';
import IntersectionObserver from './IntersectionObserver.vue';
import {
  CONVERSATION_LIST_CONTEXT_SETTINGS_KEY,
  CONVERSATION_LIST_GLOBAL_STATUS_KEY,
} from 'dashboard/helper/conversationListContext';
import { conversationUrl } from 'dashboard/helper/URLHelper';

// Focused spec for the status and sort orchestration of the conversation
// list: page status vs. remembered status, "All statuses" with advanced
// filters, and the sort order remembered per list context.

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

const statusFilter = status => ({
  attribute_key: 'status',
  filter_operator: 'equal_to',
  values: [status],
  query_operator: 'and',
});

const labelFilter = {
  attribute_key: 'labels',
  filter_operator: 'equal_to',
  values: ['vip'],
  query_operator: 'and',
};

const buildStore = ({ appliedFilters = [], folders = [] } = {}) => ({
  state: {},
  getters: reactive({
    getCurrentUser: { id: 1, name: 'Agent' },
    getFilteredConversations: [],
    getMineChats: () => [],
    getAllStatusChats: () => [],
    getUnAssignedChats: () => [],
    getParticipatingChats: () => [],
    getChatListLoadingStatus: false,
    getChatListLoadingError: false,
    getSelectedInbox: null,
    'conversationStats/getStats': {},
    getAppliedConversationFiltersV2: appliedFilters,
    'customViews/getConversationCustomViews': folders,
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

const setRoute = ({ name, params = {}, query = {} }) => {
  mocks.route = reactive({ name, params: { accountId: 1, ...params }, query });
};

// Installed like Vuex: `useStore()` injects it and the store composables read
// `$store` during setup (global mocks are only applied after setup).
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

const dispatchedActions = store =>
  store.dispatch.mock.calls.map(([action]) => action);

const lastListFilters = store =>
  store.dispatch.mock.calls
    .filter(([action]) => action === 'updateChatListFilters')
    .at(-1)?.[1];

const rememberedStatus = updates =>
  updates?.[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]?.[
    CONVERSATION_LIST_GLOBAL_STATUS_KEY
  ]?.status;

describe('ChatList status and sort orchestration', () => {
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
      onMarkConversationsRead: () => {},
    };
  });

  describe('"All statuses" with applied advanced filters', () => {
    it('turns a filter whose only condition is the status into the plain list', async () => {
      setRoute({
        name: 'communication_threads_dashboard',
        query: { status: 'open' },
      });
      const store = buildStore({ appliedFilters: [statusFilter('open')] });
      mountChatList({ store, props: { communicationThreadMode: true } });
      await flushPromises();
      store.dispatch.mockClear();

      mocks.route.query = { status: 'all' };
      await flushPromises();

      const actions = dispatchedActions(store);
      expect(actions).toContain('clearConversationFilters');
      expect(actions).toContain('fetchCommunicationThreads');
      expect(actions).not.toContain('fetchFilteredConversations');
      expect(actions).not.toContain('setConversationFilters');
      expect(lastListFilters(store)).toMatchObject({
        status: 'all',
        communicationThreadMode: true,
      });
    });

    it('selects all matching items of the plain list when only the status condition is left', async () => {
      setRoute({
        name: 'communication_threads_dashboard',
        query: { status: 'all' },
      });
      const store = buildStore({ appliedFilters: [statusFilter('open')] });
      mountChatList({ store, props: { communicationThreadMode: true } });
      await flushPromises();

      const contextKey =
        mocks.bulkActions.setSelectionContext.mock.calls.at(-1)[0];
      expect(JSON.parse(contextKey)).toMatchObject({
        resourceType: 'CommunicationThread',
        filters: { mode: 'basic', status: 'all' },
      });
    });

    it('keeps the other conditions and drops only the status condition', async () => {
      setRoute({
        name: 'communication_threads_dashboard',
        query: { status: 'open' },
      });
      const store = buildStore({
        appliedFilters: [statusFilter('open'), labelFilter],
      });
      mountChatList({ store, props: { communicationThreadMode: true } });
      await flushPromises();
      store.dispatch.mockClear();

      mocks.route.query = { status: 'all' };
      await flushPromises();

      expect(store.dispatch).toHaveBeenCalledWith('setConversationFilters', [
        labelFilter,
      ]);
      const [, request] = store.dispatch.mock.calls.find(
        ([action]) => action === 'fetchFilteredConversations'
      );
      expect(request.communicationThreadMode).toBe(true);
      expect(
        request.queryData.payload.map(filter => filter.attribute_key)
      ).toEqual(['labels']);
      expect(dispatchedActions(store)).not.toContain(
        'clearConversationFilters'
      );
    });

    it('loads the next page as the plain list when only the status condition is left', async () => {
      setRoute({
        name: 'communication_threads_dashboard',
        query: { status: 'all' },
      });
      const store = buildStore({ appliedFilters: [statusFilter('open')] });
      const wrapper = mountChatList({
        store,
        props: { communicationThreadMode: true },
      });
      await flushPromises();
      store.dispatch.mockClear();

      wrapper.findComponent(IntersectionObserver).vm.$emit('observed');
      await flushPromises();

      const actions = dispatchedActions(store);
      expect(actions).toContain('fetchCommunicationThreads');
      expect(actions).not.toContain('fetchFilteredConversations');
    });
  });

  describe('remembered status', () => {
    it('reopens the remembered status when the route has none', async () => {
      mocks.uiSettings.value = {
        [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]: {
          [CONVERSATION_LIST_GLOBAL_STATUS_KEY]: { status: 'resolved' },
        },
      };
      setRoute({ name: 'communication_threads_dashboard' });
      const store = buildStore();
      const wrapper = mountChatList({
        store,
        props: { communicationThreadMode: true },
      });
      await flushPromises();

      expect(lastListFilters(store)).toMatchObject({ status: 'resolved' });
      expect(store.dispatch).toHaveBeenCalledWith(
        'setChatStatusFilter',
        'resolved'
      );
      expect(wrapper.findComponent(ChatListHeader).props()).toMatchObject({
        activeStatus: 'resolved',
        showStatusFilter: true,
      });
    });

    it('opens a classic list with open, not a stored all-statuses selection, and shows the selector', async () => {
      mocks.uiSettings.value = {
        [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]: {
          [CONVERSATION_LIST_GLOBAL_STATUS_KEY]: { status: 'all' },
        },
      };
      setRoute({ name: 'label_conversations', params: { label: 'vip' } });
      const store = buildStore();
      const wrapper = mountChatList({ store, props: { label: 'vip' } });
      await flushPromises();

      expect(lastListFilters(store)).toMatchObject({
        status: 'open',
        labels: ['vip'],
        communicationThreadMode: false,
      });
      expect(dispatchedActions(store)).toContain('fetchAllConversations');
      expect(wrapper.findComponent(ChatListHeader).props()).toMatchObject({
        activeStatus: 'open',
        showStatusFilter: true,
      });
    });

    it('shows "All statuses" carried into a classic list and does not remember it', async () => {
      mocks.uiSettings.value = {
        [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]: {
          [CONVERSATION_LIST_GLOBAL_STATUS_KEY]: { status: 'snoozed' },
        },
      };
      setRoute({
        name: 'label_conversations',
        params: { label: 'vip' },
        query: { status: 'snoozed' },
      });
      const store = buildStore();
      const wrapper = mountChatList({ store, props: { label: 'vip' } });
      await flushPromises();

      wrapper
        .findComponent(ChatListHeader)
        .vm.$emit('statusFilterChange', 'all');
      expect(mocks.router.push).toHaveBeenCalledWith(
        expect.objectContaining({
          name: 'label_conversations',
          query: expect.objectContaining({ status: 'all' }),
        })
      );

      // the router applies the pushed query
      mocks.route.query = mocks.router.push.mock.calls[0][0].query;
      await flushPromises();

      expect(lastListFilters(store)).toMatchObject({
        status: 'all',
        labels: ['vip'],
      });
      expect(wrapper.findComponent(ChatListHeader).props()).toMatchObject({
        activeStatus: 'all',
        showStatusFilter: true,
      });
      expect(mocks.updateUISettings).toHaveBeenCalled();
      expect(
        rememberedStatus(mocks.updateUISettings.mock.calls.at(-1)[0])
      ).toBe('snoozed');

      // a concrete status is remembered again
      mocks.route.query = { ...mocks.route.query, status: 'resolved' };
      await flushPromises();
      expect(
        rememberedStatus(mocks.updateUISettings.mock.calls.at(-1)[0])
      ).toBe('resolved');
    });

    it('hides the status selector in saved folders, which ignore the page status', async () => {
      setRoute({
        name: 'folder_conversations',
        params: { id: 3 },
        query: { status: 'open' },
      });
      const store = buildStore({
        folders: [{ id: 3, name: 'VIP', query: { payload: [labelFilter] } }],
      });
      const wrapper = mountChatList({ store, props: { foldersId: 3 } });
      await flushPromises();

      expect(wrapper.findComponent(ChatListHeader).props()).toMatchObject({
        showStatusFilter: false,
        pageTitle: 'VIP',
      });
    });
  });

  describe('"All statuses" when a conversation is opened', () => {
    // The route of the opened card is built by the same URL helper the card
    // uses, so this covers the card link and the list together.
    const openCardRoute = ({ name, params, url }) => {
      mocks.route.name = name;
      mocks.route.params = { accountId: 1, ...params };
      mocks.route.query = Object.fromEntries(
        new URLSearchParams(url.split('?')[1] || '')
      );
    };

    afterEach(() => {
      window.history.replaceState({}, '', '/');
    });

    it('keeps status=all without a refetch in the thread list', async () => {
      window.history.replaceState(
        {},
        '',
        '/app/accounts/1/communication_threads?status=all&assignee_type=all'
      );
      setRoute({
        name: 'communication_threads_dashboard',
        query: { status: 'all', assignee_type: 'all' },
      });
      const store = buildStore();
      const wrapper = mountChatList({
        store,
        props: { communicationThreadMode: true },
      });
      await flushPromises();
      expect(lastListFilters(store)).toMatchObject({ status: 'all' });
      store.dispatch.mockClear();
      mocks.updateUISettings.mockClear();

      openCardRoute({
        name: 'communication_thread_conversation',
        params: { communication_thread_id: '42' },
        url: conversationUrl({
          accountId: 1,
          id: 42,
          status: 'all',
          assigneeType: 'all',
          communicationThread: true,
        }),
      });
      await flushPromises();

      expect(mocks.route.query.status).toBe('all');
      const actions = dispatchedActions(store);
      expect(actions).not.toContain('fetchCommunicationThreads');
      expect(actions).not.toContain('setChatStatusFilter');
      expect(wrapper.findComponent(ChatListHeader).props('activeStatus')).toBe(
        'all'
      );
      expect(mocks.updateUISettings).not.toHaveBeenCalled();
    });

    it('keeps status=all without a refetch in a classic tag list', async () => {
      setRoute({
        name: 'label_conversations',
        params: { label: 'vip' },
        query: { status: 'all' },
      });
      const store = buildStore();
      const wrapper = mountChatList({ store, props: { label: 'vip' } });
      await flushPromises();
      expect(lastListFilters(store)).toMatchObject({
        status: 'all',
        labels: ['vip'],
      });
      store.dispatch.mockClear();

      openCardRoute({
        name: 'conversations_through_label',
        params: { label: 'vip', conversation_id: '7' },
        url: conversationUrl({
          accountId: 1,
          id: 7,
          label: 'vip',
          status: 'all',
        }),
      });
      await flushPromises();

      const actions = dispatchedActions(store);
      expect(actions).not.toContain('fetchAllConversations');
      expect(actions).not.toContain('setChatStatusFilter');
      expect(wrapper.findComponent(ChatListHeader).props('activeStatus')).toBe(
        'all'
      );
    });
  });

  describe('sort order per list context', () => {
    it('restores the sort order of each context when switching contexts', async () => {
      mocks.uiSettings.value = {
        [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]: {
          'assignee:me': { order_by: 'priority_desc' },
        },
      };
      setRoute({
        name: 'communication_threads_dashboard',
        query: { status: 'open', assignee_type: 'all' },
      });
      const store = buildStore();
      mountChatList({ store, props: { communicationThreadMode: true } });
      await flushPromises();
      expect(lastListFilters(store)).toMatchObject({
        sortBy: 'last_activity_at_desc',
      });
      store.dispatch.mockClear();

      mocks.route.query = { status: 'open', assignee_type: 'me' };
      await flushPromises();

      expect(store.dispatch).toHaveBeenCalledWith(
        'setChatSortFilter',
        'priority_desc'
      );
      expect(lastListFilters(store)).toMatchObject({
        assigneeType: 'me',
        sortBy: 'priority_desc',
      });
      store.dispatch.mockClear();

      mocks.route.query = { status: 'open', assignee_type: 'all' };
      await flushPromises();

      expect(store.dispatch).toHaveBeenCalledWith(
        'setChatSortFilter',
        'last_activity_at_desc'
      );
      expect(lastListFilters(store)).toMatchObject({
        assigneeType: 'all',
        sortBy: 'last_activity_at_desc',
      });
    });

    it('stores a chosen sort order for the current context only', async () => {
      setRoute({
        name: 'communication_threads_dashboard',
        query: { status: 'open', assignee_type: 'unassigned' },
      });
      const store = buildStore();
      const wrapper = mountChatList({
        store,
        props: { communicationThreadMode: true },
      });
      await flushPromises();

      wrapper
        .findComponent(ChatListHeader)
        .vm.$emit('basicFilterChange', 'created_at_asc', 'sort');
      await flushPromises();

      const [updates] = mocks.updateUISettings.mock.calls.at(-1);
      expect(updates[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]).toMatchObject({
        'assignee:unassigned': { order_by: 'created_at_asc' },
      });
      expect(
        updates[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]['assignee:all']
      ).toBeUndefined();
      expect(lastListFilters(store)).toMatchObject({
        sortBy: 'created_at_asc',
      });
    });
  });
});
