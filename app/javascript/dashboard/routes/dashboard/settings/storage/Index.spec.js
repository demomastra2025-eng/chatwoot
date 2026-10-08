import { shallowMount, flushPromises } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useAlert } from 'dashboard/composables';
import { ref } from 'vue';

import StorageAPI from 'dashboard/api/storage';
import Index from './Index.vue';

const accountId = ref(43);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: { value: 'ru' } }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId }),
}));
vi.mock('dashboard/api/storage', () => ({
  default: {
    getStorage: vi.fn(),
    getTrash: vi.fn(),
    getHeavyFiles: vi.fn(),
    refresh: vi.fn(),
    previewCleanup: vi.fn(),
    moveToTrash: vi.fn(),
    restoreTrash: vi.fn(),
    emptyTrash: vi.fn(),
  },
}));

const mountPage = () =>
  shallowMount(Index, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        RouterLink: true,
        SettingsLayout: {
          template: '<main><slot name="header" /><slot name="body" /></main>',
        },
        BaseSettingsHeader: {
          template: '<header><slot name="actions" /></header>',
        },
      },
    },
  });

const button = (wrapper, label) =>
  wrapper.findAll('button').find(item => item.text().includes(label));
const openCleaner = async wrapper => {
  await button(wrapper, 'STORAGE.TABS.CLEANER').trigger('click');
  await flushPromises();
};
const fileFilter = wrapper =>
  wrapper
    .findAll('select')
    .find(select => select.find('option[value="documents"]').exists());
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};
const fileResponse = name => ({
  data: {
    files: [{ id: name, name, byte_size: 20, file_type: 'recording' }],
    recordings_pending: false,
  },
});

describe('Storage settings Cleaner list', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    accountId.value = 43;
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
    StorageAPI.refresh.mockResolvedValue({
      data: { storage: {}, refresh_status: 'queued' },
    });
    StorageAPI.moveToTrash.mockResolvedValue({
      data: { moved_count: 1, moved_bytes: 20 },
    });
    StorageAPI.restoreTrash.mockResolvedValue({ data: { restored_count: 1 } });
    StorageAPI.emptyTrash.mockResolvedValue({ data: { purged_count: 1 } });
    StorageAPI.previewCleanup.mockResolvedValue({
      data: { total_count: 1, total_bytes: 20, confirmation_token: 'receipt' },
    });
    vi.spyOn(window, 'confirm').mockReturnValue(true);
  });

  it('loads the list only when Cleaner opens and shows the pending hint', async () => {
    const wrapper = mountPage();
    await flushPromises();
    expect(StorageAPI.getHeavyFiles).not.toHaveBeenCalled();

    const cleanerTab = wrapper
      .findAll('button')
      .find(item => item.text().includes('STORAGE.TABS.CLEANER'));
    await cleanerTab.trigger('click');
    await flushPromises();

    expect(StorageAPI.getHeavyFiles).toHaveBeenCalledOnce();
    expect(wrapper.text()).toContain('STORAGE.HEAVY_FILES.RECORDINGS_PENDING');
    expect(wrapper.text()).not.toContain('STORAGE.HEAVY_FILES.EMPTY');

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
      .find(item => item.text().includes('STORAGE.REFRESH'));
    await refresh.trigger('click');
    await flushPromises();

    expect(StorageAPI.getHeavyFiles).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('keeps the latest filtered results when the old response arrives last', async () => {
    const old = deferred();
    const latest = deferred();
    StorageAPI.getHeavyFiles
      .mockReturnValueOnce(old.promise)
      .mockReturnValueOnce(latest.promise);
    const wrapper = mountPage();
    await flushPromises();
    await openCleaner(wrapper);
    await fileFilter(wrapper).setValue('recordings');
    latest.resolve(fileResponse('latest recording'));
    await flushPromises();
    old.resolve(fileResponse('old document'));
    await flushPromises();

    expect(wrapper.text()).toContain('latest recording');
    expect(wrapper.text()).not.toContain('old document');
    expect(wrapper.text()).toContain('STORAGE.TYPES.RECORDINGS');
    expect(wrapper.text()).toContain('📞');
    wrapper.unmount();
  });

  it('ignores stale failures and leaves the newest request loading until it finishes', async () => {
    const old = deferred();
    const latest = deferred();
    StorageAPI.getHeavyFiles
      .mockReturnValueOnce(old.promise)
      .mockReturnValueOnce(latest.promise);
    const wrapper = mountPage();
    await flushPromises();
    await openCleaner(wrapper);
    await fileFilter(wrapper).setValue('recordings');
    old.reject(new Error('old failure'));
    await flushPromises();
    expect(useAlert).not.toHaveBeenCalled();
    expect(wrapper.vm.isLoadingFiles).toBe(true);
    latest.resolve(fileResponse('latest recording'));
    await flushPromises();
    expect(wrapper.vm.isLoadingFiles).toBe(false);
    expect(wrapper.text()).toContain('latest recording');
    wrapper.unmount();
  });

  it('shows a loading error instead of claiming that a failed query found no files', async () => {
    StorageAPI.getHeavyFiles.mockRejectedValue(new Error('unavailable'));
    const wrapper = mountPage();
    await flushPromises();
    await openCleaner(wrapper);
    expect(wrapper.text()).toContain('STORAGE.HEAVY_FILES_ERROR');
    expect(wrapper.text()).not.toContain('STORAGE.HEAVY_FILES.EMPTY');
    wrapper.unmount();
  });

  it('discards a previous account response after the active account changes', async () => {
    const old = deferred();
    StorageAPI.getHeavyFiles
      .mockReturnValueOnce(old.promise)
      .mockResolvedValue(fileResponse('account 44 recording'));
    const wrapper = mountPage();
    await flushPromises();
    await openCleaner(wrapper);
    accountId.value = 44;
    await flushPromises();
    old.resolve(fileResponse('account 43 recording'));
    await flushPromises();

    expect(wrapper.text()).toContain('account 44 recording');
    expect(wrapper.text()).not.toContain('account 43 recording');
    wrapper.unmount();
  });

  it.each([
    'executeMoveToTrash',
    'restoreTrashItem',
    'restoreAllTrash',
    'purgeTrashItem',
    'emptyAllTrash',
  ])(
    'reloads the visible heavy files after %s and protects them from an older request',
    async action => {
      StorageAPI.getHeavyFiles.mockResolvedValue(fileResponse('before action'));
      const wrapper = mountPage();
      await flushPromises();
      await openCleaner(wrapper);
      if (action === 'executeMoveToTrash') await wrapper.vm.runPreview();
      const old = deferred();
      StorageAPI.getHeavyFiles
        .mockReturnValueOnce(old.promise)
        .mockResolvedValue(fileResponse('after action'));
      wrapper.vm.fetchHeavyFiles();
      await wrapper.vm[action]({ item_type: 'recording', id: 2 });
      old.resolve(fileResponse('stale before action'));
      await flushPromises();

      expect(wrapper.text()).toContain('after action');
      expect(wrapper.text()).not.toContain('stale before action');
      expect(StorageAPI.getHeavyFiles).toHaveBeenCalledTimes(3);
      wrapper.unmount();
    }
  );

  it('does not tell the user another refresh was queued when a job is already pending', async () => {
    StorageAPI.refresh.mockResolvedValue({
      data: { storage: {}, refresh_status: 'pending' },
    });
    const wrapper = mountPage();
    await flushPromises();
    await button(wrapper, 'STORAGE.REFRESH').trigger('click');
    await flushPromises();
    expect(useAlert).toHaveBeenLastCalledWith('STORAGE.REFRESH_PENDING');
    expect(useAlert).not.toHaveBeenCalledWith('STORAGE.REFRESH_QUEUED');
    wrapper.unmount();
  });

  it('clears the pending hint automatically after background sizes become available', async () => {
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
    const wrapper = mountPage();
    await flushPromises();
    await openCleaner(wrapper);
    StorageAPI.getHeavyFiles.mockResolvedValue(
      fileResponse('calculated recording')
    );
    await vi.advanceTimersByTimeAsync(10000);
    await flushPromises();

    expect(wrapper.text()).toContain('calculated recording');
    expect(wrapper.text()).not.toContain(
      'STORAGE.HEAVY_FILES.RECORDINGS_PENDING'
    );
    wrapper.unmount();
    vi.useRealTimers();
  });
});
