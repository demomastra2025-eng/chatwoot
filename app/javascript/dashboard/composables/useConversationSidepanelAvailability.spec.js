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
    const { activePanel, dealsAvailable, stop } = buildAvailability();

    expect(dealsAvailable.value).toBe(false);
    expect(activePanel.value).toBeNull();
    stop();
  });

  it('opens the CRM panel for a user with deal permission on an enabled account', () => {
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: ['crm_deal_manage'] }],
    };
    testState.uiSettings.value = { is_crm_deal_panel_open: true };
    const { activePanel, stop } = buildAvailability();

    expect(activePanel.value).toBe('deals');
    stop();
  });

  it('ignores a persisted appointments panel when scheduling is disabled', () => {
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: ['administrator'] }],
    };
    testState.isFeatureEnabledonAccount.value = vi.fn(
      (_accountId, feature) => feature !== 'scheduling'
    );
    testState.uiSettings.value = {
      is_scheduling_appointments_panel_open: true,
    };
    const { activePanel, appointmentsAvailable, stop } = buildAvailability();

    expect(appointmentsAvailable.value).toBe(false);
    expect(activePanel.value).toBeNull();
    stop();
  });

  it('uses the permissions of the current account only', () => {
    testState.currentUser.value = {
      accounts: [
        { id: 7, permissions: ['administrator'] },
        { id: 530, permissions: [] },
      ],
    };
    testState.uiSettings.value = {
      is_scheduling_appointments_panel_open: true,
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

  it('leaves the touch panel to its own handling', () => {
    testState.uiSettings.value = { is_touch_sidebar_open: true };
    const { activePanel, stop } = buildAvailability();

    expect(activePanel.value).toBeNull();
    stop();
  });
});
