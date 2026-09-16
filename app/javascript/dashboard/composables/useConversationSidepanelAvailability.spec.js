import { effectScope } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useConversationSidepanelAvailability } from './useConversationSidepanelAvailability';

const testState = vi.hoisted(() => ({
  currentAccountId: { __v_isRef: true, value: 530 },
  currentUser: {
    __v_isRef: true,
    value: { accounts: [{ id: 530, permissions: [] }] },
  },
  isFeatureEnabledonAccount: {
    __v_isRef: true,
    value: vi.fn(),
  },
  uiSettings: {
    __v_isRef: true,
    value: {},
  },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: testState.uiSettings }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key =>
    ({
      getCurrentAccountId: testState.currentAccountId,
      getCurrentUser: testState.currentUser,
      'accounts/isFeatureEnabledonAccount': testState.isFeatureEnabledonAccount,
    })[key],
}));

const buildAvailability = () => {
  const scope = effectScope();
  const result = scope.run(() => useConversationSidepanelAvailability());
  return { ...result, stop: () => scope.stop() };
};

describe('useConversationSidepanelAvailability', () => {
  beforeEach(() => {
    testState.currentAccountId.value = 530;
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: [] }],
    };
    testState.isFeatureEnabledonAccount.value = vi.fn(() => true);
    testState.uiSettings.value = {};
  });

  it('ignores a persisted CRM panel when the user lacks permission', () => {
    testState.uiSettings.value = { is_crm_deal_panel_open: true };
    const { activePanel, stop } = buildAvailability();

    expect(activePanel.value).toBeNull();
    stop();
  });

  it('ignores persisted scheduling and touch panels when their features are disabled', () => {
    testState.isFeatureEnabledonAccount.value = vi.fn(
      (_accountId, feature) => feature === 'crm_deals'
    );
    testState.uiSettings.value = {
      is_scheduling_appointments_panel_open: true,
      is_touch_sidebar_open: true,
    };
    const { activePanel, stop } = buildAvailability();

    expect(activePanel.value).toBeNull();
    stop();
  });

  it('keeps the contact panel available independently of feature flags', () => {
    testState.isFeatureEnabledonAccount.value = vi.fn(() => false);
    testState.uiSettings.value = { is_contact_sidebar_open: true };
    const { activePanel, stop } = buildAvailability();

    expect(activePanel.value).toBe('contact');
    stop();
  });
});
