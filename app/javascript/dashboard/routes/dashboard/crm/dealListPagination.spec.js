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
    {
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
import ConversationAPI from 'dashboard/api/conversations';
import { useAlert } from 'dashboard/composables';
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
  CrmDealsAPI.show.mockReset();
  CrmDealsAPI.timeline.mockReset().mockResolvedValue(response([]));
  CrmDealsAPI.update.mockReset();
  ConversationAPI.create.mockReset();
  useAlert.mockClear();
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
