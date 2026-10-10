import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { nextTick, reactive } from 'vue';

const { runtime, referencesStore } = vi.hoisted(() => ({
  runtime: {
    accountId: null,
    dispatch: vi.fn(),
    routeQuery: {},
    routeParams: null,
    routerBack: vi.fn(),
    routerPush: vi.fn(),
    routerReplace: vi.fn(),
  },
  referencesStore: {
    dealFieldDefinitions: [],
    pipelines: [
      {
        id: 10,
        active: true,
        default: true,
        name: 'Sales',
        stages: [
          { id: 100, active: true, name: 'New', position: 1 },
          { id: 200, active: true, name: 'Qualified', position: 2 },
        ],
      },
    ],
    taskFieldDefinitions: [],
    taskStatuses: [],
    taskTypes: [],
    loadFieldDefinitions: vi.fn(),
    loadPipelines: vi.fn(),
    loadTaskStatuses: vi.fn(),
    loadTaskTypes: vi.fn(),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { __v_isRef: true, value: 'en' },
    t: key => key,
  }),
}));
// A partial mock: a module that is imported lazily after a test has finished
// (dashboard/routes/index.js) still needs the real createRouter.
vi.mock('vue-router', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    onBeforeRouteLeave: vi.fn(),
    useRoute: () => ({
      query: runtime.routeQuery,
      params: runtime.routeParams,
    }),
    useRouter: () => ({
      back: runtime.routerBack,
      push: runtime.routerPush,
      replace: runtime.routerReplace,
      resolve: vi.fn(() => ({ href: '/app/accounts/1/contacts/edit' })),
    }),
  };
});
vi.mock('dashboard/api/crm/deals', () => ({
  default: new Proxy(
    {
      create: vi.fn(),
      get: vi.fn(),
      show: vi.fn(),
      timeline: vi.fn(),
      transitionStage: vi.fn(),
      update: vi.fn(),
    },
    { get: (target, key) => target[key] || vi.fn() }
  ),
}));
vi.mock('dashboard/api/companies', () => ({
  default: { get: vi.fn() },
}));
vi.mock('dashboard/api/contacts', () => ({
  default: { get: vi.fn(), getCommunicationThreads: vi.fn(), show: vi.fn() },
}));
vi.mock('dashboard/api/conversations', () => ({
  default: { create: vi.fn(), get: vi.fn() },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));
vi.mock('dashboard/composables/store', async () => {
  const { ref } = await vi.importActual('vue');
  runtime.accountId ||= ref(1);

  return {
    useMapGetter: key => {
      const values = {
        getCurrentAccountId: runtime.accountId,
        getCurrentUser: { __v_isRef: true, value: { id: 1 } },
        'agents/getAgents': {
          __v_isRef: true,
          value: [{ id: 1, name: 'Agent' }],
        },
        'accounts/isFeatureEnabledonAccount': {
          __v_isRef: true,
          value: () => true,
        },
        'teams/getTeams': { __v_isRef: true, value: [] },
      };
      return values[key] || { __v_isRef: true, value: null };
    },
    useStore: () => ({ dispatch: runtime.dispatch }),
  };
});
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => referencesStore,
}));

import CrmDealsAPI from 'dashboard/api/crm/deals';
import ConversationAPI from 'dashboard/api/conversations';
import ContactAPI from 'dashboard/api/contacts';
import CompanyAPI from 'dashboard/api/companies';
import { useAlert } from 'dashboard/composables';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import CrmDealsPage from './pages/CrmDealsPage.vue';

const response = (payload, meta = {}) => ({ data: { payload, meta } });
const deferred = () => {
  let reject;
  let resolve;
  const promise = new Promise((done, fail) => {
    reject = fail;
    resolve = done;
  });
  return { promise, reject, resolve };
};
const deal = (id, title = `Deal ${id}`) => ({
  id,
  accountId: runtime.accountId.value,
  lockVersion: 1,
  pipelineId: 10,
  stageId: 100,
  title,
});
const wrappers = [];

const mountPage = async (stubs = {}, components = {}) => {
  const wrapper = shallowMount(CrmDealsPage, {
    global: {
      components,
      mocks: { $t: key => key },
      stubs: { transition: false, ...stubs },
    },
  });
  wrappers.push(wrapper);
  await flushPromises();
  return { state: wrapper.vm.$.setupState, wrapper };
};

// The payload the server broadcasts for a deal event (see
// action_cable_listener.rb), as emitted by helper/actionCable.js.
const crmDealEvent = (dealPayload, event = 'crm.deal.updated') => ({
  account_id: 1,
  deal: { pipeline_id: 10, stage_id: 100, ...dealPayload },
  event,
  meta: { event_type: 'deal_updated' },
});
const emitCrmDealEvent = (...args) =>
  emitter.emit(BUS_EVENTS.CRM_DEAL_REALTIME_EVENT, crmDealEvent(...args));
const boardMeta = (overrides = {}) => ({
  count: 1,
  has_more: false,
  page: 1,
  per_page: 8,
  stage_counts: { 100: 1 },
  total_count: 1,
  ...overrides,
});

beforeEach(() => {
  vi.clearAllMocks();
  localStorage.clear();
  sessionStorage.clear();
  runtime.accountId.value = 1;
  runtime.routeParams = reactive({ accountId: 1 });
  Object.keys(runtime.routeQuery).forEach(
    key => delete runtime.routeQuery[key]
  );
  runtime.routerReplace.mockReset().mockResolvedValue(undefined);
  runtime.dispatch.mockReset().mockResolvedValue(undefined);
  referencesStore.loadFieldDefinitions.mockResolvedValue([]);
  referencesStore.loadPipelines.mockResolvedValue(referencesStore.pipelines);
  referencesStore.loadTaskStatuses.mockResolvedValue([]);
  referencesStore.loadTaskTypes.mockResolvedValue([]);
  CrmDealsAPI.get.mockResolvedValue(
    response([deal(1)], {
      count: 1,
      has_more: false,
      page: 1,
      per_page: 8,
      stage_counts: { 100: 1 },
      total_count: 1,
    })
  );
  CrmDealsAPI.create.mockReset();
  CrmDealsAPI.show.mockReset();
  CrmDealsAPI.timeline.mockReset().mockResolvedValue(response([]));
  CrmDealsAPI.update.mockReset();
  ContactAPI.get.mockResolvedValue(response([]));
  ContactAPI.show.mockReset();
  CompanyAPI.get.mockResolvedValue(response([]));
  ConversationAPI.create.mockReset();
  ContactAPI.getCommunicationThreads
    .mockReset()
    .mockResolvedValue(response([{ id: 41, timestamp: 1 }]));
  useAlert.mockClear();
});

afterEach(() => {
  wrappers.splice(0).forEach(wrapper => wrapper.unmount());
  window.history.replaceState(null, '');
});

it('exposes a localized string when the initial load fails', async () => {
  CrmDealsAPI.get.mockRejectedValueOnce({
    code: 'ERR_BAD_REQUEST',
    message: 'Request failed with status code 409',
    response: { data: { code: 'STALE_RECORD' }, status: 409 },
  });

  const { state } = await mountPage();

  expect(state.ui.error).toBe('CRM.ERRORS.STALE_RECORD');
});

it('keeps the settings gear after create in the Deals header', async () => {
  const { state, wrapper } = await mountPage();
  const header = wrapper.findComponent({ name: 'SchedulingPageHeader' });
  const buttons = header.vm.$slots.actions().filter(node => node.props?.icon);
  const gear = buttons.at(-1);

  expect(buttons.at(-2).props.icon).toBe('i-lucide-plus');
  expect(gear.props).toMatchObject({
    icon: 'i-lucide-settings',
    size: 'sm',
    color: 'slate',
    variant: 'ghost',
    class: '!size-8 !text-n-slate-11 hover:!text-n-slate-12',
    'aria-label': 'SIDEBAR.SETTINGS',
    title: 'SIDEBAR.SETTINGS',
  });
  state.openDealSettings();
  expect(runtime.routerPush).toHaveBeenCalledWith({
    name: 'crm_settings_index',
    params: { accountId: 1 },
    query: { pipelineId: 10 },
  });
});

it('retries the complete page bootstrap after a reference request fails', async () => {
  referencesStore.loadPipelines.mockRejectedValueOnce(
    new Error('pipelines unavailable')
  );

  const { state, wrapper } = await mountPage();

  expect(state.ui.isLoading).toBe(false);
  expect(state.ui.error).toBe('pipelines unavailable');
  expect(wrapper.findComponent({ name: 'SchedulingErrorState' }).exists()).toBe(
    true
  );
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();

  runtime.dispatch.mockClear();
  wrapper.findComponent({ name: 'SchedulingErrorState' }).vm.$emit('retry');
  await flushPromises();

  expect(referencesStore.loadPipelines).toHaveBeenCalledTimes(2);
  expect(runtime.dispatch).toHaveBeenCalledWith('agents/get', {
    throwOnError: true,
  });
  expect(runtime.dispatch).toHaveBeenCalledWith('teams/get');
  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);
  expect(state.ui.error).toBeNull();
  expect(state.deals.map(item => item.id)).toEqual([1]);
});

it('does not publish an obsolete bootstrap failure after a retry succeeds', async () => {
  const { state } = await mountPage();
  const obsolete = deferred();
  referencesStore.loadPipelines
    .mockReturnValueOnce(obsolete.promise)
    .mockResolvedValueOnce(referencesStore.pipelines);

  const firstRetry = state.initializeDealsPage();
  await flushPromises();
  await state.initializeDealsPage();
  obsolete.reject(new Error('obsolete bootstrap failed'));
  await firstRetry;

  expect(state.ui.isLoading).toBe(false);
  expect(state.ui.error).toBeNull();
  expect(state.deals.map(item => item.id)).toEqual([1]);
});

it('keeps loading owned by a newer list request', async () => {
  const { state } = await mountPage();
  const bootstrapList = deferred();
  const currentList = deferred();
  CrmDealsAPI.get
    .mockReset()
    .mockReturnValueOnce(bootstrapList.promise)
    .mockReturnValueOnce(currentList.promise);

  const bootstrap = state.initializeDealsPage();
  await flushPromises();
  const current = state.loadDeals();
  bootstrapList.resolve(response([deal(11)]));
  await bootstrap;

  expect(state.ui.isLoading).toBe(true);
  currentList.resolve(response([deal(22)]));
  await current;
  expect(state.ui.isLoading).toBe(false);
  expect(state.deals.map(item => item.id)).toEqual([22]);
});

it('opens a board deal on its own URL and keeps the current query', async () => {
  const { state } = await mountPage();
  runtime.routeQuery.pipelineId = '10';

  state.openDealPage(deal(11));

  expect(runtime.routerPush).toHaveBeenCalledWith({
    name: 'crm_deal_show',
    params: { accountId: 1, dealId: 11 },
    query: { pipelineId: '10' },
  });
  expect(state.drawerOpen).toBe(false);
});

it('restores list scroll when returning from a deal page', async () => {
  const { state } = await mountPage();
  state.currentPresentation = 'list';
  await flushPromises();
  const scrollElement = state.dealsListScrollRef;
  scrollElement.scrollTop = 87;

  state.openDealPage(deal(11));
  scrollElement.scrollTop = 0;
  await state.restoreDealListScroll();

  expect(scrollElement.scrollTop).toBe(87);
});

it('redirects legacy deal query links to the full page', async () => {
  const { state } = await mountPage();
  runtime.routeQuery.dealId = '11';
  runtime.routeQuery.pipelineId = '10';

  await state.handleDealUiActionQuery();

  expect(runtime.routerReplace).toHaveBeenCalledWith({
    name: 'crm_deal_show',
    params: { accountId: 1, dealId: 11 },
    query: { pipelineId: '10' },
  });
  expect(CrmDealsAPI.show).not.toHaveBeenCalled();
});

it('loads a deep-linked deal without loading the board', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));

  const { state, wrapper } = await mountPage();

  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
  expect(CrmDealsAPI.show).toHaveBeenCalledWith(11);
  expect(state.selectedDeal.id).toBe(11);
  expect(state.drawerOpen).toBe(true);
  expect(wrapper.find('.modal-mask').exists()).toBe(false);
  expect(wrapper.find('[data-testid="crm-deal-card"]').exists()).toBe(true);
  expect(wrapper.find('[data-testid="crm-deal-chat"]').exists()).toBe(true);
});

it('keeps a linked dialog beside the card on the deal URL', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(
    response({
      ...deal(11),
      originatingConversationId: 11963,
      originatingConversationDisplayId: 185,
    })
  );

  const { state, wrapper } = await mountPage();
  const card = wrapper.find('[data-testid="crm-deal-card"]');
  const chat = wrapper.find('[data-testid="crm-deal-chat"]');

  expect(card.classes()).toContain('lg:w-1/3');
  expect(chat.exists()).toBe(true);
  expect(state.linkedConversationDisplayId).toBe('185');
  expect(runtime.routerPush).not.toHaveBeenCalled();
});

it('switches between card and chat on narrow screens without changing route', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(
    response({ ...deal(11), originatingConversationDisplayId: 185 })
  );

  const { state, wrapper } = await mountPage();
  const switcher = wrapper.find('[data-testid="crm-deal-page-tabs"]');
  const tabs = switcher.findAll('[role="tab"]');
  expect(switcher.attributes('aria-label')).toBe('CRM.DEALS.TABS.PAGE_LABEL');
  expect(tabs).toHaveLength(2);
  expect(tabs[0].attributes('aria-selected')).toBe('true');
  expect(state.dealPageTab).toBe('deal');

  await tabs[1].trigger('click');
  expect(tabs[1].attributes('aria-selected')).toBe('true');
  expect(wrapper.find('[data-testid="crm-deal-card"]').classes()).toContain(
    'hidden'
  );
  expect(state.dealPageTab).toBe('chat');
  expect(wrapper.find('[data-testid="crm-deal-chat"]').exists()).toBe(true);
  expect(runtime.routerPush).not.toHaveBeenCalled();

  await tabs[0].trigger('click');
  expect(tabs[0].attributes('aria-selected')).toBe('true');
  expect(wrapper.find('[data-testid="crm-deal-card"]').classes()).toContain(
    'flex'
  );
});

it('keeps the deal URL after creating a dialog from its chat panel', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({
      ...deal(11),
      dealContacts: [{ contactId: 7 }],
      primaryContactId: 7,
    })
  );
  ContactAPI.show.mockResolvedValue(response({ id: 7, name: 'Test' }));
  ConversationAPI.create.mockResolvedValueOnce({
    data: { display_id: 185, id: 11963 },
  });

  const { state } = await mountPage();
  await state.createDealConversation({ contactId: 7, inbox: { id: 9 } });

  expect(ConversationAPI.create).toHaveBeenCalled();
  // Only the contact link is saved, never the rest of the card.
  expect(CrmDealsAPI.update).toHaveBeenCalledExactlyOnceWith(11, {
    contact_ids: [7],
    lock_version: 1,
    primary_contact_id: 7,
  });
  expect(state.dealConversationDraft.communicationThreadDisplayId).toBe(41);
  expect(state.linkedConversationId).toBe(11963);
  expect(state.linkedConversationDisplayId).toBe('185');
  expect(runtime.routerPush).not.toHaveBeenCalled();
});

it('shows a retryable page error when a deep-linked deal cannot load', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockRejectedValueOnce(new Error('deal unavailable'));

  const { state, wrapper } = await mountPage();

  expect(state.drawerOpen).toBe(false);
  expect(state.dealPageError).toBe('deal unavailable');
  expect(state.ui.error).toBeNull();
  expect(wrapper.findComponent({ name: 'SchedulingErrorState' }).exists()).toBe(
    true
  );
});

it('returns to the board history entry or falls back for a deep link', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));
  const { state } = await mountPage();

  state.returnToDeals();
  expect(runtime.routerPush).toHaveBeenCalledWith({
    name: 'crm_deals_index',
    params: { accountId: 1 },
    query: {},
  });

  window.history.replaceState({ back: '/app/accounts/1/deals?q=old' }, '');
  state.returnToDeals();
  expect(runtime.routerBack).toHaveBeenCalledTimes(1);
});

it('opens a linked dialog on its full page route', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));
  const { state } = await mountPage();

  state.form.originatingConversationId = 77;
  state.form.originatingConversationDisplayId = '#19';
  state.openLinkedConversation();
  expect(runtime.routerPush).toHaveBeenCalledWith({
    name: 'inbox_conversation',
    params: { accountId: 1, conversation_id: '19' },
  });

  state.form.originatingCommunicationThreadId = 88;
  state.form.originatingCommunicationThreadDisplayId = '#29';
  state.openLinkedConversation();
  expect(runtime.routerPush).toHaveBeenCalledWith({
    name: 'communication_thread_conversation',
    params: { accountId: 1, communication_thread_id: '29' },
  });
});

it('only opens the newest route deal when requests finish in reverse', async () => {
  runtime.routeParams.dealId = '11';
  const obsolete = deferred();
  const current = deferred();
  CrmDealsAPI.show
    .mockReturnValueOnce(obsolete.promise)
    .mockReturnValueOnce(current.promise);
  const { state } = await mountPage();

  runtime.routeParams.dealId = '22';
  await flushPromises();
  current.resolve(response(deal(22)));
  await flushPromises();
  obsolete.resolve(response(deal(11)));
  await flushPromises();

  expect(state.selectedDeal.id).toBe(22);
  expect(state.drawerOpen).toBe(true);
});

it('does not publish a pending route deal after an account switch', async () => {
  runtime.routeParams.dealId = '11';
  const obsolete = deferred();
  const accountBootstrap = deferred();
  CrmDealsAPI.show.mockReturnValueOnce(obsolete.promise);
  const { state, wrapper } = await mountPage();

  referencesStore.loadPipelines.mockReturnValueOnce(accountBootstrap.promise);
  runtime.accountId.value = 2;
  await flushPromises();
  obsolete.resolve(response(deal(11)));
  await flushPromises();

  expect(state.selectedDeal).toBeNull();
  expect(state.drawerOpen).toBe(false);
  wrapper.unmount();
  accountBootstrap.resolve(referencesStore.pipelines);
});

it('does not publish a pending route deal after unmount', async () => {
  runtime.routeParams.dealId = '11';
  const obsolete = deferred();
  CrmDealsAPI.show.mockReturnValueOnce(obsolete.promise);
  const { state, wrapper } = await mountPage();

  wrapper.unmount();
  obsolete.resolve(response(deal(11)));
  await flushPromises();

  expect(state.selectedDeal).toBeNull();
});

it('renders a filtered-empty list without a create action', async () => {
  const { state, wrapper } = await mountPage();
  state.currentPresentation = 'list';
  state.listQuickFilters.q = 'missing deal';
  state.deals = [];
  await flushPromises();

  const emptyState = wrapper.findComponent({ name: 'SchedulingEmptyState' });
  expect(emptyState.props('description')).toBe('CRM.DEALS.LIST.EMPTY_FILTERED');
  expect(emptyState.props('actionLabel')).toBe('');
});

it('does not publish an old timeline after the deal drawer closes', async () => {
  const { state } = await mountPage();
  const pending = deferred();
  state.selectedDeal = deal(1);
  state.drawerOpen = true;
  CrmDealsAPI.timeline.mockReturnValueOnce(pending.promise);

  const loading = state.loadTimeline(1);
  state.closeDrawer();
  pending.resolve(response([{ id: 'obsolete-history' }]));
  await loading;

  expect(state.timelineItems).toEqual([]);
  expect(state.ui.isTimelineLoading).toBe(false);
});

it('keeps the newest timeline when same-deal requests finish in reverse', async () => {
  const { state } = await mountPage();
  const previous = deferred();
  const current = deferred();
  state.selectedDeal = deal(1);
  state.drawerOpen = true;
  CrmDealsAPI.timeline
    .mockReturnValueOnce(previous.promise)
    .mockReturnValueOnce(current.promise);

  const first = state.loadTimeline(1);
  const second = state.loadTimeline(1);
  current.resolve(response([{ id: 'current-history' }]));
  await second;
  previous.resolve(response([{ id: 'obsolete-history' }]));
  await first;

  expect(state.timelineItems).toEqual([{ id: 'current-history' }]);
  expect(state.ui.isTimelineLoading).toBe(false);
});

it('shows a retryable timeline error instead of confirmed-empty history', async () => {
  const { state } = await mountPage();
  state.selectedDeal = deal(1);
  state.drawerOpen = true;
  CrmDealsAPI.timeline.mockRejectedValueOnce(new Error('timeline unavailable'));

  await state.loadTimeline(1);

  expect(state.timelineItems).toEqual([]);
  expect(state.ui.timelineError).toBe('timeline unavailable');
  expect(state.ui.isTimelineLoading).toBe(false);

  CrmDealsAPI.timeline.mockResolvedValueOnce(
    response([{ id: 'restored-history' }])
  );
  await state.loadTimeline(1);

  expect(state.ui.timelineError).toBeNull();
  expect(state.timelineItems).toEqual([{ id: 'restored-history' }]);
});

it('keeps a failed conversation-context lookup out of the empty placeholder', async () => {
  const { state } = await mountPage();
  ContactAPI.getCommunicationThreads.mockRejectedValueOnce(
    new Error('context unavailable')
  );

  await state.loadDealConversationContext(9);

  expect(state.dealConversationDraft.contextError).toBe(
    'CRM.DEALS.CONVERSATION_PLACEHOLDER.THREADS_LOAD_ERROR'
  );
  expect(state.dealConversationDraft.communicationThreadDisplayId).toBe('');
  expect(state.dealConversationDraft.contactableInboxes).toEqual([]);

  ContactAPI.getCommunicationThreads.mockResolvedValueOnce(
    response([{ id: 42, timestamp: 2 }])
  );
  await state.loadDealConversationContext(9);

  expect(state.dealConversationDraft.contextError).toBeNull();
  expect(state.dealConversationDraft.communicationThreadDisplayId).toBe(42);
});

it('does not cache an older same-contact conversation-context response', async () => {
  const { state } = await mountPage();
  const older = deferred();
  const newer = deferred();
  ContactAPI.getCommunicationThreads
    .mockImplementationOnce(() => older.promise)
    .mockImplementationOnce(() => newer.promise);

  const olderLoad = state.loadDealConversationContext(9);
  const newerLoad = state.loadDealConversationContext(9);

  newer.resolve(response([{ id: 42, timestamp: 2 }]));
  await newerLoad;
  older.resolve(response([{ id: 41, timestamp: 1 }]));
  await olderLoad;

  await state.loadDealConversationContext(9);

  expect(ContactAPI.getCommunicationThreads).toHaveBeenCalledTimes(2);
  expect(state.dealConversationDraft.communicationThreadDisplayId).toBe(42);
});

it('stops conversation creation after the deal editor closes', async () => {
  const { state } = await mountPage();
  const pending = deferred();
  state.selectedDeal = deal(1);
  state.drawerOpen = true;
  ConversationAPI.create.mockReturnValueOnce(pending.promise);

  const creating = state.createDealConversation({
    contactId: 9,
    inbox: { id: 3, value: 3 },
  });
  state.closeDrawer();
  pending.resolve(response({ id: 11 }));
  await creating;

  expect(CrmDealsAPI.update).not.toHaveBeenCalled();
  expect(state.showLinkedConversationPanel).toBe(false);
  expect(state.dealConversationDraft.isCreating).toBe(false);
  expect(useAlert).not.toHaveBeenCalled();
});

it('rolls a rejected board move back with its stage counts', async () => {
  const { state } = await mountPage();
  CrmDealsAPI.transitionStage.mockRejectedValueOnce({
    response: { data: { code: 'STALE_RECORD' }, status: 409 },
  });

  await state.handleDealStageChange({
    deal: state.deals[0],
    position: 1,
    stageId: 200,
  });

  expect(CrmDealsAPI.transitionStage).toHaveBeenCalledWith(
    1,
    expect.objectContaining({ lock_version: 1, stage_id: 200 })
  );
  expect(state.deals[0]).toMatchObject({ id: 1, stageId: 100 });
  expect(state.dealsMeta.stageCounts).toMatchObject({ 100: 1, 200: 0 });
});

it('ignores another stage intent while the same deal mutation is pending', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  const pendingTransition = deferred();
  CrmDealsAPI.transitionStage.mockReturnValueOnce(pendingTransition.promise);

  const moving = state.handleDealStageChange({
    deal: original,
    position: null,
    stageId: 200,
  });
  await flushPromises();
  await state.handleDealStageChange({
    deal: state.deals[0],
    position: null,
    stageId: 100,
  });

  expect(CrmDealsAPI.transitionStage).toHaveBeenCalledTimes(1);
  expect(state.pendingDealStageIds.has(original.id)).toBe(true);

  pendingTransition.resolve(
    response({ ...original, lockVersion: 2, stageId: 200 })
  );
  await moving;

  expect(state.pendingDealStageIds.has(original.id)).toBe(false);
});

it('keeps the newest list stage after a pending board move', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  const pendingTransition = deferred();
  CrmDealsAPI.transitionStage.mockReturnValueOnce(pendingTransition.promise);

  const moving = state.handleDealStageChange({
    deal: original,
    position: 1,
    stageId: 200,
  });
  await flushPromises();
  CrmDealsAPI.get.mockResolvedValueOnce(
    response([{ ...original, lock_version: 3, stage_id: 100 }], {
      count: 1,
      has_more: false,
      page: 1,
      per_page: 25,
      total_count: 1,
    })
  );
  await state.handlePresentationChange('list');
  expect(state.selectedDeal).toMatchObject({ lockVersion: 3, stageId: 100 });
  expect(state.form.stageId).toBe(200);

  pendingTransition.resolve(
    response({ ...original, lockVersion: 2, stageId: 200 })
  );
  await moving;

  expect(state.selectedDeal).toMatchObject({ lockVersion: 3, stageId: 100 });
  expect(state.form.stageId).toBe(100);
});

it('preserves a stale deal draft and retries only its changed fields', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.captureFormBaseline();
  state.form.title = 'Local draft';

  const authoritative = {
    ...original,
    lockVersion: 2,
    ownerId: 9,
    stageId: 200,
    title: 'Changed elsewhere',
  };
  CrmDealsAPI.update
    .mockRejectedValueOnce({
      response: { data: { code: 'STALE_RECORD' }, status: 409 },
    })
    .mockResolvedValueOnce(
      response({ ...authoritative, lockVersion: 3, title: 'Local draft' })
    );
  CrmDealsAPI.show.mockResolvedValueOnce(response(authoritative));

  await state.saveDeal();

  expect(state.form.title).toBe('Local draft');
  expect(state.dealEditSnapshot.deal).toMatchObject({
    lockVersion: 2,
    title: 'Deal 1',
  });
  expect(state.selectedDeal).toMatchObject({
    lockVersion: 2,
    ownerId: 9,
  });
  expect(state.dealConflict).toMatchObject({
    active: true,
    hasAuthoritative: true,
  });

  await state.saveDeal();

  expect(CrmDealsAPI.update).toHaveBeenNthCalledWith(2, 1, {
    lock_version: 2,
    title: 'Local draft',
  });
  expect(CrmDealsAPI.transitionStage).not.toHaveBeenCalled();
});

it('requires an explicit retry after realtime advances an edited deal', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';

  const authoritative = {
    ...original,
    lockVersion: 2,
    ownerId: 9,
    title: 'Changed elsewhere',
  };
  state.selectedDeal = authoritative;
  CrmDealsAPI.show.mockResolvedValueOnce(response(authoritative));
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({ ...authoritative, lockVersion: 3, title: 'Local draft' })
  );

  await state.saveDeal();

  expect(CrmDealsAPI.update).not.toHaveBeenCalled();
  expect(state.form.title).toBe('Local draft');
  expect(state.dealConflict.hasAuthoritative).toBe(true);

  await state.saveDeal();

  expect(CrmDealsAPI.update).toHaveBeenCalledExactlyOnceWith(1, {
    lock_version: 2,
    title: 'Local draft',
  });
});

it('keeps a newer list version after the mutation response returns', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.currentPresentation = 'list';
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({ ...original, lockVersion: 2, title: 'Local draft' })
  );
  CrmDealsAPI.get.mockResolvedValueOnce(
    response(
      [{ ...original, lock_version: 3, owner_id: 9, title: 'Newer list' }],
      {
        count: 1,
        has_more: false,
        page: 1,
        per_page: 25,
        total_count: 1,
      }
    )
  );

  await state.saveDeal();

  expect(state.form.title).toBe('Local draft');
  expect(state.selectedDeal).toMatchObject({
    lockVersion: 3,
    ownerId: 9,
    title: 'Newer list',
  });
  expect(state.dealEditSnapshot.deal.lockVersion).toBe(3);
  expect(state.dealConflict).toMatchObject({
    active: true,
    hasAuthoritative: true,
  });
});

it('does not roll a newer board version back to the mutation response', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  const mutation = deferred();
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';
  CrmDealsAPI.update.mockReturnValueOnce(mutation.promise);

  const saving = state.saveDeal();
  await flushPromises();
  const authoritative = {
    ...original,
    lockVersion: 3,
    ownerId: 9,
    stageId: 200,
    title: 'Newer board',
  };
  state.deals = [authoritative];
  state.selectedDeal = authoritative;
  state.dealsMeta = {
    ...state.dealsMeta,
    stageCounts: { 100: 0, 200: 1 },
  };
  mutation.resolve(
    response({ ...original, lockVersion: 2, title: 'Local draft' })
  );
  await saving;

  expect(state.deals[0]).toMatchObject({
    lockVersion: 3,
    stageId: 200,
    title: 'Newer board',
  });
  expect(state.dealsMeta.stageCounts).toEqual({ 100: 0, 200: 1 });
  expect(state.form.title).toBe('Local draft');
  expect(state.dealConflict).toMatchObject({
    active: true,
    hasAuthoritative: true,
  });
});

it('ignores a board request that predates an accepted mutation', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  const pendingBoard = deferred();
  CrmDealsAPI.get.mockReturnValueOnce(pendingBoard.promise);
  const loading = state.loadDeals();
  await flushPromises();

  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Accepted mutation';
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({ ...original, lockVersion: 2, title: 'Accepted mutation' })
  );
  await state.saveDeal();

  pendingBoard.resolve(
    response(
      [{ ...original, lock_version: 1, title: 'Stale board response' }],
      { stage_counts: { 100: 1 } }
    )
  );
  await loading;

  expect(state.deals[0]).toMatchObject({
    lockVersion: 2,
    title: 'Accepted mutation',
  });
  expect(state.selectedDeal).toMatchObject({
    lockVersion: 2,
    title: 'Accepted mutation',
  });
});

it('does not let a late deal list refresh replace a reopened editor', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  const pendingList = deferred();
  state.currentPresentation = 'list';
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'First save';
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({ ...original, lockVersion: 2, title: 'First save' })
  );
  CrmDealsAPI.get.mockReturnValueOnce(pendingList.promise);

  const saving = state.saveDeal();
  await flushPromises();
  state.closeDrawer();
  const reopened = deal(2);
  state.selectedDeal = reopened;
  state.populateFormFromDeal(reopened);
  state.dealEditSnapshot = state.buildDealEditSnapshot(reopened);
  pendingList.resolve(response([{ ...original, lock_version: 2 }]));
  await saving;

  expect(state.selectedDeal.id).toBe(2);
  expect(state.form.title).toBe(reopened.title);
  expect(state.dealConflict.active).toBe(false);
});

it('uses the newest list version after an inline title mutation', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.currentPresentation = 'list';
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.dealTitleDraft = 'HTTP title';
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({ ...original, lockVersion: 2, title: 'HTTP title' })
  );
  CrmDealsAPI.get.mockResolvedValueOnce(
    response([{ ...original, lock_version: 3, title: 'Newest list title' }], {
      count: 1,
      has_more: false,
      page: 1,
      per_page: 25,
      total_count: 1,
    })
  );

  await state.saveDealTitle(original);

  expect(state.deals[0]).toMatchObject({
    lockVersion: 3,
    title: 'Newest list title',
  });
  expect(state.selectedDeal).toMatchObject({
    lockVersion: 3,
    title: 'Newest list title',
  });
  expect(state.form.title).toBe('Newest list title');

  state.form.description = 'Edited after title mutation';
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({
      ...original,
      description: 'Edited after title mutation',
      lockVersion: 4,
      title: 'Newest list title',
    })
  );
  CrmDealsAPI.get.mockResolvedValueOnce(
    response(
      [
        {
          ...original,
          description: 'Edited after title mutation',
          lock_version: 4,
          title: 'Newest list title',
        },
      ],
      { count: 1, has_more: false, page: 1, per_page: 25, total_count: 1 }
    )
  );

  await state.saveDeal();

  expect(CrmDealsAPI.update).toHaveBeenLastCalledWith(
    1,
    expect.objectContaining({
      description: 'Edited after title mutation',
      lock_version: 3,
    })
  );
  expect(state.dealConflict.active).toBe(false);
});

it('keeps a stale deal draft when the authoritative reload fails', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';
  CrmDealsAPI.update.mockRejectedValueOnce({
    response: { data: { code: 'STALE_RECORD' }, status: 409 },
  });
  CrmDealsAPI.show.mockRejectedValueOnce(new Error('reload failed'));

  await state.saveDeal();

  expect(state.form.title).toBe('Local draft');
  expect(state.dealConflict).toMatchObject({
    active: true,
    hasAuthoritative: false,
    reloadFailed: true,
  });
});

it('ignores a deal conflict reload that finishes after the drawer closes', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';
  const reload = deferred();
  CrmDealsAPI.update.mockRejectedValueOnce({
    response: { data: { code: 'STALE_RECORD' }, status: 409 },
  });
  CrmDealsAPI.show.mockReturnValueOnce(reload.promise);

  const saving = state.saveDeal();
  await flushPromises();
  expect(state.dealConflict.isReloading).toBe(true);

  state.closeDrawer();
  const reopened = deal(2, 'Reopened');
  state.selectedDeal = reopened;
  state.dealEditSnapshot = state.buildDealEditSnapshot(reopened);
  reload.resolve(response({ ...original, lockVersion: 2 }));
  await saving;

  expect(state.selectedDeal).toMatchObject({ id: 2, title: 'Reopened' });
  expect(state.dealEditSnapshot.deal).toMatchObject({ id: 2 });
  expect(state.dealConflict).toMatchObject({
    active: false,
    hasAuthoritative: false,
    isReloading: false,
  });
});

it('invalidates a pending deal conflict reload on unmount', async () => {
  const { state, wrapper } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';
  const reload = deferred();
  CrmDealsAPI.update.mockRejectedValueOnce({
    response: { data: { code: 'STALE_RECORD' }, status: 409 },
  });
  CrmDealsAPI.show.mockReturnValueOnce(reload.promise);

  const saving = state.saveDeal();
  await flushPromises();
  wrapper.unmount();
  wrappers.splice(wrappers.indexOf(wrapper), 1);
  reload.resolve(response({ ...original, lockVersion: 2 }));
  await saving;

  expect(state.dealConflict).toMatchObject({
    active: false,
    hasAuthoritative: false,
    isReloading: false,
  });
  expect(state.selectedDeal.lockVersion).toBe(1);
});

it('ignores a late stale mutation after reopening another deal', async () => {
  const { state } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';
  const mutation = deferred();
  CrmDealsAPI.update.mockReturnValueOnce(mutation.promise);
  CrmDealsAPI.show.mockClear();

  const saving = state.saveDeal();
  await flushPromises();
  state.closeDrawer();
  const reopened = deal(2, 'Reopened');
  state.selectedDeal = reopened;
  mutation.reject({
    response: { data: { code: 'STALE_RECORD' }, status: 409 },
  });
  await saving;

  expect(CrmDealsAPI.show).not.toHaveBeenCalled();
  expect(state.selectedDeal).toMatchObject({ id: 2, title: 'Reopened' });
  expect(state.dealConflict.active).toBe(false);
  expect(state.ui.isSaving).toBe(false);
});

it('ignores a late stale deal mutation after unmount', async () => {
  const { state, wrapper } = await mountPage();
  const original = state.deals[0];
  state.selectedDeal = original;
  state.populateFormFromDeal(original);
  state.dealEditSnapshot = state.buildDealEditSnapshot(original);
  state.form.title = 'Local draft';
  const mutation = deferred();
  CrmDealsAPI.update.mockReturnValueOnce(mutation.promise);
  CrmDealsAPI.show.mockClear();

  const saving = state.saveDeal();
  await flushPromises();
  wrapper.unmount();
  wrappers.splice(wrappers.indexOf(wrapper), 1);
  mutation.reject({
    response: { data: { code: 'STALE_RECORD' }, status: 409 },
  });
  await saving;

  expect(CrmDealsAPI.show).not.toHaveBeenCalled();
  expect(state.dealConflict.active).toBe(false);
  expect(state.ui.isSaving).toBe(false);
});

it('requests one bounded list page with server search and sort', async () => {
  const { state } = await mountPage();
  state.currentPresentation = 'list';
  state.listQuickFilters.q = 'needle';
  state.listSort = { direction: 'desc', key: 'title' };
  CrmDealsAPI.get.mockReset().mockResolvedValue(
    response([deal(26, 'Needle')], {
      count: 1,
      has_more: false,
      page: 2,
      per_page: 25,
      total_count: 26,
    })
  );

  await state.handleListPageChange(2);

  expect(CrmDealsAPI.get).toHaveBeenCalledExactlyOnceWith(
    expect.objectContaining({
      page: 2,
      per_page: 25,
      q: 'needle',
      sort_by: 'title',
      sort_direction: 'desc',
    })
  );
  expect(state.deals.map(item => item.id)).toEqual([26]);
  expect(state.dealsMeta).toMatchObject({
    page: 2,
    perPage: 25,
    totalCount: 26,
  });
});

it('sends localized custom-field search aliases for board requests', async () => {
  const { state } = await mountPage();
  CrmDealsAPI.get.mockClear();
  state.listQuickFilters.q = 'yes';

  await state.loadDeals();

  expect(CrmDealsAPI.get).toHaveBeenLastCalledWith(
    expect.objectContaining({
      board: true,
      q: 'yes',
      q_checked: true,
    })
  );
});

it('refetches the last valid page after the current page becomes empty', async () => {
  const { state } = await mountPage();
  state.currentPresentation = 'list';
  state.listCurrentPage = 2;
  CrmDealsAPI.get
    .mockReset()
    .mockResolvedValueOnce(
      response([], {
        count: 0,
        has_more: false,
        page: 2,
        per_page: 25,
        total_count: 25,
      })
    )
    .mockResolvedValueOnce(
      response([deal(25)], {
        count: 25,
        has_more: false,
        page: 1,
        per_page: 25,
        total_count: 25,
      })
    );

  await state.loadDeals();

  expect(state.listCurrentPage).toBe(1);
  expect(CrmDealsAPI.get).toHaveBeenNthCalledWith(
    1,
    expect.objectContaining({ page: 2, per_page: 25 })
  );
  expect(CrmDealsAPI.get).toHaveBeenNthCalledWith(
    2,
    expect.objectContaining({ page: 1, per_page: 25 })
  );
  expect(state.deals.map(item => item.id)).toEqual([25]);
});

it('ignores an older list response after a newer request wins', async () => {
  const { state } = await mountPage();
  state.currentPresentation = 'list';
  const older = deferred();
  CrmDealsAPI.get
    .mockReset()
    .mockReturnValueOnce(older.promise)
    .mockResolvedValueOnce(
      response([deal(2, 'New result')], {
        count: 1,
        has_more: false,
        page: 1,
        per_page: 25,
        total_count: 1,
      })
    );

  const oldRequest = state.loadDeals();
  const newRequest = state.loadDeals();
  await newRequest;
  older.resolve(
    response([deal(1, 'Old result')], {
      count: 1,
      has_more: false,
      page: 1,
      per_page: 25,
      total_count: 1,
    })
  );
  await oldRequest;

  expect(state.deals.map(item => item.id)).toEqual([2]);
});

it('invalidates the old workspace request before loading the new workspace', async () => {
  const { state } = await mountPage();
  state.currentPresentation = 'list';
  const oldWorkspace = deferred();
  CrmDealsAPI.get
    .mockReset()
    .mockReturnValueOnce(oldWorkspace.promise)
    .mockResolvedValueOnce(
      response([deal(2, 'Account two')], {
        count: 1,
        has_more: false,
        page: 1,
        per_page: 25,
        total_count: 1,
      })
    );

  const oldRequest = state.loadDeals();
  runtime.accountId.value = 2;
  await flushPromises();
  oldWorkspace.resolve(
    response([deal(1, 'Old workspace')], {
      count: 1,
      has_more: false,
      page: 1,
      per_page: 25,
      total_count: 1,
    })
  );
  await oldRequest;
  await flushPromises();

  expect(state.deals.map(item => item.id)).toEqual([2]);
  expect(CrmDealsAPI.get).toHaveBeenLastCalledWith(
    expect.objectContaining({
      page: 1,
      per_page: 25,
    })
  );
});

it('does not page the board while a deal page is open', async () => {
  CrmDealsAPI.get.mockResolvedValue(
    response([deal(1)], boardMeta({ has_more: true }))
  );
  const { state } = await mountPage();
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(1)));
  runtime.routeParams.dealId = '1';
  await flushPromises();
  CrmDealsAPI.get.mockClear();

  expect(state.hasMoreDeals).toBe(true);
  expect(await state.loadMoreDeals()).toBe(false);
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();

  delete runtime.routeParams.dealId;
  await flushPromises();
  await state.loadMoreDeals();

  expect(CrmDealsAPI.get).toHaveBeenCalledExactlyOnceWith(
    expect.objectContaining({ page: 2 })
  );
});

it('keeps the real board mounted and idle under a deal page', async () => {
  // jsdom has no layout, so the board reports a zero size exactly like a board
  // hidden by display: none. Auto-fill must not read that as "not full".
  CrmDealsAPI.get.mockResolvedValue(
    response([deal(1)], boardMeta({ has_more: true }))
  );
  const { wrapper } = await mountPage(
    { CrmDealBoard: false },
    { 'fluent-icon': { template: '<i />' } }
  );
  const board = wrapper.findComponent({ name: 'CrmDealBoard' });
  expect(board.exists()).toBe(true);
  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);

  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(1)));
  runtime.routeParams.dealId = '1';
  await flushPromises();

  const boardUnderDeal = wrapper.findComponent({ name: 'CrmDealBoard' });
  expect(boardUnderDeal.vm.$.uid).toBe(board.vm.$.uid);
  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);
});

it('resets the deal loading flag when Back is pressed before the deal arrives', async () => {
  const { state, wrapper } = await mountPage();
  const pendingDeal = deferred();
  CrmDealsAPI.show.mockReturnValueOnce(pendingDeal.promise);
  runtime.routeParams.dealId = '11';
  await flushPromises();

  expect(state.isDealLoading).toBe(true);
  // The board's own loading state is not used while a deal opens.
  expect(state.ui.isLoading).toBe(false);

  delete runtime.routeParams.dealId;
  await flushPromises();
  pendingDeal.resolve(response(deal(11)));
  await flushPromises();

  expect(state.isDealLoading).toBe(false);
  expect(state.ui.isLoading).toBe(false);
  expect(state.drawerOpen).toBe(false);
  expect(state.selectedDeal).toBeNull();
  expect(wrapper.findComponent({ name: 'CrmPageSkeleton' }).exists()).toBe(
    false
  );
  expect(wrapper.findComponent({ name: 'CrmDealBoard' }).exists()).toBe(true);
});

it('lets only the newest opened deal own the deal loading flag', async () => {
  runtime.routeParams.dealId = '11';
  const obsolete = deferred();
  const current = deferred();
  CrmDealsAPI.show
    .mockReturnValueOnce(obsolete.promise)
    .mockReturnValueOnce(current.promise);
  const { state } = await mountPage();

  runtime.routeParams.dealId = '22';
  await flushPromises();
  obsolete.resolve(response(deal(11)));
  await flushPromises();
  expect(state.isDealLoading).toBe(true);

  current.resolve(response(deal(22)));
  await flushPromises();
  expect(state.isDealLoading).toBe(false);
  expect(state.selectedDeal.id).toBe(22);
});

it('keeps a failed deal load off the board when coming back', async () => {
  const { state } = await mountPage();
  CrmDealsAPI.show.mockRejectedValueOnce(new Error('deal unavailable'));
  runtime.routeParams.dealId = '11';
  await flushPromises();

  expect(state.dealPageError).toBe('deal unavailable');
  expect(state.ui.error).toBeNull();

  CrmDealsAPI.get.mockClear();
  delete runtime.routeParams.dealId;
  await flushPromises();

  expect(state.dealPageError).toBeNull();
  expect(state.ui.error).toBeNull();
  expect(state.deals.map(item => item.id)).toEqual([1]);
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
});

it('loads the board on the way back from a deep-linked deal that was saved', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));
  const { state } = await mountPage();
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
  expect(state.isDealListLoaded).toBe(false);

  state.form.title = 'Edited deal';
  CrmDealsAPI.update.mockResolvedValueOnce(
    response({ ...deal(11), lockVersion: 2, title: 'Edited deal' })
  );
  await state.saveDeal();

  // No one-card board with totals for a single deal.
  expect(state.deals).toEqual([]);
  expect(state.dealsMeta.stageAmountsMinor).toBeUndefined();
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();

  CrmDealsAPI.get.mockResolvedValueOnce(
    response([deal(1), deal(11, 'Edited deal')], boardMeta({ count: 2 }))
  );
  delete runtime.routeParams.dealId;
  await flushPromises();

  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);
  expect(state.deals.map(item => item.id)).toEqual([1, 11]);
  expect(state.isDealListLoaded).toBe(true);
  expect(state.ui.isLoading).toBe(false);
});

it('reloads the board on the way back when its last load failed', async () => {
  CrmDealsAPI.get.mockRejectedValueOnce(new Error('board unavailable'));
  const { state } = await mountPage();
  expect(state.ui.error).toBe('board unavailable');

  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));
  await flushPromises();
  CrmDealsAPI.get.mockClear();
  delete runtime.routeParams.dealId;
  await flushPromises();

  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);
  expect(state.ui.error).toBeNull();
  expect(state.deals.map(item => item.id)).toEqual([1]);
});

it('merges a realtime deal event with the server payload into the loaded board', async () => {
  const { state } = await mountPage();
  CrmDealsAPI.get.mockClear();

  emitCrmDealEvent({
    id: 1,
    lock_version: 2,
    stage_id: 200,
    title: 'Renamed elsewhere',
  });
  await flushPromises();

  expect(state.deals).toHaveLength(1);
  expect(state.deals[0]).toMatchObject({
    id: 1,
    lockVersion: 2,
    stageId: 200,
    title: 'Renamed elsewhere',
  });
  expect(state.dealsMeta.stageCounts).toMatchObject({ 100: 0, 200: 1 });
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
  expect(state.ui.isLoading).toBe(false);
});

it('ignores a realtime deal event that is older than the loaded deal', async () => {
  const { state } = await mountPage();
  state.deals = [{ ...state.deals[0], lockVersion: 5, title: 'Newest' }];

  emitCrmDealEvent({ id: 1, lock_version: 3, title: 'Older' });
  await flushPromises();

  expect(state.deals[0]).toMatchObject({ lockVersion: 5, title: 'Newest' });
});

it('refreshes the board quietly when a realtime event brings a deal it does not hold', async () => {
  const { state } = await mountPage();
  const loadingDuringRefresh = [];
  CrmDealsAPI.get.mockReset().mockImplementation(async () => {
    loadingDuringRefresh.push(state.ui.isLoading);
    return response(
      [deal(1), deal(2)],
      boardMeta({ count: 2, stage_counts: { 100: 2 } })
    );
  });

  vi.useFakeTimers();
  try {
    emitCrmDealEvent(
      { id: 2, lock_version: 1, title: 'Deal 2' },
      'crm.deal.created'
    );
    await vi.advanceTimersByTimeAsync(400);
  } finally {
    vi.useRealTimers();
  }
  await flushPromises();

  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);
  expect(loadingDuringRefresh).toEqual([false]);
  expect(state.ui.isLoading).toBe(false);
  expect(state.ui.error).toBeNull();
  expect(state.deals.map(item => item.id)).toEqual([1, 2]);
});

it('does not reload for a realtime event of another pipeline', async () => {
  await mountPage();
  CrmDealsAPI.get.mockClear();

  vi.useFakeTimers();
  try {
    emitCrmDealEvent({ id: 90, lock_version: 1, pipeline_id: 99 });
    await vi.advanceTimersByTimeAsync(400);
  } finally {
    vi.useRealTimers();
  }

  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
});

it('keeps a failed quiet refresh from turning the board into an error page', async () => {
  const { state } = await mountPage();
  CrmDealsAPI.get.mockReset().mockRejectedValue(new Error('refresh failed'));

  vi.useFakeTimers();
  try {
    emitCrmDealEvent({ id: 2, lock_version: 1 }, 'crm.deal.created');
    await vi.advanceTimersByTimeAsync(400);
  } finally {
    vi.useRealTimers();
  }
  await flushPromises();

  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);
  expect(state.ui.error).toBeNull();
  expect(state.ui.isLoading).toBe(false);
  expect(state.deals.map(item => item.id)).toEqual([1]);
});

it('follows a realtime update of the open deal page without loading the board', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));
  const { state } = await mountPage();

  emitCrmDealEvent({ id: 11, lock_version: 2, title: 'Changed elsewhere' });
  expect(state.selectedDeal).toMatchObject({
    lockVersion: 2,
    title: 'Changed elsewhere',
  });

  emitCrmDealEvent({ id: 11, lock_version: 1, title: 'Older version' });
  expect(state.selectedDeal.title).toBe('Changed elsewhere');
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
  expect(state.deals).toEqual([]);
});

it('waits for the way back to refresh a board that changed under a deal page', async () => {
  const { state } = await mountPage();
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(1)));
  runtime.routeParams.dealId = '1';
  await flushPromises();
  CrmDealsAPI.get.mockClear();

  emitCrmDealEvent(
    { id: 7, lock_version: 1, title: 'New elsewhere' },
    'crm.deal.created'
  );
  await flushPromises();
  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
  expect(state.isDealListLoaded).toBe(false);

  CrmDealsAPI.get.mockResolvedValueOnce(
    response([deal(1), deal(7)], boardMeta({ count: 2 }))
  );
  delete runtime.routeParams.dealId;
  await flushPromises();

  expect(CrmDealsAPI.get).toHaveBeenCalledTimes(1);
  expect(state.deals.map(item => item.id)).toEqual([1, 7]);
  expect(state.isDealListLoaded).toBe(true);
});

it('keeps a created dialog on screen when linking its contact fails', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(response(deal(11)));
  CrmDealsAPI.update.mockRejectedValueOnce(new Error('contact link rejected'));
  ConversationAPI.create.mockResolvedValueOnce({
    data: { display_id: 185, id: 11963 },
  });
  const { state } = await mountPage();
  state.form.title = 'Unsaved draft title';

  await state.createDealConversation({ contactId: 7, inbox: { id: 9 } });

  expect(ConversationAPI.create).toHaveBeenCalledTimes(1);
  expect(state.dealConversationDraft.createdConversationId).toBe(11963);
  expect(state.linkedConversationId).toBe(11963);
  expect(state.linkedConversationDisplayId).toBe('185');
  expect(state.dealConversationDraft.isCreating).toBe(false);
  // The unsaved title is not part of the contact link.
  expect(CrmDealsAPI.update).toHaveBeenCalledExactlyOnceWith(11, {
    contact_ids: [7],
    lock_version: 1,
    primary_contact_id: 7,
  });
  expect(useAlert).toHaveBeenCalledWith(
    'CRM.DEALS.CONVERSATION_PLACEHOLDER.LINK_FAILED'
  );
  expect(useAlert).not.toHaveBeenCalledWith(
    'CRM.DEALS.CONVERSATION_PLACEHOLDER.CREATED'
  );
  expect(state.form.title).toBe('Unsaved draft title');
});

it('does not save the deal again when its contact is already linked', async () => {
  runtime.routeParams.dealId = '11';
  CrmDealsAPI.show.mockResolvedValueOnce(
    response({
      ...deal(11),
      dealContacts: [{ contactId: 7 }],
      primaryContactId: 7,
    })
  );
  ContactAPI.show.mockResolvedValue(response({ id: 7, name: 'Test' }));
  ConversationAPI.create.mockResolvedValueOnce({
    data: { display_id: 185, id: 11963 },
  });
  const { state } = await mountPage();
  expect(state.selectedDeal.id).toBe(11);

  await state.createDealConversation({ contactId: 7, inbox: { id: 9 } });

  expect(ConversationAPI.create).toHaveBeenCalledTimes(1);
  expect(CrmDealsAPI.update).not.toHaveBeenCalled();
  expect(state.dealConversationDraft).toMatchObject({
    contactId: 7,
    createdConversationDisplayId: 185,
    createdConversationId: 11963,
  });
  expect(state.linkedConversationId).toBe(11963);
  expect(useAlert).toHaveBeenCalledWith(
    'CRM.DEALS.CONVERSATION_PLACEHOLDER.CREATED'
  );
});

it('builds an empty amount as no amount instead of 0', async () => {
  const { state } = await mountPage();

  state.form.amount = '';
  expect(state.buildPayload()).not.toHaveProperty('amount_minor');

  state.form.amount = 0;
  expect(state.buildPayload().amount_minor).toBe(0);
  state.form.amount = 15;
  expect(state.buildPayload().amount_minor).toBe(1500);

  state.selectedDeal = deal(1);
  state.form.amount = '';
  expect(state.buildPayload().amount_minor).toBeNull();
});

it('creates a deal without an amount when the amount field is empty', async () => {
  CrmDealsAPI.create.mockResolvedValueOnce(response(deal(5)));
  const { state } = await mountPage();
  await state.openCreateDrawer();
  state.form.title = 'No amount yet';
  state.form.amount = '';

  await state.saveDeal();

  expect(CrmDealsAPI.create).toHaveBeenCalledTimes(1);
  const payload = CrmDealsAPI.create.mock.calls[0][0];
  expect(payload).toMatchObject({ title: 'No amount yet', pipeline_id: 10 });
  expect(payload).not.toHaveProperty('amount_minor');
});

it('names the system stage like the board in the list stage menu', async () => {
  const [stage] = referencesStore.pipelines[0].stages;
  referencesStore.pipelines[0].stages[0] = {
    ...stage,
    code: 'new',
    name: 'Unsorted',
  };
  try {
    const { state } = await mountPage();
    const options = state.listStageOptionsForDeal({ pipelineId: 10 });

    expect(options.map(option => option.name)).toEqual([
      'CRM.SETTINGS.STAGES.SYSTEM.UNSORTED',
      'Qualified',
    ]);
    expect(options[0]).toMatchObject({ code: 'new', id: 100 });
    expect(state.listStageOptionsForDeal({ pipelineId: 404 })).toEqual([]);
  } finally {
    referencesStore.pipelines[0].stages[0] = stage;
  }
});

it('opens a deal even when the scroll position cannot be remembered', async () => {
  const { state } = await mountPage();
  state.currentPresentation = 'list';
  await flushPromises();
  const setItem = vi
    .spyOn(Storage.prototype, 'setItem')
    .mockImplementation(() => {
      throw new Error('storage blocked');
    });

  try {
    expect(() => state.openDealPage(deal(11))).not.toThrow();
  } finally {
    setItem.mockRestore();
  }

  expect(runtime.routerPush).toHaveBeenCalledWith(
    expect.objectContaining({
      name: 'crm_deal_show',
      params: { accountId: 1, dealId: 11 },
    })
  );
});

it('returns to the list when the remembered scroll position cannot be read', async () => {
  const { state } = await mountPage();
  const getItem = vi
    .spyOn(Storage.prototype, 'getItem')
    .mockImplementation(() => {
      throw new Error('storage blocked');
    });

  try {
    await expect(state.restoreDealListScroll()).resolves.toBeUndefined();
  } finally {
    getItem.mockRestore();
  }

  sessionStorage.setItem('crm-deals-return-scroll:1', '{not json');
  await expect(state.restoreDealListScroll()).resolves.toBeUndefined();
});

it('drops a pending debounced reload when the page unmounts', async () => {
  const { state, wrapper } = await mountPage();
  CrmDealsAPI.get.mockClear();
  vi.useFakeTimers();
  try {
    state.listQuickFilters.q = 'late search';
    await nextTick();
    wrapper.unmount();
    vi.advanceTimersByTime(400);
  } finally {
    vi.useRealTimers();
  }

  expect(CrmDealsAPI.get).not.toHaveBeenCalled();
});
