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
      is_touch_sidebar_open: false,
    },
  },
  updateUISettings: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: testState.uiSettings,
    updateUISettings: testState.updateUISettings,
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
      is_touch_sidebar_open: false,
    };
    testState.isFeatureEnabledonAccount.value = () => true;
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
      is_touch_sidebar_open: false,
    });
  });
});
