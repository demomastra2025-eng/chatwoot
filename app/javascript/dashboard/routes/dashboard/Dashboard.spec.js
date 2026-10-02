import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';

let mockCurrentAccountData = null;

vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref } = await vi.importActual('vue');
  return {
    useUISettings: () => ({
      uiSettings: ref({}),
      updateUISettings: vi.fn(),
    }),
  };
});
vi.mock('dashboard/composables/useAccount', async () => {
  const { ref, computed } = await vi.importActual('vue');
  return {
    useAccount: () => ({
      accountId: ref(1),
      currentAccount: computed(() => mockCurrentAccountData),
    }),
  };
});
vi.mock('dashboard/stores/whatsappCalls', () => ({
  useWhatsappCallsStore: () => ({
    hasActiveCall: false,
    hasIncomingCall: false,
  }),
}));
vi.mock('next/sidebar/Sidebar.vue', () => ({
  default: { name: 'NextSidebar', template: '<aside />' },
}));
vi.mock('dashboard/components/widgets/modal/WootKeyShortcutModal.vue', () => ({
  default: { name: 'WootKeyShortcutModal', template: '<div />' },
}));
vi.mock('dashboard/components/app/AddAccountModal.vue', () => ({
  default: { name: 'AddAccountModal', template: '<div />' },
}));
vi.mock('dashboard/routes/dashboard/upgrade/UpgradePage.vue', () => ({
  default: { name: 'UpgradePage', template: '<div><slot /></div>' },
}));
vi.mock('dashboard/components-next/sidebar/MobileSidebarLauncher.vue', () => ({
  default: { name: 'MobileSidebarLauncher', template: '<div />' },
}));
vi.mock('./commands/commandbar.vue', () => ({
  __esModule: true,
  default: { name: 'CommandBar', template: '<div />' },
}));
vi.mock('dashboard/components/widgets/FloatingCallWidget.vue', () => ({
  __esModule: true,
  default: {
    name: 'FloatingCallWidget',
    template: '<div data-testid="standalone-call-cards" />',
  },
}));
vi.mock('dashboard/components/widgets/PhoneWidget.vue', () => ({
  __esModule: true,
  default: {
    name: 'PhoneWidget',
    template: '<div data-testid="phone-widget" />',
  },
}));
vi.mock('dashboard/components/widgets/WhatsappCallWidget.vue', () => ({
  __esModule: true,
  default: { name: 'WhatsappCallWidget', template: '<div />' },
}));

import Dashboard from './Dashboard.vue';

// Every child is mocked above with a light component.
const mountDashboard = () =>
  mount(Dashboard, {
    global: {
      mocks: { $route: { name: 'home' } },
      stubs: {
        'router-view': true,
        'router-link': { template: '<a><slot /></a>' },
      },
    },
  });

describe('Dashboard call windows', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    mockCurrentAccountData = null;
  });

  it('shows the standalone call cards only to employees without the phone widget', async () => {
    const wrapper = mountDashboard();
    // The call widgets are async components.
    await vi.dynamicImportSettled();
    await flushPromises();

    expect(wrapper.find('[data-testid="standalone-call-cards"]').exists()).toBe(
      true
    );
    expect(wrapper.find('[data-testid="phone-widget"]').exists()).toBe(true);

    // The phone widget reports a browser SIP line: calls move into it.
    usePhoneWidgetStore().publishSipState({ available: true, status: 'ready' });
    await flushPromises();

    expect(wrapper.find('[data-testid="standalone-call-cards"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-testid="phone-widget"]').exists()).toBe(true);

    usePhoneWidgetStore().publishSipState({ available: false });
    await vi.dynamicImportSettled();
    await flushPromises();
    expect(wrapper.find('[data-testid="standalone-call-cards"]').exists()).toBe(
      true
    );
  });
});

describe('Dashboard 3-day Full Free trial banner', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    mockCurrentAccountData = null;
  });

  it('does not display any trial banner for non-trial accounts', async () => {
    mockCurrentAccountData = { id: 1, custom_attributes: { plan_type: 'growth' } };
    const wrapper = mountDashboard();
    await flushPromises();

    expect(wrapper.find('[data-testid="trial-active-banner"]').exists()).toBe(false);
    expect(wrapper.find('[data-testid="trial-expired-banner"]').exists()).toBe(false);
  });

  it('displays active trial banner with countdown and upgrade link when trial is active', async () => {
    const futureDate = new Date(Date.now() + 2 * 86400000 + 14 * 3600000).toISOString();
    mockCurrentAccountData = {
      id: 1,
      custom_attributes: {
        plan_type: 'trial',
        trial_expires_at: futureDate,
      },
    };
    const wrapper = mountDashboard();
    await flushPromises();

    const banner = wrapper.find('[data-testid="trial-active-banner"]');
    expect(banner.exists()).toBe(true);
    expect(banner.text()).toContain('🎁 Пробный период (Full Free): осталось 2 дн.');
    expect(banner.text()).toContain('Доступны все каналы и AI');
    expect(banner.text()).toContain('Выбрать тариф');
  });

  it('displays warning banner when trial has expired', async () => {
    const pastDate = new Date(Date.now() - 3600000).toISOString();
    mockCurrentAccountData = {
      id: 1,
      custom_attributes: {
        plan_type: 'trial',
        trial_expires_at: pastDate,
      },
    };
    const wrapper = mountDashboard();
    await flushPromises();

    const banner = wrapper.find('[data-testid="trial-expired-banner"]');
    expect(banner.exists()).toBe(true);
    expect(banner.text()).toContain('⚠️ Пробный период завершён. Выберите тариф для продолжения работы.');
    expect(banner.text()).toContain('Выбрать тариф');
  });
});
