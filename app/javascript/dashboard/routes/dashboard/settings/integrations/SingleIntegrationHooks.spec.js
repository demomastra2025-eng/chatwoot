import { flushPromises, shallowMount } from '@vue/test-utils';
import { computed, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const testState = vi.hoisted(() => ({
  alerts: vi.fn(),
  dispatch: vi.fn(),
  integration: null,
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
    testState.dispatch.mockImplementation(action => {
      if (action === 'integrations/getHookSyncStatus')
        return Promise.resolve(syncStatus);
      if (action === 'integrations/runHookSync') {
        return Promise.resolve({ message: 'queued', sync_status: syncStatus });
      }
      if (action === 'integrations/updateHookSyncConflict')
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
});
