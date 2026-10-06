import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ChatList from './ChatList.vue';

const ConversationBulkActionsStub = {
  name: 'ConversationBulkActions',
  props: [
    'canSelectAllMatching',
    'selectedCount',
    'selectionVersion',
    'selectionContextKey',
    'allConversationsSelected',
    'selectableConversationsCount',
    'selectedInboxes',
    'isSelectingAll',
    'showOpenAction',
    'showResolvedAction',
    'showSnoozedAction',
  ],
  emits: ['selectAllMatching'],
  template: '<div />',
};

const ACCOUNT_ID = 1;

const mocks = vi.hoisted(() => ({
  route: null,
  accountSettings: {},
  router: {
    push: vi.fn(() => Promise.resolve()),
    replace: vi.fn(() => Promise.resolve()),
  },
  crmStore: {
    pipelines: [],
    ui: { isLoadingPipelines: false },
    loadPipelines: vi.fn(() => Promise.resolve()),
  },
  appliedFilters: [],
  savedFolders: [],
  bulkMatchingSelectionRef: null,
  conversationStats: { allCount: 30, mineCount: 0, unAssignedCount: 0 },
  bulkSelectionIds: [],
  bulkActionMethods: {
    selectAllMatching: vi.fn(),
  },
}));

vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => mocks.route,
  useRouter: () => mocks.router,
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => mocks.crmStore,
}));

vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref } = await import('vue');
  return {
    useUISettings: () => ({
      uiSettings: ref({}),
      updateUISettings: vi.fn(),
    }),
  };
});

vi.mock('dashboard/composables/chatlist/useChatListKeyboardEvents', () => ({
  useChatListKeyboardEvents: () => {},
}));

vi.mock('dashboard/composables/chatlist/useBulkActions', async () => {
  const { computed, ref } = await import('vue');
  const selectedConversations = ref([...mocks.bulkSelectionIds]);
  const allMatchingSelection = ref(null);
  mocks.bulkSelectedRef = selectedConversations;
  mocks.bulkMatchingSelectionRef = allMatchingSelection;
  return {
    useBulkActions: () => ({
      selectedConversations,
      selectedCount: computed(() => selectedConversations.value.length),
      selectedInboxes: ref([]),
      allMatchingSelection,
      isSelectingAll: ref(false),
      selectionVersion: ref(0),
      selectConversation: vi.fn(),
      deSelectConversation: vi.fn(),
      selectAllConversations: vi.fn(),
      selectAllMatching: mocks.bulkActionMethods.selectAllMatching,
      setSelectionContext: vi.fn(),
      resetBulkActions: vi.fn(),
      isConversationSelected: vi.fn(() => false),
      onAssignAgent: vi.fn(),
      onAssignLabels: vi.fn(),
      onRemoveLabels: vi.fn(),
      onAssignTeamsForBulk: vi.fn(),
      onUpdateConversations: vi.fn(),
      onMarkConversationsRead: vi.fn(),
    }),
  };
});

vi.mock('shared/composables/useFilter', () => ({
  useFilter: () => ({
    initializeStatusAndAssigneeFilterToModal: vi.fn(),
    initializeInboxTeamAndLabelFilterToModal: vi.fn(() => []),
  }),
}));

vi.mock('dashboard/composables/useConversationRequiredAttributes', () => ({
  useConversationRequiredAttributes: () => ({
    checkMissingAttributes: vi.fn(() => ({ hasMissing: false, missing: [] })),
  }),
}));

vi.mock('./widgets/conversation/CommunicationThreadDeleteDialog.vue', () => ({
  default: { name: 'CommunicationThreadDeleteDialog', template: '<div />' },
}));

const PIPELINES = [
  {
    id: 1,
    name: 'Sales',
    position: 1,
    stages: [
      { id: 11, name: 'New', position: 1 },
      { id: 12, name: 'Won', position: 2 },
    ],
  },
  {
    id: 2,
    name: 'Support',
    position: 2,
    stages: [{ id: 21, name: 'Open', position: 1 }],
  },
];

// Only Sales is shown in Conversation navigation, without its Won stage.
const PIPELINE_VISIBILITY = {
  dashboard_conversation_sidebar_pipeline_visibility: {
    configured: true,
    pipelines: [
      { id: 1, enabled: true, hidden_stage_ids: [12] },
      { id: 2, enabled: false, hidden_stage_ids: [] },
    ],
  },
};

// Mine and Unassigned are switched off for the whole company.
const ASSIGNEE_LISTS_OFF = {
  dashboard_sidebar_hidden_items: ['Conversation:Assignee'],
  dashboard_sidebar_hidden_items_version: 20,
};

const buildStore = () => ({
  getters: {
    getCurrentUser: { id: 7, name: 'Employee' },
    getFilteredConversations: [],
    getMineChats: () => [],
    getAllStatusChats: () => [],
    getUnAssignedChats: () => [],
    getParticipatingChats: () => [],
    getChatListLoadingStatus: false,
    getChatListLoadingError: null,
    getSelectedInbox: null,
    'conversationStats/getStats': mocks.conversationStats,
    getConversationSidebarUnreadCounts: {},
    getAppliedConversationFiltersV2: mocks.appliedFilters,
    'customViews/getConversationCustomViews': mocks.savedFolders,
    'agents/getAgents': [],
    'teams/getTeams': [],
    'inboxes/getInboxes': [],
    'campaigns/getAllCampaigns': [],
    'labels/getLabels': [],
    getCurrentAccountId: ACCOUNT_ID,
    'accounts/getAccount': () => ({
      id: ACCOUNT_ID,
      settings: mocks.accountSettings,
    }),
    'accounts/isFeatureEnabledonAccount': () => false,
    'contacts/getContact': () => ({}),
    'teams/getTeam': () => ({}),
    getConversationById: () => null,
    'inboxes/getInbox': () => ({}),
    'conversationPage/getCurrentPageFilter': () => 0,
    'conversationPage/getHasEndReached': () => false,
    'attributes/getAttributesByModel': () => [],
  },
  dispatch: vi.fn(() => Promise.resolve()),
});

// Installs the fake store the way Vuex does, for `useStore` from vuex and for
// `$store` in `dashboard/composables/store`.
const storePlugin = store => ({
  install(app) {
    app.provide('store', store);
    app.config.globalProperties.$store = store;
  },
});

const mountChatList = async (query, componentProps = {}) => {
  mocks.route = {
    name: 'home',
    path: `/app/accounts/${ACCOUNT_ID}/dashboard`,
    params: { accountId: String(ACCOUNT_ID) },
    query,
  };
  if (mocks.bulkSelectedRef) {
    mocks.bulkSelectedRef.value = [...mocks.bulkSelectionIds];
  }
  if (mocks.bulkMatchingSelectionRef) {
    mocks.bulkMatchingSelectionRef.value = null;
  }
  const store = buildStore();
  const wrapper = shallowMount(ChatList, {
    props: componentProps,
    global: {
      plugins: [storePlugin(store)],
      stubs: {
        ConversationBulkActions: ConversationBulkActionsStub,
      },
    },
  });
  await flushPromises();
  return { wrapper, store };
};

const dispatchedPayloads = (store, action) =>
  store.dispatch.mock.calls
    .filter(([name]) => name === action)
    .map(([, payload]) => payload);

const lastListFilters = store =>
  dispatchedPayloads(store, 'updateChatListFilters').at(-1);

const loadErrorBanner = wrapper =>
  wrapper.find('[data-test="crm-pipelines-load-error"]');

describe('ChatList', () => {
  beforeEach(() => {
    mocks.accountSettings = {};
    mocks.router.push.mockClear();
    mocks.router.replace.mockClear();
    mocks.crmStore.pipelines = [];
    mocks.crmStore.ui.isLoadingPipelines = false;
    mocks.crmStore.loadPipelines = vi.fn(() => Promise.resolve());
    mocks.appliedFilters = [];
    mocks.savedFolders = [];
    if (mocks.bulkMatchingSelectionRef) {
      mocks.bulkMatchingSelectionRef.value = null;
    }
    mocks.conversationStats = {
      allCount: 30,
      mineCount: 0,
      unAssignedCount: 0,
    };
    mocks.bulkSelectionIds = [];
    mocks.bulkActionMethods.selectAllMatching.mockClear();
  });

  describe('assignee list', () => {
    it('fetches the requested assignee list while the lists are on', async () => {
      const { store } = await mountChatList({
        assignee_type: 'me',
        status: 'open',
      });

      expect(lastListFilters(store)).toMatchObject({ assigneeType: 'me' });
      expect(dispatchedPayloads(store, 'fetchAllConversations')).toHaveLength(
        1
      );
    });

    it('stays on All when the company switched Mine and Unassigned off', async () => {
      mocks.accountSettings = ASSIGNEE_LISTS_OFF;

      const { store } = await mountChatList({
        assignee_type: 'me',
        status: 'open',
      });

      expect(lastListFilters(store)).toMatchObject({ assigneeType: 'all' });
      expect(dispatchedPayloads(store, 'fetchAllConversations')).toHaveLength(
        1
      );
    });

    it('lists every assignee inside an exclusive scope', async () => {
      const { store } = await mountChatList({
        assignee_type: 'unassigned',
        labels_scope: 'any',
        status: 'open',
      });

      expect(lastListFilters(store)).toMatchObject({
        assigneeType: 'all',
        labelsScope: 'any',
      });
    });
  });

  describe('pipeline scope', () => {
    beforeEach(() => {
      mocks.accountSettings = PIPELINE_VISIBILITY;
      mocks.crmStore.pipelines = PIPELINES;
    });

    it('keeps a visible pipeline in the URL', async () => {
      const { store } = await mountChatList({
        crm_pipeline_id: '1',
        crm_stage_id: '11',
        status: 'open',
      });

      expect(mocks.router.replace).not.toHaveBeenCalled();
      expect(lastListFilters(store)).toMatchObject({
        crmPipelineId: '1',
        crmStageId: '11',
      });
    });

    it('falls back to the account-wide list for a hidden pipeline', async () => {
      await mountChatList({
        crm_pipeline_id: '2',
        assignee_type: 'me',
        status: 'resolved',
      });

      expect(mocks.router.replace).toHaveBeenCalledTimes(1);
      const [target] = mocks.router.replace.mock.calls[0];
      expect(target.name).toBe('home');
      expect(target.params).toEqual({ accountId: String(ACCOUNT_ID) });
      expect(target.query).not.toHaveProperty('crm_pipeline_id');
      expect(target.query).not.toHaveProperty('crm_stage_id');
      expect(target.query).toMatchObject({
        assignee_type: 'all',
        status: 'resolved',
      });
    });

    it('falls back to the account-wide list for a hidden stage', async () => {
      await mountChatList({
        crm_pipeline_id: '1',
        crm_stage_id: '12',
        status: 'open',
      });

      expect(mocks.router.replace).toHaveBeenCalledTimes(1);
      const [target] = mocks.router.replace.mock.calls[0];
      expect(target.query).not.toHaveProperty('crm_pipeline_id');
      expect(target.query).not.toHaveProperty('crm_stage_id');
    });
  });

  describe('when pipelines cannot be loaded', () => {
    beforeEach(() => {
      mocks.accountSettings = PIPELINE_VISIBILITY;
    });

    it('keeps the filter, shows the retry banner and recovers on retry', async () => {
      mocks.crmStore.loadPipelines = vi
        .fn()
        .mockRejectedValueOnce(new Error('network'))
        .mockImplementationOnce(() => {
          mocks.crmStore.pipelines = PIPELINES;
          return Promise.resolve();
        });

      const { wrapper, store } = await mountChatList({
        crm_pipeline_id: '1',
        status: 'open',
      });

      expect(loadErrorBanner(wrapper).exists()).toBe(true);
      expect(loadErrorBanner(wrapper).text()).toContain(
        wrapper.vm.$t('CRM.DEALS.PIPELINES_LOAD_ERROR')
      );
      expect(mocks.router.replace).not.toHaveBeenCalled();
      expect(lastListFilters(store)).toMatchObject({ crmPipelineId: '1' });

      await loadErrorBanner(wrapper).find('button').trigger('click');
      await flushPromises();

      expect(mocks.crmStore.loadPipelines).toHaveBeenCalledTimes(2);
      expect(loadErrorBanner(wrapper).exists()).toBe(false);
      expect(mocks.router.replace).not.toHaveBeenCalled();
    });

    it('does not show the banner without a pipeline filter', async () => {
      mocks.crmStore.loadPipelines = vi.fn(() =>
        Promise.reject(new Error('network'))
      );

      const { wrapper } = await mountChatList({ status: 'open' });

      expect(mocks.crmStore.loadPipelines).not.toHaveBeenCalled();
      expect(loadErrorBanner(wrapper).exists()).toBe(false);
    });
  });

  describe('all matching selection filters', () => {
    it('passes the complete basic context and conversation resource type to the snapshot request', async () => {
      mocks.bulkSelectionIds = [12];
      mocks.conversationStats.allCount = 120;
      const { wrapper } = await mountChatList(
        { status: 'open' },
        {
          conversationInbox: 4,
          teamId: 9,
          label: 'vip',
          conversationType: 'email',
        }
      );
      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });

      expect(bulkActions.props('canSelectAllMatching')).toBe(true);
      bulkActions.vm.$emit('selectAllMatching');

      expect(mocks.bulkActionMethods.selectAllMatching).toHaveBeenCalledWith(
        expect.objectContaining({
          mode: 'basic',
          inbox_id: 4,
          status: 'open',
          assignee_type: 'all',
          labels: ['vip'],
          team_id: 9,
          conversation_type: 'email',
        }),
        'Conversation',
        expect.any(String)
      );
    });

    it('passes advanced filters with the sidebar contexts used by the list', async () => {
      mocks.bulkSelectionIds = [12];
      mocks.appliedFilters = [
        {
          attributeKey: 'status',
          filterOperator: 'equal_to',
          values: ['pending'],
          queryOperator: null,
        },
      ];
      mocks.conversationStats.allCount = 120;

      const { wrapper } = await mountChatList({
        status: 'open',
        crm_pipeline_id: '4',
        crm_stage_id: '8',
        appointment_status: 'confirmed',
        labels_scope: 'any',
        team_scope: 'any',
        unread: 'true',
      });
      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });
      bulkActions.vm.$emit('selectAllMatching');

      expect(mocks.bulkActionMethods.selectAllMatching).toHaveBeenCalledWith(
        expect.objectContaining({
          mode: 'advanced',
          query_data: expect.objectContaining({
            payload: expect.arrayContaining([
              expect.objectContaining({ attribute_key: 'status' }),
            ]),
          }),
          crm_pipeline_id: '4',
          crm_stage_id: '8',
          appointment_status: 'confirmed',
          labels_scope: 'any',
          team_scope: 'any',
          unread: true,
        }),
        'Conversation',
        expect.any(String)
      );
    });

    it('passes a saved folder query and its sidebar filters as one advanced snapshot', async () => {
      mocks.bulkSelectionIds = [12];
      mocks.savedFolders = [
        {
          id: 7,
          query: {
            payload: [
              {
                attributeKey: 'status',
                filterOperator: 'equal_to',
                values: ['pending'],
                queryOperator: null,
              },
            ],
          },
        },
      ];
      mocks.conversationStats.allCount = 120;
      const { wrapper } = await mountChatList(
        {
          crm_pipeline_id: '4',
          crm_stage_id: '8',
          appointment_status: 'confirmed',
          labels_scope: 'any',
          team_scope: 'any',
          unread: 'true',
        },
        { foldersId: 7 }
      );
      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });
      bulkActions.vm.$emit('selectAllMatching');

      expect(mocks.bulkActionMethods.selectAllMatching).toHaveBeenCalledWith(
        expect.objectContaining({
          mode: 'advanced',
          query_data: expect.objectContaining({
            payload: expect.arrayContaining([
              expect.objectContaining({ attribute_key: 'status' }),
            ]),
          }),
          crm_pipeline_id: '4',
          crm_stage_id: '8',
          appointment_status: 'confirmed',
          labels_scope: 'any',
          team_scope: 'any',
          unread: true,
        }),
        'Conversation',
        expect.any(String)
      );
    });

    it('keeps status actions available for a resolved saved folder snapshot when the page status is open', async () => {
      mocks.bulkSelectionIds = [12];
      mocks.savedFolders = [
        {
          id: 7,
          query: {
            payload: [
              {
                attributeKey: 'status',
                filterOperator: 'equal_to',
                values: ['resolved'],
                queryOperator: null,
              },
            ],
          },
        },
      ];

      const { wrapper } = await mountChatList(
        { status: 'open' },
        { foldersId: 7 }
      );
      mocks.bulkMatchingSelectionRef.value = {
        token: 'resolved-folder-token',
        count: 40,
      };
      await flushPromises();

      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });
      expect(bulkActions.props('showOpenAction')).toBe(false);
      expect(bulkActions.props('showResolvedAction')).toBe(false);
      expect(bulkActions.props('showSnoozedAction')).toBe(false);
    });

    it('keeps status actions available for mixed-status communication thread snapshots', async () => {
      mocks.bulkSelectionIds = [12];
      const { wrapper } = await mountChatList(
        { status: 'all' },
        { communicationThreadMode: true }
      );
      mocks.bulkMatchingSelectionRef.value = {
        token: 'mixed-thread-token',
        count: 40,
      };
      await flushPromises();

      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });
      expect(bulkActions.props('showOpenAction')).toBe(false);
      expect(bulkActions.props('showResolvedAction')).toBe(false);
      expect(bulkActions.props('showSnoozedAction')).toBe(false);
    });

    it('sends thread type and suppresses all matching during local loaded-content search', async () => {
      mocks.bulkSelectionIds = [12];
      mocks.conversationStats.allCount = 120;
      const { wrapper } = await mountChatList(
        { status: 'open' },
        { communicationThreadMode: true }
      );
      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });

      expect(bulkActions.props('canSelectAllMatching')).toBe(true);
      wrapper
        .findComponent({ name: 'ChatListHeader' })
        .vm.$emit('update:localSearchQuery', 'customer');
      await flushPromises();

      expect(bulkActions.props('canSelectAllMatching')).toBe(false);
      bulkActions.vm.$emit('selectAllMatching');
      expect(mocks.bulkActionMethods.selectAllMatching).not.toHaveBeenCalled();
    });
  });
});
