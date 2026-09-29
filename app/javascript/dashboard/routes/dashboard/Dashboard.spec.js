import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';

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
  const { ref } = await vi.importActual('vue');
  return { useAccount: () => ({ accountId: ref(1) }) };
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
      stubs: { 'router-view': true },
    },
  });

describe('Dashboard call windows', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
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
