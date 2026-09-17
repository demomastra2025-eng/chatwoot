import { shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useInboxStore } from 'dashboard/stores/inboxes';
import InboxReports from './InboxReports.vue';
import InboxReportsIndex from './InboxReportsIndex.vue';
import SummaryReports from './components/SummaryReports.vue';
import WootReports from './components/WootReports.vue';

const mountOptions = pinia => ({
  global: {
    plugins: [pinia],
    mocks: { $t: key => key },
  },
});

describe('inbox report item provider', () => {
  let pinia;
  let inboxStore;

  beforeEach(() => {
    pinia = createPinia();
    setActivePinia(pinia);
    inboxStore = useInboxStore();
    inboxStore.records = [{ id: 1, name: 'Support' }];
    vi.spyOn(inboxStore, 'get').mockResolvedValue();
  });

  it('provides Pinia inboxes to detailed reports', async () => {
    const wrapper = shallowMount(InboxReports, mountOptions(pinia));
    const reports = wrapper.findComponent(WootReports);

    expect(reports.props('items')).toEqual([{ id: 1, name: 'Support' }]);
    await reports.props('fetchItems')();
    expect(inboxStore.get).toHaveBeenCalledOnce();
  });

  it('provides Pinia inboxes to summary reports', async () => {
    const wrapper = shallowMount(InboxReportsIndex, mountOptions(pinia));
    const reports = wrapper.findComponent(SummaryReports);

    expect(reports.props('items')).toEqual([{ id: 1, name: 'Support' }]);
    await reports.props('fetchItems')();
    expect(inboxStore.get).toHaveBeenCalledOnce();
  });
});
