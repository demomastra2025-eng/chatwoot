import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { reactive } from 'vue';

import ChatList from './ChatList.vue';
import { SERVER_SEARCH_DELAY } from 'dashboard/composables/chatlist/useConversationListSearch';

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
    'isSearchCapped',
    'showOpenAction',
    'showResolvedAction',
    'showSnoozedAction',
  ],
  emits: ['selectAllMatching'],
  template: '<div />',
};

const ACCOUNT_ID = 1;

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  groupDialogOpen: vi.fn(),
  groupDialogClose: vi.fn(),
  deletionOperations: [],
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

vi.mock('dashboard/composables', async importOriginal => ({
  ...(await importOriginal()),
  useAlert: mocks.alert,
}));

const DialogStub = {
  name: 'Dialog',
  props: ['title', 'description', 'isLoading'],
  emits: ['confirm', 'close'],
  methods: { open() {}, close() {} },
  template: '<div />',
};
const ThreadDialogStub = {
  name: 'CommunicationThreadDeleteDialog',
  props: ['threadId', 'channels', 'isLoading'],
  emits: ['confirm', 'close'],
  methods: { open: mocks.groupDialogOpen, close: mocks.groupDialogClose },
  template: '<div />',
};

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
  getters: reactive({
    getConversationDeletionOperations: mocks.deletionOperations,
    getConversationDeletionRevision: 0,
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
  }),
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
  mocks.route = reactive({
    name: 'home',
    path: `/app/accounts/${ACCOUNT_ID}/dashboard`,
    params: { accountId: String(ACCOUNT_ID) },
    query,
  });
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
        Dialog: DialogStub,
        CommunicationThreadDeleteDialog: ThreadDialogStub,
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
    mocks.alert.mockClear();
    mocks.groupDialogOpen.mockClear();
    mocks.groupDialogClose.mockClear();
    mocks.deletionOperations = [];
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

  describe('deletion acknowledgement', () => {
    it.each(['failed', 'partial'])(
      'keeps an unresolved older %s outcome visible as partial when another target is deleted',
      async outcome => {
        mocks.deletionOperations = [
          {
            requestKey: 'older',
            operationId: 90,
            targets:
              outcome === 'partial'
                ? [
                    { id: 12, status: 'deleted' },
                    { id: 13, status: 'failed' },
                  ]
                : [{ id: 12, status: 'failed' }],
          },
          {
            requestKey: 'newer',
            operationId: 91,
            targets: [{ id: 14, status: 'deleted' }],
          },
        ];
        const { wrapper } = await mountChatList({ status: 'open' });
        const banner = wrapper.find(
          '[data-test="conversation-deletion-state"]'
        );
        expect(banner.exists()).toBe(true);
        expect(banner.text()).toContain(
          wrapper.vm.$t('CONVERSATION.DELETION_STATE.PARTIAL')
        );
      }
    );

    it('clears the old failure banner after an explicit retry deletes the same target while retaining both receipts', async () => {
      const failed = {
        requestKey: 'failed',
        operationId: 90,
        targets: [{ id: 12, status: 'failed' }],
      };
      const retry = {
        requestKey: 'retry',
        operationId: 91,
        targets: [{ id: 12, status: 'pending' }],
      };
      mocks.deletionOperations = [failed];
      const { wrapper, store } = await mountChatList({ status: 'open' });
      const banner = () =>
        wrapper.find('[data-test="conversation-deletion-state"]');
      expect(banner().text()).toContain(
        wrapper.vm.$t('CONVERSATION.FAIL_DELETE_CONVERSATION')
      );
      store.dispatch.mockImplementation(type => {
        if (type === 'deleteConversation') {
          store.getters.getConversationDeletionOperations = [failed, retry];
          return Promise.resolve({ outcome: 'pending' });
        }
        return Promise.resolve();
      });
      await wrapper.vm.$.provides.deleteConversation(12);
      wrapper.findComponent(DialogStub).vm.$emit('confirm');
      await flushPromises();
      expect(store.dispatch).toHaveBeenCalledWith(
        'deleteConversation',
        expect.objectContaining({ conversationId: 12 })
      );
      expect(banner().text()).toContain(
        wrapper.vm.$t('CONVERSATION.DELETION_STATE.PENDING_COUNT', { count: 1 })
      );
      const deleted = { ...retry, targets: [{ id: 12, status: 'deleted' }] };
      store.getters.getConversationDeletionOperations = [failed, deleted];
      await flushPromises();
      expect(banner().exists()).toBe(false);
      expect(store.getters.getConversationDeletionOperations).toEqual([
        failed,
        deleted,
      ]);
      expect(failed.targets[0].status).toBe('failed');
      expect(deleted.targets[0].status).toBe('deleted');
    });

    it('shows pending confirmation and checks status without sending DELETE', async () => {
      mocks.deletionOperations = [
        {
          requestKey: 'pending',
          operationId: 91,
          targets: [{ id: 12, status: 'pending' }],
        },
      ];
      const { wrapper, store } = await mountChatList({ status: 'open' });
      const banner = wrapper.find('[data-test="conversation-deletion-state"]');
      expect(banner.exists()).toBe(true);
      await banner.find('button').trigger('click');
      expect(store.dispatch).toHaveBeenCalledWith(
        'reconcileConversationDeletions'
      );
      expect(store.dispatch).not.toHaveBeenCalledWith(
        'deleteConversation',
        expect.anything()
      );
    });

    it('uses pending feedback for an accepted request and success feedback only for a terminal deleted result', async () => {
      const { wrapper, store } = await mountChatList({ status: 'open' });
      store.dispatch.mockImplementation(type =>
        Promise.resolve(
          type === 'deleteConversation' ? { outcome: 'pending' } : []
        )
      );
      await wrapper.vm.$.provides.deleteConversation(12);
      wrapper.findComponent(DialogStub).vm.$emit('confirm');
      await flushPromises();
      expect(mocks.alert).toHaveBeenLastCalledWith(
        wrapper.vm.$t('CONVERSATION.DELETION_STATE.PENDING')
      );
      expect(mocks.alert).not.toHaveBeenCalledWith(
        wrapper.vm.$t('CONVERSATION.SUCCESS_DELETE_CONVERSATION')
      );
      store.dispatch.mockImplementation(type =>
        Promise.resolve(
          type === 'deleteConversation' ? { outcome: 'deleted' } : []
        )
      );
      await wrapper.vm.$.provides.deleteConversation(12);
      wrapper.findComponent(DialogStub).vm.$emit('confirm');
      await flushPromises();
      expect(mocks.alert).toHaveBeenLastCalledWith(
        wrapper.vm.$t('CONVERSATION.SUCCESS_DELETE_CONVERSATION')
      );
    });

    it.each(['account', 'employee', 'mode'])(
      'abandons a single deletion confirmation after a %s switch',
      async kind => {
        const { wrapper, store } = await mountChatList({ status: 'open' });
        await wrapper.vm.$.provides.deleteConversation(12);
        if (kind === 'account') {
          store.getters.getCurrentAccountId = 2;
          mocks.route.params.accountId = '2';
        } else if (kind === 'employee')
          store.getters.getCurrentUser = { id: 8, name: 'Other employee' };
        else await wrapper.setProps({ communicationThreadMode: true });
        wrapper.findComponent(DialogStub).vm.$emit('confirm');
        await flushPromises();
        expect(store.dispatch).not.toHaveBeenCalledWith(
          'deleteConversation',
          expect.anything()
        );
        expect(store.dispatch).not.toHaveBeenCalledWith(
          'deleteCommunicationThreadConversations',
          expect.anything()
        );
      }
    );

    it('abandons a group confirmation opened in account A during lazy import before entering cached account B', async () => {
      const { wrapper, store } = await mountChatList(
        { status: 'open' },
        { communicationThreadMode: true }
      );
      store.getters.getConversationById = () => ({
        id: 7,
        is_communication_thread: true,
        channels: [{ conversation_id: 12 }],
      });
      const opening = wrapper.vm.$.provides.deleteConversation(7);
      store.getters.getCurrentAccountId = 2;
      mocks.route.params.accountId = '2';
      await opening;
      await flushPromises();
      wrapper.findComponent(ThreadDialogStub).vm.$emit('confirm', [12]);
      await flushPromises();
      expect(mocks.groupDialogOpen).not.toHaveBeenCalled();
      expect(store.dispatch).not.toHaveBeenCalledWith(
        'deleteCommunicationThreadConversations',
        expect.anything()
      );
    });

    it('does not let an old deletion finalizer close or change a newly opened confirmation', async () => {
      const { wrapper, store } = await mountChatList({ status: 'open' });
      let finish;
      store.dispatch.mockImplementation(type =>
        type === 'deleteConversation'
          ? new Promise(resolve => {
              finish = resolve;
            })
          : Promise.resolve()
      );
      const dialog = wrapper.findComponent(DialogStub);
      const close = vi.spyOn(dialog.vm, 'close');
      await wrapper.vm.$.provides.deleteConversation(12);
      dialog.vm.$emit('confirm');
      await flushPromises();
      expect(store.dispatch).toHaveBeenCalledWith('deleteConversation', {
        conversationId: 12,
        expectedScope: expect.objectContaining({
          accountId: '1',
          userId: '7',
          kind: 'conversation',
        }),
      });
      await wrapper.vm.$.provides.deleteConversation(13);
      const closeCount = close.mock.calls.length;
      finish({ outcome: 'deleted' });
      await flushPromises();
      expect(close).toHaveBeenCalledTimes(closeCount);
      expect(mocks.alert).not.toHaveBeenCalled();
      store.dispatch.mockImplementation(type =>
        Promise.resolve(
          type === 'deleteConversation' ? { outcome: 'pending' } : []
        )
      );
      dialog.vm.$emit('confirm');
      await flushPromises();
      expect(store.dispatch).toHaveBeenCalledWith('deleteConversation', {
        conversationId: 13,
        expectedScope: expect.objectContaining({
          accountId: '1',
          userId: '7',
          kind: 'conversation',
        }),
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

  describe('search', () => {
    const searchResponse = (ids, meta = {}) => ({
      conversations: ids.map(id => ({ id, meta: { sender: { id } } })),
      meta: { total_count: ids.length, per_page: 25, current_page: 1, ...meta },
    });

    const mountForSearch = async (
      query = { assignee_type: 'me', status: 'open' }
    ) => {
      const mounted = await mountChatList(query);
      mounted.store.dispatch.mockImplementation(name =>
        Promise.resolve(
          name === 'fetchListSearchResults' ? searchResponse([4, 5]) : undefined
        )
      );
      return mounted;
    };

    const typeSearch = async (wrapper, value) => {
      wrapper
        .findComponent({ name: 'ChatListHeader' })
        .vm.$emit('update:localSearchQuery', value);
      await flushPromises();
      await vi.advanceTimersByTimeAsync(SERVER_SEARCH_DELAY);
      await flushPromises();
    };

    const countProps = wrapper =>
      wrapper.findComponent({ name: 'ChatListCount' }).props();

    beforeEach(() => {
      vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it('asks the server for the typed query only, whatever the list is filtered by', async () => {
      const { wrapper, store } = await mountForSearch({
        assignee_type: 'me',
        status: 'open',
        labels_scope: 'any',
        team_scope: 'any',
        unread: 'true',
      });

      await typeSearch(wrapper, '  87072817060 ');

      expect(dispatchedPayloads(store, 'fetchListSearchResults')).toEqual([
        { q: '87072817060', page: 1, communicationThreadMode: false },
      ]);
    });

    it('shows how many conversations the server found and leaves the list and its filters alone', async () => {
      const { wrapper, store } = await mountForSearch();
      const listRequestsBefore = dispatchedPayloads(
        store,
        'fetchAllConversations'
      ).length;
      const filtersBefore = lastListFilters(store);

      await typeSearch(wrapper, 'иван');

      expect(countProps(wrapper)).toMatchObject({
        conversationCount: 2,
        isSearchResult: true,
        isCountApproximate: false,
      });
      expect(dispatchedPayloads(store, 'fetchAllConversations')).toHaveLength(
        listRequestsBefore
      );
      expect(lastListFilters(store)).toEqual(filtersBefore);
    });

    it('shows select all for the server count only after search returns', async () => {
      mocks.bulkSelectionIds = [12];
      const { wrapper } = await mountForSearch();
      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });

      wrapper
        .findComponent({ name: 'ChatListHeader' })
        .vm.$emit('update:localSearchQuery', 'пациент');
      await flushPromises();
      expect(bulkActions.props('canSelectAllMatching')).toBe(false);

      await vi.advanceTimersByTimeAsync(SERVER_SEARCH_DELAY);
      await flushPromises();
      expect(bulkActions.props('canSelectAllMatching')).toBe(true);
      expect(bulkActions.props('selectableConversationsCount')).toBe(2);

      bulkActions.vm.$emit('selectAllMatching');
      expect(mocks.bulkActionMethods.selectAllMatching).toHaveBeenCalledWith(
        { mode: 'basic', q: 'пациент' },
        'Conversation',
        expect.any(String)
      );
    });

    it('shows the capped server count for a thread search', async () => {
      mocks.bulkSelectionIds = [12];
      const { wrapper, store } = await mountChatList(
        { status: 'open' },
        { communicationThreadMode: true }
      );
      store.dispatch.mockImplementation(name =>
        Promise.resolve(
          name === 'fetchListSearchResults'
            ? searchResponse([4], { total_count: 2, capped: true })
            : undefined
        )
      );

      await typeSearch(wrapper, 'пациент');
      const bulkActions = wrapper.findComponent({
        name: 'ConversationBulkActions',
      });
      expect(bulkActions.props('canSelectAllMatching')).toBe(true);
      expect(bulkActions.props('selectableConversationsCount')).toBe(2);
      bulkActions.vm.$emit('selectAllMatching');
      expect(mocks.bulkActionMethods.selectAllMatching).toHaveBeenCalledWith(
        { mode: 'basic', q: 'пациент' },
        'CommunicationThread',
        expect.any(String)
      );
    });

    it('marks the count as approximate when the search was cut at its limit', async () => {
      const { wrapper, store } = await mountForSearch();
      store.dispatch.mockImplementation(name =>
        Promise.resolve(
          name === 'fetchListSearchResults'
            ? searchResponse([4], { total_count: 100, capped: true })
            : undefined
        )
      );

      await typeSearch(wrapper, 'иван');

      expect(countProps(wrapper)).toMatchObject({
        conversationCount: 100,
        isCountApproximate: true,
      });
    });

    it('does not ask the server for a query shorter than three characters', async () => {
      const { wrapper, store } = await mountForSearch();

      await typeSearch(wrapper, 'ив');

      expect(dispatchedPayloads(store, 'fetchListSearchResults')).toHaveLength(
        0
      );
      expect(countProps(wrapper).isSearchResult).toBe(true);
    });

    it('goes back to the list when the search is cleared', async () => {
      const { wrapper, store } = await mountForSearch();
      await typeSearch(wrapper, 'иван');

      await typeSearch(wrapper, '');

      expect(countProps(wrapper).isSearchResult).toBe(false);
      expect(dispatchedPayloads(store, 'fetchListSearchResults')).toHaveLength(
        1
      );
    });
  });
});
