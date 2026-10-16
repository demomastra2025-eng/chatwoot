import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import Scheduling from './Scheduling.vue';

const testState = vi.hoisted(() => ({
  accountId: null,
  currentAccount: null,
  dealsEnabled: null,
  canManage: null,
  uiFlags: null,
  updateAccount: vi.fn(() => Promise.resolve()),
  useAlert: vi.fn(),
  integrations: vi.fn(() => Promise.resolve({ data: { payload: [] } })),
  loadPipelines: vi.fn(() => Promise.resolve()),
  savePipelineSettings: vi.fn(() => Promise.resolve()),
  pipelines: [],
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: testState.useAlert,
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: testState.currentAccount,
    updateAccount: testState.updateAccount,
  }),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: () => testState.canManage.value,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => {
    if (key === 'accounts/getUIFlags') return testState.uiFlags;
    if (key === 'getCurrentAccountId') return testState.accountId;
    if (key === 'accounts/isFeatureEnabledonAccount') {
      return ref(() => testState.dealsEnabled.value);
    }
    return ref(null);
  },
}));

vi.mock('dashboard/api/integrations', () => ({
  default: { get: testState.integrations },
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    get pipelines() {
      return testState.pipelines;
    },
    loadPipelines: testState.loadPipelines,
    savePipelineSettings: testState.savePipelineSettings,
  }),
}));

const mountScheduling = () =>
  mount(Scheduling, {
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        BaseSettingsHeader: true,
        'woot-loading-state': true,
      },
    },
  });

describe('Scheduling settings page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    testState.accountId = ref(1);
    testState.currentAccount = ref({
      id: 1,
      settings: {
        scheduling_contact_required: true,
        scheduling_company_enabled: false,
      },
    });
    testState.dealsEnabled = ref(true);
    testState.canManage = ref(true);
    testState.uiFlags = ref({ isFetchingItem: false, isUpdating: false });
    testState.pipelines = [
      {
        id: 1,
        name: 'Primary',
        active: true,
        default: true,
        position: 10,
        appointmentAutomation: {
          enabled: false,
          auto_create_deals: false,
          rules: [],
        },
        stages: [
          { id: 11, name: 'Booked', active: true, outcome: 'open', position: 1 },
          { id: 12, name: 'Visited', active: true, outcome: 'won', position: 2 },
        ],
      },
      {
        id: 2,
        name: 'Repeat Clinic',
        active: true,
        default: false,
        position: 20,
        appointmentAutomation: {
          enabled: true,
          auto_create_deals: true,
          auto_create_from_calendar: true,
          rules: [{ stage_id: 21, scope: 'any', conditions: ['scheduled'] }],
        },
        stages: [
          {
            id: 21,
            name: 'Repeat Booked',
            active: true,
            outcome: 'open',
            position: 1,
          },
        ],
      },
    ];
  });

  it('renders CRM appointment automation in Calendar Settings and saves both account and selected pipeline settings', async () => {
    testState.integrations.mockResolvedValueOnce({
      data: { payload: [{ id: 'medelement', hooks: [{ id: 5 }] }] },
    });
    const wrapper = mountScheduling();
    await flushPromises();

    expect(testState.loadPipelines).toHaveBeenCalledWith({
      include_inactive_stages: true,
    });
    const automation = wrapper.findComponent({
      name: 'CrmAppointmentAutomationSettings',
    });
    expect(automation.exists()).toBe(true);
    expect(automation.props('selectedPipelineId')).toBe(2);
    expect(automation.props('medelementInstalled')).toBe(true);

    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(testState.updateAccount).toHaveBeenCalledWith({
      scheduling_contact_required: true,
      scheduling_company_enabled: false,
    });
    expect(testState.savePipelineSettings).toHaveBeenCalledWith(
      2,
      expect.objectContaining({
        appointment_automation: expect.objectContaining({
          enabled: true,
          auto_create_deals: true,
          auto_create_from_calendar: true,
        }),
      })
    );
    expect(testState.useAlert).toHaveBeenCalledWith(
      'GENERAL_SETTINGS.UPDATE.SUCCESS'
    );
  });
});
