import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, expect, it, vi } from 'vitest';

const { referencesStore, store } = vi.hoisted(() => ({
  referencesStore: {
    dealFieldDefinitions: [],
    pipelines: [
      {
        id: 10,
        active: true,
        default: true,
        name: 'Sales',
        stages: [
          { id: 100, active: true, default: true, name: 'New' },
          { id: 101, active: true, name: 'Qualified' },
        ],
      },
    ],
    taskFieldDefinitions: [],
    taskStatuses: [],
    taskTypes: [],
    loadFieldDefinitions: vi.fn().mockResolvedValue(),
    loadPipelines: vi.fn().mockResolvedValue(),
    loadTaskStatuses: vi.fn().mockResolvedValue(),
    loadTaskTypes: vi.fn().mockResolvedValue(),
  },
  store: { dispatch: vi.fn().mockResolvedValue() },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ locale: { value: 'en' }, t: key => key }),
}));
vi.mock('dashboard/api/companies', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/api/crm/deals', () => ({
  default: {
    create: vi.fn(),
    get: vi.fn(),
    show: vi.fn(),
    transitionStage: vi.fn(),
    update: vi.fn(),
  },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/store', async () => {
  const { ref } = await vi.importActual('vue');
  const getters = {
    getCurrentAccountId: ref(1),
    getCurrentUser: ref({ id: 1, accounts: [{ id: 1, permissions: [] }] }),
    'agents/getAgents': ref([{ id: 1, name: 'Agent' }]),
    'accounts/isFeatureEnabledonAccount': ref(() => true),
    'teams/getTeams': ref([]),
  };

  return {
    useMapGetter: key => getters[key] || ref(null),
    useStore: () => store,
  };
});
vi.mock('dashboard/helper/permissionsHelper', () => ({
  hasPermissions: () => true,
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => referencesStore,
}));

import CompanyAPI from 'dashboard/api/companies';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';
import CrmConversationDealsSidebar from './CrmConversationDealsSidebar.vue';

const currentChat = {
  id: 11963,
  display_id: 185,
  meta: { sender: { id: 77, name: 'Customer' } },
};

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((promiseResolve, promiseReject) => {
    resolve = promiseResolve;
    reject = promiseReject;
  });
  return { promise, reject, resolve };
};

const dealFixture = (overrides = {}) => ({
  id: 1,
  contactIds: [77],
  currency: 'KZT',
  customAttributes: {},
  lockVersion: 1,
  pipelineId: 10,
  primaryContactId: 77,
  stageId: 100,
  title: 'Original deal',
  ...overrides,
});

const staleError = () => {
  const error = new Error('Stale record');
  error.response = { status: 409, data: { code: 'STALE_RECORD' } };
  return error;
};

const mountWithDeals = async deals => {
  CrmDealsAPI.get.mockResolvedValue({ data: { payload: deals } });
  const wrapper = shallowMount(CrmConversationDealsSidebar, {
    props: { currentChat },
    global: { mocks: { $t: key => key } },
  });
  await flushPromises();
  return wrapper;
};

beforeEach(() => {
  vi.clearAllMocks();
  CompanyAPI.get.mockResolvedValue({ data: { payload: [] } });
  CrmDealsAPI.get.mockResolvedValue({ data: { payload: [] } });
  CrmDealsAPI.create.mockReset();
  CrmDealsAPI.show.mockReset();
  CrmDealsAPI.transitionStage.mockReset();
  CrmDealsAPI.update.mockReset();
});

it('shows a retryable error instead of a create form when deal lookup fails', async () => {
  CrmDealsAPI.get.mockRejectedValueOnce(new Error('Network unavailable'));
  const wrapper = shallowMount(CrmConversationDealsSidebar, {
    props: { currentChat },
    global: { mocks: { $t: key => key } },
  });
  await flushPromises();

  const state = wrapper.vm.$.setupState;
  const errorState = wrapper.findComponent({ name: 'SchedulingErrorState' });
  expect(errorState.exists()).toBe(true);
  expect(state.deals).toEqual([]);
  expect(Object.keys(state.forms)).toEqual([]);
  expect(wrapper.findComponent({ name: 'CrmDealTasksPanel' }).exists()).toBe(
    false
  );
  expect(
    wrapper.findComponent({ name: 'SidebarActionsHeader' }).props('buttons')
  ).toEqual([]);
});

it('does not let a stale request clear the current loading state', async () => {
  const oldLookup = deferred();
  const oldOriginLookup = deferred();
  const newLookup = deferred();
  const newOriginLookup = deferred();
  CrmDealsAPI.get
    .mockReset()
    .mockImplementationOnce(() => oldLookup.promise)
    .mockImplementationOnce(() => oldOriginLookup.promise)
    .mockImplementationOnce(() => newLookup.promise)
    .mockImplementationOnce(() => newOriginLookup.promise);

  const wrapper = shallowMount(CrmConversationDealsSidebar, {
    props: { currentChat },
    global: { mocks: { $t: key => key } },
  });
  await vi.waitFor(() => expect(CrmDealsAPI.get).toHaveBeenCalledTimes(2));

  await wrapper.setProps({
    currentChat: {
      id: 11964,
      display_id: 186,
      meta: { sender: { id: 78, name: 'Next customer' } },
    },
  });
  await vi.waitFor(() => expect(CrmDealsAPI.get).toHaveBeenCalledTimes(4));

  oldLookup.resolve({
    data: {
      payload: [{ id: 1, primaryContactId: 77, title: 'Old deal' }],
    },
  });
  oldOriginLookup.resolve({ data: { payload: [] } });
  await flushPromises();

  const state = wrapper.vm.$.setupState;
  expect(state.ui.isInitializing).toBe(true);
  expect(state.deals).toEqual([]);

  newLookup.resolve({
    data: {
      payload: [{ id: 2, primaryContactId: 78, title: 'New deal' }],
    },
  });
  newOriginLookup.resolve({ data: { payload: [] } });
  await flushPromises();

  expect(state.ui.isInitializing).toBe(false);
  expect(state.ui.error).toBeNull();
  expect(state.deals.map(deal => deal.id)).toEqual([2]);
  expect(Object.keys(state.forms)).toContain('deal-2');
  expect(Object.keys(state.forms)).not.toContain('deal-1');
});

it('keeps current deals when the stale conversation resolves last', async () => {
  const oldLookup = deferred();
  const oldOriginLookup = deferred();
  const newLookup = deferred();
  const newOriginLookup = deferred();
  CrmDealsAPI.get
    .mockReset()
    .mockImplementationOnce(() => oldLookup.promise)
    .mockImplementationOnce(() => oldOriginLookup.promise)
    .mockImplementationOnce(() => newLookup.promise)
    .mockImplementationOnce(() => newOriginLookup.promise);

  const wrapper = shallowMount(CrmConversationDealsSidebar, {
    props: { currentChat },
    global: { mocks: { $t: key => key } },
  });
  await vi.waitFor(() => expect(CrmDealsAPI.get).toHaveBeenCalledTimes(2));

  await wrapper.setProps({
    currentChat: {
      id: 11964,
      display_id: 186,
      meta: { sender: { id: 78, name: 'Next customer' } },
    },
  });
  await vi.waitFor(() => expect(CrmDealsAPI.get).toHaveBeenCalledTimes(4));

  newLookup.resolve({
    data: {
      payload: [{ id: 2, primaryContactId: 78, title: 'New deal' }],
    },
  });
  newOriginLookup.resolve({ data: { payload: [] } });
  await flushPromises();

  const state = wrapper.vm.$.setupState;
  expect(state.deals.map(deal => deal.id)).toEqual([2]);
  expect(Object.keys(state.forms)).toContain('deal-2');

  oldLookup.resolve({
    data: {
      payload: [{ id: 1, primaryContactId: 77, title: 'Old deal' }],
    },
  });
  oldOriginLookup.resolve({ data: { payload: [] } });
  await flushPromises();

  expect(state.ui.error).toBeNull();
  expect(state.ui.isInitializing).toBe(false);
  expect(state.deals.map(deal => deal.id)).toEqual([2]);
  expect(Object.keys(state.forms)).toContain('deal-2');
  expect(Object.keys(state.forms)).not.toContain('deal-1');
});

it('preserves the update draft, reloads the lock version, and retries a conflict', async () => {
  const originalDeal = dealFixture();
  const authoritativeDeal = dealFixture({
    lockVersion: 2,
    title: 'Server title',
  });
  const savedDeal = dealFixture({ lockVersion: 3, title: 'Draft title' });
  CrmDealsAPI.update
    .mockRejectedValueOnce(staleError())
    .mockResolvedValueOnce({ data: { payload: savedDeal } });
  CrmDealsAPI.show.mockResolvedValue({
    data: { payload: authoritativeDeal },
  });
  const wrapper = await mountWithDeals([originalDeal]);
  const state = wrapper.vm.$.setupState;
  state.forms['deal-1'].title = 'Draft title';

  await state.saveDeal(state.accordionItems[0]);
  await flushPromises();

  expect(state.forms['deal-1'].title).toBe('Draft title');
  expect(state.deals[0]).toMatchObject(authoritativeDeal);
  expect(state.dealConflict).toMatchObject({
    active: true,
    hasAuthoritative: true,
    reloadFailed: false,
  });
  expect(wrapper.findComponent({ name: 'CrmConflictNotice' }).exists()).toBe(
    true
  );

  await state.saveDeal(state.accordionItems[0]);
  await flushPromises();

  expect(CrmDealsAPI.update).toHaveBeenNthCalledWith(
    2,
    1,
    expect.objectContaining({ lock_version: 2, title: 'Draft title' })
  );
  expect(state.deals[0]).toMatchObject(savedDeal);
  expect(state.forms['deal-1'].title).toBe('Draft title');
  expect(state.dealConflict.active).toBe(false);
});

it('rebases and retries when stage transition conflicts after update succeeds', async () => {
  const originalDeal = dealFixture();
  const updatedDeal = dealFixture({ lockVersion: 2, title: 'Draft title' });
  const authoritativeDeal = dealFixture({
    lockVersion: 3,
    title: 'Draft title',
  });
  const transitionedDeal = dealFixture({
    lockVersion: 4,
    stageId: 101,
    title: 'Draft title',
  });
  CrmDealsAPI.update.mockResolvedValueOnce({ data: { payload: updatedDeal } });
  CrmDealsAPI.transitionStage
    .mockRejectedValueOnce(staleError())
    .mockResolvedValueOnce({ data: { payload: transitionedDeal } });
  CrmDealsAPI.show.mockResolvedValue({
    data: { payload: authoritativeDeal },
  });
  const wrapper = await mountWithDeals([originalDeal]);
  const state = wrapper.vm.$.setupState;
  state.forms['deal-1'].title = 'Draft title';
  state.forms['deal-1'].stageId = 101;

  await state.saveDeal(state.accordionItems[0]);
  await flushPromises();

  expect(state.forms['deal-1']).toMatchObject({
    stageId: 101,
    title: 'Draft title',
  });
  expect(state.deals[0].lockVersion).toBe(3);
  expect(state.dealConflict.hasAuthoritative).toBe(true);

  await state.saveDeal(state.accordionItems[0]);
  await flushPromises();

  expect(CrmDealsAPI.update).toHaveBeenCalledTimes(1);
  expect(CrmDealsAPI.transitionStage).toHaveBeenNthCalledWith(2, 1, {
    closing_reasons: [],
    lock_version: 3,
    stage_id: 101,
  });
  expect(state.deals[0]).toMatchObject(transitionedDeal);
  expect(state.dealConflict.active).toBe(false);
});

it('does not treat a non-stale HTTP 409 as an editable conflict', async () => {
  const duplicateError = new Error('Duplicate external reference');
  duplicateError.response = {
    status: 409,
    data: { code: 'DUPLICATE_EXTERNAL_REF' },
  };
  CrmDealsAPI.update.mockRejectedValue(duplicateError);
  const wrapper = await mountWithDeals([dealFixture()]);
  const state = wrapper.vm.$.setupState;

  await state.saveDeal(state.accordionItems[0]);
  await flushPromises();

  expect(CrmDealsAPI.show).not.toHaveBeenCalled();
  expect(state.dealConflict.active).toBe(false);
  expect(useAlert).toHaveBeenCalledWith('Duplicate external reference');
});

it('ignores a stale create completion and cannot clear the newer save state', async () => {
  const oldCreate = deferred();
  const newUpdate = deferred();
  CrmDealsAPI.create.mockReturnValue(oldCreate.promise);
  const wrapper = await mountWithDeals([]);
  const state = wrapper.vm.$.setupState;
  state.forms['new-deal'].title = 'Old conversation draft';
  const oldSave = state.saveDeal(state.accordionItems[0]);
  expect(state.savingDealKey).toBe('new-deal');

  const nextDeal = dealFixture({
    id: 2,
    primaryContactId: 78,
    title: 'Next conversation deal',
  });
  CrmDealsAPI.get.mockResolvedValue({ data: { payload: [nextDeal] } });
  await wrapper.setProps({
    currentChat: {
      id: 11964,
      display_id: 186,
      meta: { sender: { id: 78, name: 'Next customer' } },
    },
  });
  await flushPromises();

  CrmDealsAPI.update.mockReturnValue(newUpdate.promise);
  state.forms['deal-2'].title = 'Current draft';
  const currentSave = state.saveDeal(state.accordionItems[0]);
  expect(state.savingDealKey).toBe('deal-2');

  oldCreate.resolve({
    data: { payload: dealFixture({ id: 9, title: 'Stale created deal' }) },
  });
  await oldSave;
  await flushPromises();

  expect(state.savingDealKey).toBe('deal-2');
  expect(state.deals.map(deal => deal.id)).toEqual([2]);
  expect(Object.keys(state.forms)).not.toContain('deal-9');
  expect(useAlert).not.toHaveBeenCalled();

  newUpdate.resolve({
    data: {
      payload: { ...nextDeal, lockVersion: 2, title: 'Current draft' },
    },
  });
  await currentSave;
  await flushPromises();

  expect(state.savingDealKey).toBe('');
  expect(state.deals[0].title).toBe('Current draft');
  expect(useAlert).toHaveBeenCalledTimes(1);
});

it('does not publish an update completion after unmount', async () => {
  const update = deferred();
  CrmDealsAPI.update.mockReturnValue(update.promise);
  const wrapper = await mountWithDeals([dealFixture()]);
  const state = wrapper.vm.$.setupState;
  state.forms['deal-1'].title = 'Unmounted draft';
  const save = state.saveDeal(state.accordionItems[0]);

  wrapper.unmount();
  update.resolve({
    data: {
      payload: dealFixture({ lockVersion: 2, title: 'Unmounted draft' }),
    },
  });
  await save;
  await flushPromises();

  expect(state.deals[0].title).toBe('Original deal');
  expect(state.openDealKeys).toEqual(['deal-1']);
  expect(useAlert).not.toHaveBeenCalled();
});
