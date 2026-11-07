import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';

const accountState = vi.hoisted(() => ({ account: null, admin: false }));

vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref } = await vi.importActual('vue');
  return {
    useUISettings: () => ({
      uiSettings: ref({}),
      updateUISettings: vi.fn(),
    }),
  };
});
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ shouldShow: () => accountState.admin }),
}));
vi.mock('dashboard/composables/useAccount', async () => {
  const { ref } = await vi.importActual('vue');
  return {
    useAccount: () => ({
      accountId: ref(1),
      currentAccount: ref(accountState.account),
    }),
  };
});
const whatsappCallsState = vi.hoisted(() => ({
  hasActiveCall: false,
  hasIncomingCall: false,
}));

vi.mock('dashboard/stores/whatsappCalls', async () => {
  const { reactive } = await vi.importActual('vue');
  const reactiveState = reactive(whatsappCallsState);
  return {
    useWhatsappCallsStore: () => reactiveState,
  };
});
vi.mock('next/sidebar/Sidebar.vue', () => ({
  default: { name: 'NextSidebar', template: '<aside />' },
}));
vi.mock('dashboard/components/widgets/modal/WootKeyShortcutModal.vue', () => ({
  default: { name: 'WootKeyShortcutModal', template: '<div />' },
}));
vi.mock('dashboard/components/app/AddAccountModal.vue', () => ({
  default: { name: 'AddAccountModal', template: '<div />' },
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
  default: {
    name: 'WhatsappCallWidget',
    template: '<div data-testid="standalone-whatsapp-widget" />',
  },
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
    accountState.account = null;
    accountState.admin = false;
    setActivePinia(createPinia());
    whatsappCallsState.hasActiveCall = false;
    whatsappCallsState.hasIncomingCall = false;
  });

  it('shows the trial end date to account administrators only', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-28T10:00:00+05:00'));
    accountState.account = {
      custom_attributes: {
        plan_type: 'trial',
        trial_expires_at: '2026-10-31T13:30:00+05:00',
      },
    };
    accountState.admin = true;
    const adminView = mountDashboard();
    await flushPromises();
    expect(adminView.vm.trialExpiryDate).toBe('31.10');
    expect(adminView.find('[data-testid="trial-active-banner"]').exists()).toBe(
      true
    );

    accountState.admin = false;
    const agentView = mountDashboard();
    await flushPromises();
    expect(agentView.find('[data-testid="trial-active-banner"]').exists()).toBe(
      false
    );
    vi.useRealTimers();
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
    expect(
      wrapper.find('[data-testid="standalone-whatsapp-widget"]').exists()
    ).toBe(false);

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
    expect(wrapper.vm.trialTimer).toBeNull();
  });

  it('renders a mobile sidebar backdrop when open and closes the sidebar on tap without propagating clicks', async () => {
    const wrapper = mountDashboard();
    await flushPromises();

    expect(
      wrapper.find('[data-testid="mobile-sidebar-backdrop"]').exists()
    ).toBe(false);

    wrapper.vm.toggleMobileSidebar();
    await flushPromises();

    const backdrop = wrapper.find('[data-testid="mobile-sidebar-backdrop"]');
    expect(backdrop.exists()).toBe(true);

    await backdrop.trigger('click');
    await flushPromises();

    expect(wrapper.vm.isMobileSidebarOpen).toBe(false);
    expect(
      wrapper.find('[data-testid="mobile-sidebar-backdrop"]').exists()
    ).toBe(false);
  });
});
