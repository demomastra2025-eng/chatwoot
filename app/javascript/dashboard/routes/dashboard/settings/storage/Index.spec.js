import { shallowMount, flushPromises } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import StorageAPI from 'dashboard/api/storage';
import Index from './Index.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: { value: 'ru' } }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId: { value: 43 } }),
}));
vi.mock('dashboard/api/storage', () => ({
  default: {
    getStorage: vi.fn(),
    getTrash: vi.fn(),
    getHeavyFiles: vi.fn(),
    refresh: vi.fn(),
  },
}));

const mountPage = () =>
  shallowMount(Index, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        SettingsLayout: {
          template: '<main><slot name="header" /><slot name="body" /></main>',
        },
        BaseSettingsHeader: {
          template: '<header><slot name="actions" /></header>',
        },
      },
    },
  });

describe('Storage settings Cleaner list', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    StorageAPI.getStorage.mockResolvedValue({
      data: {
        storage: {
          calculating: false,
          breakdown: { by_inbox: [], total: 0 },
          usage_percent: 0,
          consumed_bytes: 0,
          total_limit_bytes: 0,
        },
      },
    });
    StorageAPI.getTrash.mockResolvedValue({
      data: { total_count: 0, total_bytes: 0, items: [] },
    });
    StorageAPI.getHeavyFiles.mockResolvedValue({
      data: { files: [], recordings_pending: true },
    });
    StorageAPI.refresh.mockResolvedValue({ data: { storage: {} } });
  });

  it('loads the list only when Cleaner opens and shows the pending hint', async () => {
    const wrapper = mountPage();
    await flushPromises();
    expect(StorageAPI.getHeavyFiles).not.toHaveBeenCalled();

    const cleanerTab = wrapper
      .findAll('button')
      .find(button => button.text().includes('STORAGE.TABS.CLEANER'));
    await cleanerTab.trigger('click');
    await flushPromises();

    expect(StorageAPI.getHeavyFiles).toHaveBeenCalledOnce();
    expect(wrapper.text()).toContain('STORAGE.HEAVY_FILES.RECORDINGS_PENDING');

    const fileTypeFilter = wrapper
      .findAll('select')
      .find(select => select.find('option[value="documents"]').exists());
    await fileTypeFilter.setValue('recordings');
    await flushPromises();
    expect(StorageAPI.getHeavyFiles).toHaveBeenCalledTimes(2);
    expect(StorageAPI.getHeavyFiles).toHaveBeenLastCalledWith({
      file_type: 'recordings',
      limit: 50,
    });
    wrapper.unmount();
  });

  it('does not load the Cleaner list after Overview refresh', async () => {
    const wrapper = mountPage();
    await flushPromises();
    const refresh = wrapper
      .findAll('button')
      .find(button => button.text().includes('STORAGE.REFRESH'));
    await refresh.trigger('click');
    await flushPromises();

    expect(StorageAPI.getHeavyFiles).not.toHaveBeenCalled();
    wrapper.unmount();
  });
});
