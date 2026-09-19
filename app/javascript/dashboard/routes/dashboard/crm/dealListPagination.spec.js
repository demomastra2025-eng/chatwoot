import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const { runtime, referencesStore } = vi.hoisted(() => ({
  runtime: { accountId: null },
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
vi.mock('vue-router', () => ({
  onBeforeRouteLeave: vi.fn(),
  useRoute: () => ({ query: {}, params: { accountId: 1 } }),
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(), resolve: vi.fn() }),
}));
vi.mock('dashboard/api/crm/deals', () => ({
  default: new Proxy(
    { get: vi.fn(), transitionStage: vi.fn(), update: vi.fn() },
    { get: (target, key) => target[key] || vi.fn() }
  ),
}));
vi.mock('dashboard/api/companies', () => ({
  default: { get: vi.fn() },
}));
vi.mock('dashboard/api/contacts', () => ({
  default: { get: vi.fn() },
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
    useStore: () => ({ dispatch: vi.fn() }),
  };
});
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => referencesStore,
}));

import CrmDealsAPI from 'dashboard/api/crm/deals';
import CrmDealsPage from './pages/CrmDealsPage.vue';

const response = (payload, meta = {}) => ({ data: { payload, meta } });
const deferred = () => {
  let resolve;
  const promise = new Promise(done => {
    resolve = done;
  });
  return { promise, resolve };
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

const mountPage = async () => {
  const wrapper = shallowMount(CrmDealsPage, {
    global: { mocks: { $t: key => key } },
  });
  wrappers.push(wrapper);
  await flushPromises();
  return { state: wrapper.vm.$.setupState, wrapper };
};

beforeEach(() => {
  vi.clearAllMocks();
  localStorage.clear();
  runtime.accountId.value = 1;
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
});

afterEach(() => {
  wrappers.splice(0).forEach(wrapper => wrapper.unmount());
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
