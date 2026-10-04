import { nextTick, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import StorageUsageBanner from './StorageUsageBanner.vue';
import StorageAPI from 'dashboard/api/storage';
import Banner from 'dashboard/components/ui/Banner.vue';

const mocks = vi.hoisted(() => ({
  getStorage: vi.fn(),
  routerPush: vi.fn(),
  useAccount: vi.fn(),
  useAdmin: vi.fn(),
}));

vi.mock('dashboard/api/storage', () => ({
  default: { getStorage: mocks.getStorage },
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: mocks.useAccount,
}));
vi.mock('dashboard/composables/useAdmin', () => ({ useAdmin: mocks.useAdmin }));
vi.mock('vue-router', () => ({
  useRouter: () => ({ push: mocks.routerPush }),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values) => (values ? `${key}:${values.percentage}` : key),
  }),
}));

const storageResponse = percentage => ({
  data: {
    storage: {
      unlimited: false,
      usage_percent: percentage,
      consumed_bytes: percentage,
      total_limit_bytes: 100,
    },
  },
});

const mountBanner = () => mount(StorageUsageBanner);

describe('StorageUsageBanner', () => {
  let accountId;
  let isAdmin;

  beforeEach(() => {
    vi.clearAllMocks();
    window.localStorage.clear();
    accountId = ref('11');
    isAdmin = ref(true);
    mocks.useAccount.mockReturnValue({ accountId });
    mocks.useAdmin.mockReturnValue({ isAdmin });
    mocks.getStorage.mockResolvedValue(storageResponse(82));
  });

  it('loads cached usage for administrators and links to storage settings', async () => {
    const wrapper = mountBanner();
    await flushPromises();

    expect(StorageAPI.getStorage).toHaveBeenCalledTimes(1);
    const banner = wrapper.findComponent(Banner);
    expect(banner.exists()).toBe(true);
    expect(banner.props('bannerMessage')).toBe(
      'STORAGE.ALERTS.GLOBAL_WARNING:82'
    );

    banner.vm.$emit('primaryAction');
    expect(mocks.routerPush).toHaveBeenCalledWith({
      name: 'storage_settings_index',
      params: { accountId: '11' },
    });

    banner.vm.$emit('close');
    await nextTick();
    expect(
      JSON.parse(window.localStorage.getItem('storage-alert:11')).until
    ).toBeGreaterThan(Date.now());
    expect(wrapper.findComponent(Banner).exists()).toBe(false);
    wrapper.unmount();
  });

  it('shows the actual over-limit percentage instead of capping it at 100', async () => {
    mocks.getStorage.mockResolvedValue(storageResponse(127.5));
    const wrapper = mountBanner();
    await flushPromises();

    expect(wrapper.findComponent(Banner).props('bannerMessage')).toBe(
      'STORAGE.ALERTS.GLOBAL_CRITICAL:127.5'
    );
    wrapper.unmount();
  });

  it('does not request or display account quota for non-administrators', async () => {
    isAdmin.value = false;
    const wrapper = mountBanner();
    await flushPromises();

    expect(StorageAPI.getStorage).not.toHaveBeenCalled();
    expect(wrapper.findComponent(Banner).exists()).toBe(false);
    wrapper.unmount();
  });

  it('reloads quota when the selected account changes', async () => {
    const wrapper = mountBanner();
    await flushPromises();
    expect(StorageAPI.getStorage).toHaveBeenCalledTimes(1);

    accountId.value = '22';
    await flushPromises();

    expect(StorageAPI.getStorage).toHaveBeenCalledTimes(2);
    expect(wrapper.findComponent(Banner).props('bannerMessage')).toBe(
      'STORAGE.ALERTS.GLOBAL_WARNING:82'
    );
    wrapper.unmount();
  });
  it('refreshes cached usage during a long-running admin session', async () => {
    vi.useFakeTimers();
    const wrapper = mountBanner();
    try {
      await flushPromises();
      expect(StorageAPI.getStorage).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(15 * 60 * 1000);
      await flushPromises();

      expect(StorageAPI.getStorage).toHaveBeenCalledTimes(2);
    } finally {
      wrapper.unmount();
      vi.useRealTimers();
    }
  });

  it('shows a dismissed warning again after 24 hours', async () => {
    vi.useFakeTimers();
    const wrapper = mountBanner();
    try {
      await flushPromises();
      wrapper.findComponent(Banner).vm.$emit('close');
      await nextTick();
      expect(wrapper.findComponent(Banner).exists()).toBe(false);

      const dismissedUntil = JSON.parse(
        window.localStorage.getItem('storage-alert:11')
      ).until;
      vi.setSystemTime(dismissedUntil);
      await vi.advanceTimersByTimeAsync(60 * 1000);
      await flushPromises();

      expect(wrapper.findComponent(Banner).exists()).toBe(true);
    } finally {
      wrapper.unmount();
      vi.useRealTimers();
    }
  });
});
