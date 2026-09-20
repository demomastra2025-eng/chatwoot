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
        stages: [{ id: 100, active: true, default: true, name: 'New' }],
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
  default: new Proxy(
    { get: vi.fn() },
    { get: (target, key) => target[key] || vi.fn() }
  ),
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
import CrmConversationDealsSidebar from './CrmConversationDealsSidebar.vue';

const currentChat = {
  id: 11963,
  display_id: 185,
  meta: { sender: { id: 77, name: 'Customer' } },
};

const deferred = () => {
  let resolve;
  const promise = new Promise(promiseResolve => {
    resolve = promiseResolve;
  });
  return { promise, resolve };
};

beforeEach(() => {
  vi.clearAllMocks();
  CompanyAPI.get.mockResolvedValue({ data: { payload: [] } });
  CrmDealsAPI.get.mockResolvedValue({ data: { payload: [] } });
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
