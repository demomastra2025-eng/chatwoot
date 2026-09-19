import { nextTick, reactive, ref } from 'vue';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import ContactsIndex from './ContactsIndex.vue';
import ContactsListLayout from 'dashboard/components-next/Contacts/ContactsListLayout.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  replace: vi.fn(),
  route: null,
  getters: {},
  updateUISettings: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => ({ replace: mocks.replace }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key => mocks.getters[key],
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: ref({ contacts_sort_by: '' }),
    updateUISettings: mocks.updateUISettings,
  }),
}));

vi.mock('dashboard/api/bulkActions', () => ({
  default: { create: vi.fn() },
}));

const mountPage = async () => {
  const wrapper = shallowMount(ContactsIndex, {
    global: {
      renderStubDefaultSlot: true,
    },
  });
  await flushPromises();
  await nextTick();
  return wrapper;
};

const listRequests = () =>
  mocks.dispatch.mock.calls.filter(([action]) =>
    [
      'contacts/get',
      'contacts/search',
      'contacts/filter',
      'contacts/active',
    ].includes(action)
  );

describe('ContactsIndex pagination context', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.route = reactive({
      name: 'contacts_dashboard_index',
      params: { accountId: '1' },
      query: { page: '1' },
    });
    mocks.getters = {
      'contacts/getContactsList': ref([]),
      'contacts/getUIFlags': ref({ isFetching: false }),
      'customViews/getUIFlags': ref({ isFetching: false }),
      'customViews/getContactCustomViews': ref([]),
      'contacts/getAppliedContactFilters': ref([]),
      'contacts/getMeta': ref({ count: 0, currentPage: 1 }),
      'labels/getLabels': ref([]),
    };
    mocks.dispatch.mockImplementation(action => {
      if (
        [
          'contacts/get',
          'contacts/search',
          'contacts/filter',
          'contacts/active',
        ].includes(action)
      ) {
        return Promise.resolve(true);
      }
      return Promise.resolve();
    });
    mocks.replace.mockImplementation(async ({ query }) => {
      mocks.route.query = { ...query };
      await nextTick();
    });
    mocks.updateUISettings.mockResolvedValue();
  });

  afterEach(() => {
    emitter.all.clear();
    vi.clearAllMocks();
    vi.useRealTimers();
  });

  it('keeps realtime reloads in the newest pending search context', async () => {
    const wrapper = await mountPage();
    mocks.dispatch.mockClear();

    wrapper
      .findComponent(ContactsListLayout)
      .vm.$emit('search', 'new customer');
    await vi.advanceTimersByTimeAsync(300);
    await flushPromises();

    expect(listRequests()).toContainEqual([
      'contacts/search',
      expect.objectContaining({ search: 'new%20customer', page: 1 }),
    ]);

    mocks.dispatch.mockClear();
    emitter.emit(BUS_EVENTS.CONTACT_REALTIME_EVENT, {
      account_id: 1,
      id: 42,
      event: 'contact.updated',
    });
    await vi.advanceTimersByTimeAsync(300);
    await flushPromises();

    expect(listRequests()).toEqual([
      [
        'contacts/search',
        expect.objectContaining({ search: 'new%20customer', page: 1 }),
      ],
    ]);
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'contacts/get',
      expect.anything()
    );

    wrapper.unmount();
  });

  it('reloads page one when browser navigation changes the company query', async () => {
    const wrapper = await mountPage();
    mocks.dispatch.mockClear();

    mocks.route.query = { page: '1', company: 'Company B' };
    await nextTick();
    await flushPromises();

    expect(listRequests()).toEqual([
      [
        'contacts/get',
        expect.objectContaining({ company: 'Company B', page: 1 }),
      ],
    ]);

    wrapper.unmount();
  });

  it('cancels a pending search when the company context changes', async () => {
    const wrapper = await mountPage();
    mocks.dispatch.mockClear();

    wrapper
      .findComponent(ContactsListLayout)
      .vm.$emit('search', 'stale search');
    wrapper
      .findComponent(ContactsListLayout)
      .vm.$emit('update:company-filter', 'Company B');
    await flushPromises();
    await vi.advanceTimersByTimeAsync(300);
    await flushPromises();

    expect(listRequests()).toEqual([
      [
        'contacts/search',
        expect.objectContaining({
          company: 'Company B',
          page: 1,
          search: 'stale%20search',
        }),
      ],
    ]);

    wrapper.unmount();
  });
});
