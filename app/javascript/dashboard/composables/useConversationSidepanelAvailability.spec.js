import { effectScope, reactive, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import {
  resetMobileConversationPanel,
  useConversationSidepanelAvailability,
} from './useConversationSidepanelAvailability';

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
  width: null,
  route: null,
  updateUISettings: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: testState.uiSettings,
    updateUISettings: testState.updateUISettings,
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => testState.route,
}));

vi.mock('@vueuse/core', () => ({
  useWindowSize: () => ({ width: testState.width }),
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
    testState.uiSettings = ref({});
    testState.width = ref(1280);
    testState.route = reactive({
      params: { accountId: '530', conversation_id: '42' },
    });
    testState.updateUISettings.mockImplementation(settings => {
      testState.uiSettings.value = {
        ...testState.uiSettings.value,
        ...settings,
      };
    });
    resetMobileConversationPanel();
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

  it('ignores a persisted reminders panel flag', () => {
    testState.uiSettings.value = { is_touch_sidebar_open: true };
    const { activePanel, stop } = buildAvailability();

    expect(activePanel.value).toBeNull();
    stop();
  });

  it('opens the conversation on a phone despite a desktop contact preference', () => {
    testState.uiSettings.value = { is_contact_sidebar_open: true };
    testState.width.value = 390;
    const { activePanel, openPanel, closePanel, stop } = buildAvailability();

    expect(activePanel.value).toBeNull();
    openPanel('contact');
    expect(activePanel.value).toBe('contact');
    closePanel();
    expect(activePanel.value).toBeNull();
    expect(testState.updateUISettings).not.toHaveBeenCalled();
    expect(testState.uiSettings.value.is_contact_sidebar_open).toBe(true);
    stop();
  });

  it('keeps a phone panel inside its conversation and restores desktop state on resize', () => {
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: ['administrator'] }],
    };
    testState.uiSettings.value = { is_contact_sidebar_open: true };
    testState.width.value = 390;
    const { activePanel, openPanel, stop } = buildAvailability();

    openPanel('appointments');
    expect(activePanel.value).toBe('appointments');
    testState.route.params.conversation_id = '43';
    expect(activePanel.value).toBeNull();
    testState.width.value = 1280;
    expect(activePanel.value).toBe('contact');
    stop();
  });

  it('scopes a phone panel on team routes that use conversationId', () => {
    testState.width.value = 390;
    testState.route.params = { accountId: '530', conversationId: '42' };
    const { activePanel, openPanel, stop } = buildAvailability();

    openPanel('contact');
    expect(activePanel.value).toBe('contact');
    testState.route.params.conversationId = '43';
    expect(activePanel.value).toBeNull();
    stop();
  });

  it('does not show a persisted deals panel on a phone until its button is used', () => {
    testState.currentUser.value = {
      accounts: [{ id: 530, permissions: ['crm_deal_manage'] }],
    };
    testState.uiSettings.value = { is_crm_deal_panel_open: true };
    testState.width.value = 390;
    const { activePanel, openPanel, closePanel, stop } = buildAvailability();

    expect(activePanel.value).toBeNull();
    openPanel('deals');
    expect(activePanel.value).toBe('deals');
    closePanel();
    expect(activePanel.value).toBeNull();
    stop();
  });

  it('retains desktop panel updates through the shared buttons', () => {
    const { activePanel, openPanel, closePanel, stop } = buildAvailability();

    openPanel('contact');
    expect(activePanel.value).toBe('contact');
    expect(testState.updateUISettings).toHaveBeenCalledWith({
      is_contact_sidebar_open: true,
      is_crm_deal_panel_open: false,
      is_scheduling_appointments_panel_open: false,
    });
    closePanel();
    expect(activePanel.value).toBeNull();
    stop();
  });
});
