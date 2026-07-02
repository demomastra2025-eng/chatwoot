import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SidepanelSwitch from './SidepanelSwitch.vue';

const testState = vi.hoisted(() => ({
  currentAccountId: { __v_isRef: true, value: 530 },
  currentUser: {
    __v_isRef: true,
    value: { accounts: [{ id: 530, permissions: ['crm_deal_manage'] }] },
  },
  isFeatureEnabledonAccount: { __v_isRef: true, value: () => true },
  uiSettings: {
    value: {
      is_contact_sidebar_open: false,
      is_copilot_panel_open: false,
      is_crm_deal_panel_open: false,
      is_scheduling_appointments_panel_open: false,
      is_touch_sidebar_open: false,
    },
  },
  currentAccount: { __v_isRef: true, value: { settings: {} } },
  updateUISettings: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: testState.uiSettings,
    updateUISettings: testState.updateUISettings,
  }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: testState.currentAccount,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key =>
    ({
      getCurrentAccountId: testState.currentAccountId,
      getCurrentUser: testState.currentUser,
      'accounts/isFeatureEnabledonAccount': testState.isFeatureEnabledonAccount,
    })[key],
}));

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('dashboard/featureFlags', () => ({
  FEATURE_FLAGS: {
    CAMPAIGNS: 'campaigns',
    CAPTAIN: 'captain',
    CRM_DEALS: 'crm_deals',
    SCHEDULING: 'scheduling',
  },
}));

const mountComponent = () =>
  shallowMount(SidepanelSwitch, {
    global: {
      stubs: {
        ButtonGroup: { template: '<div><slot /></div>' },
        Button: {
          props: ['icon'],
          template: '<button type="button" :data-icon="icon" />',
        },
      },
    },
  });

describe('SidepanelSwitch', () => {
  beforeEach(() => {
    testState.uiSettings.value = {
      is_contact_sidebar_open: false,
      is_copilot_panel_open: false,
      is_crm_deal_panel_open: false,
      is_scheduling_appointments_panel_open: false,
      is_touch_sidebar_open: false,
    };
    testState.isFeatureEnabledonAccount.value = () => true;
    testState.currentAccount.value = { settings: {} };
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: ['crm_deal_manage'] }],
    };
    testState.updateUISettings.mockClear();
  });

  it('opens the CRM deals sidebar from the floating switch', async () => {
    const wrapper = mountComponent();

    await wrapper
      .find('[data-icon="i-lucide-briefcase-business"]')
      .trigger('click');

    expect(testState.updateUISettings).toHaveBeenCalledWith({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: true,
      is_copilot_panel_open: false,
      is_scheduling_appointments_panel_open: false,
      is_touch_sidebar_open: false,
    });
  });

  it('opens the scheduling appointments sidebar from the floating switch', async () => {
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: ['agent'] }],
    };
    const wrapper = mountComponent();

    await wrapper
      .find('[data-icon="i-lucide-calendar-clock"]')
      .trigger('click');

    expect(testState.updateUISettings).toHaveBeenCalledWith({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: false,
      is_copilot_panel_open: false,
      is_scheduling_appointments_panel_open: true,
      is_touch_sidebar_open: false,
    });
  });

  it('hides the CRM deals switch when conversation pipelines are hidden by account policy', () => {
    testState.currentAccount.value = {
      settings: {
        dashboard_sidebar_hidden_items: ['Conversation:Pipelines'],
        dashboard_sidebar_hidden_items_version: 13,
      },
    };

    const wrapper = mountComponent();

    expect(
      wrapper.find('[data-icon="i-lucide-briefcase-business"]').exists()
    ).toBe(false);
  });

  it('hides the scheduling switch when appointment statuses are hidden by account policy', () => {
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: ['agent'] }],
    };
    testState.currentAccount.value = {
      settings: {
        dashboard_sidebar_hidden_items: ['Conversation:AppointmentStatuses'],
        dashboard_sidebar_hidden_items_version: 13,
      },
    };

    const wrapper = mountComponent();

    expect(wrapper.find('[data-icon="i-lucide-calendar-clock"]').exists()).toBe(
      false
    );
  });
});
