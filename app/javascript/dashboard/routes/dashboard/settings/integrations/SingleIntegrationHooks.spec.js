import { flushPromises, shallowMount } from '@vue/test-utils';
import { computed, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const testState = vi.hoisted(() => ({
  alerts: vi.fn(),
  dispatch: vi.fn(),
  integration: null,
  syncStatus: null,
}));

vi.mock('vuex', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    useStore: () => ({
      dispatch: testState.dispatch,
      getters: { 'integrations/getUIFlags': {} },
    }),
  };
});

vi.mock('vue-router', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    useRoute: () => ({ params: { accountId: 1 } }),
  };
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: ref('en') }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: message => testState.alerts(message),
}));

vi.mock('dashboard/composables/useIntegrationHook', () => ({
  useIntegrationHook: () => ({
    integration: computed(() => testState.integration),
    hasConnectedHooks: computed(() =>
      Boolean(testState.integration?.hooks?.length)
    ),
  }),
}));

vi.mock('shared/composables/useBranding', () => ({
  useBranding: () => ({ replaceInstallationName: value => value }),
}));

vi.mock('shared/helpers/clipboard', () => ({
  copyTextToClipboard: vi.fn(),
}));

vi.mock(
  'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue',
  () => ({
    default: { template: '<header><slot name="actions" /></header>' },
  })
);

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: {
    props: ['label', 'disabled', 'isLoading'],
    emits: ['click'],
    template:
      '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
  },
}));

import SingleIntegrationHooks from './SingleIntegrationHooks.vue';

const syncStatus = {
  run: {
    id: 12,
    status: 'partial',
    phase_results: { services: { status: 'succeeded', imported_count: 3 } },
    created_at: '2026-08-07T12:00:00Z',
  },
  conflicts: [
    {
      id: 8,
      phase: 'services',
      conflict_type: 'invalid_service',
      status: 'open',
      occurrences: 2,
      details: { reason: 'Internal provider reason must not render' },
    },
  ],
  conflict_counts: { open: 1, ignored: 0 },
};

const mountComponent = () =>
  shallowMount(SingleIntegrationHooks, {
    props: { integrationId: 'medelement' },
    global: {
      mocks: { $t: key => key },
      stubs: {
        BaseSettingsHeader: {
          template: '<header><slot name="actions" /></header>',
        },
        NextButton: {
          props: ['label', 'disabled', 'isLoading'],
          emits: ['click'],
          template:
            '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
        },
        Dialog: {
          emits: ['confirm', 'close'],
          methods: { open() {}, close() {} },
          template:
            '<div><slot /><button data-test="dialog-confirm" @click="$emit(\'confirm\')">confirm</button></div>',
        },
        Input: true,
      },
    },
  });

const buttonByLabel = (wrapper, label) =>
  wrapper.findAll('button').find(button => button.text() === label);

describe('SingleIntegrationHooks MedElement synchronization', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    testState.alerts.mockReset();
    testState.dispatch.mockReset();
    testState.integration = {
      id: 'medelement',
      name: 'MedElement',
      hooks: [{ id: 7, status: true, settings: {}, metadata: {} }],
      visible_properties: [],
      settings_form_schema: [],
    };
    testState.syncStatus = syncStatus;
    testState.dispatch.mockImplementation(action => {
      if (action === 'integrations/getHookSyncStatus')
        return Promise.resolve(testState.syncStatus);
      if (action === 'integrations/runHookSync') {
        return Promise.resolve({ message: 'queued', sync_status: syncStatus });
      }
      if (action === 'integrations/updateHookSyncConflict')
        return Promise.resolve(syncStatus);
      if (action === 'integrations/resolveHookSyncConflict')
        return Promise.resolve(syncStatus);
      return Promise.reject(new Error(`Unexpected action: ${action}`));
    });
  });

  it('renders persisted phase and conflict state without exposing internal reason text', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.PARTIAL'
    );
    expect(wrapper.text()).toContain(
      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.INVALID_SERVICE'
    );
    expect(wrapper.text()).toContain(
      'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.IMPORTED_COUNT'
    );
    expect(wrapper.text()).not.toContain(
      'Internal provider reason must not render'
    );

    wrapper.unmount();
  });

  it('always renders the conflict queue for a connected MedElement integration', async () => {
    testState.syncStatus = {
      run: null,
      conflicts: [],
      conflict_counts: { open: 0, ignored: 0, resolved: 0 },
      conflict_pagination: { page: 1, per_page: 25, total: 0, total_pages: 1 },
    };

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.CONFLICTS'
    );
    expect(wrapper.text()).toContain(
      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.EMPTY'
    );

    wrapper.unmount();
  });

  it('queues an exact conflict phase retry and submits administrator decisions', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    testState.dispatch.mockClear();

    await buttonByLabel(
      wrapper,
      'INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.RETRY_PHASE'
    ).trigger('click');
    await flushPromises();
    expect(testState.dispatch).toHaveBeenCalledWith(
      'integrations/runHookSync',
      {
        hookId: 7,
        phases: ['services'],
      }
    );

    await buttonByLabel(
      wrapper,
      'INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.IGNORE'
    ).trigger('click');
    await flushPromises();
    expect(testState.dispatch).toHaveBeenCalledWith(
      'integrations/updateHookSyncConflict',
      { hookId: 7, conflictId: 8, resolution: 'ignore' }
    );

    wrapper.unmount();
  });

  it('renders both contact cards and submits a scoped merge decision', async () => {
    testState.syncStatus = {
      ...syncStatus,
      conflicts: [
        {
          id: 19,
          phase: 'contacts',
          conflict_type: 'phone_owned_by_another_contact',
          status: 'open',
          occurrences: 3,
          contact_resolution: {
            can_merge: true,
            can_delete_primary: false,
            can_delete_conflicting: false,
            primary_contact: {
              id: 101,
              name: 'MedElement patient',
              phone_number: null,
              conversations_count: 0,
              appointments_count: 1,
              deals_count: 0,
              call_sessions_count: 0,
            },
            conflicting_contact: {
              id: 202,
              name: 'Phone owner',
              phone_number: '+77000000000',
              conversations_count: 1,
              appointments_count: 0,
              deals_count: 1,
              call_sessions_count: 1,
            },
          },
        },
      ],
    };
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('MedElement patient');
    expect(wrapper.text()).toContain('Phone owner');
    await buttonByLabel(
      wrapper,
      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.MERGE'
    ).trigger('click');
    await wrapper.get('[data-test="dialog-confirm"]').trigger('click');
    await flushPromises();

    expect(testState.dispatch).toHaveBeenCalledWith(
      'integrations/resolveHookSyncConflict',
      {
        hookId: 7,
        conflictId: 19,
        resolution: 'merge',
        base_contact_id: 101,
        mergee_contact_id: 202,
      }
    );

    wrapper.unmount();
  });

  it('renders specialist and appointment conflict cards without exposing raw reasons', async () => {
    testState.syncStatus = {
      ...syncStatus,
      conflicts: [
        {
          id: 31,
          phase: 'specialists',
          conflict_type: 'invalid_specialist',
          status: 'open',
          occurrences: 1,
          details: { reason: 'raw specialist reason' },
          entity_context: {
            kind: 'specialist',
            specialist_code: 'specialist-1',
            specialty: 'Cardiology',
            resource: { id: 41, name: 'Doctor One', active: true },
          },
        },
        {
          id: 32,
          phase: 'receptions',
          conflict_type: 'appointment_amount_mismatch',
          status: 'open',
          occurrences: 1,
          details: { reason: 'raw appointment reason' },
          entity_context: {
            kind: 'appointment',
            reception_code: 'reception-1',
            starts_at: '2026-08-12T10:00:00Z',
            specialist_code: 'specialist-1',
            local_amount: 1000,
            provider_amount: 1200,
            appointment: {
              id: 51,
              client_name: 'Patient One',
              resource_name: 'Doctor One',
              service_name: 'Consultation',
              status: 'scheduled',
              payment_status: 'awaiting_payment',
            },
          },
        },
      ],
    };

    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper.get('[data-test="specialist-conflict-card"]').text()
    ).toContain('Doctor One');
    expect(
      wrapper.get('[data-test="appointment-conflict-card"]').text()
    ).toContain('Patient One');
    expect(wrapper.text()).toContain('Consultation');
    expect(wrapper.text()).not.toContain('raw specialist reason');
    expect(wrapper.text()).not.toContain('raw appointment reason');

    wrapper.unmount();
  });
});
