import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import CopilotLauncher from './CopilotLauncher.vue';

const testState = vi.hoisted(() => ({
  route: { name: 'dashboard' },
  uiSettings: {
    value: {
      is_copilot_panel_open: false,
    },
  },
  updateUISettings: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => testState.route,
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: testState.uiSettings,
    updateUISettings: testState.updateUISettings,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => {
    const refOf = value => ({ __v_isRef: true, value });
    return {
      getCurrentAccountId: refOf(530),
      'accounts/isFeatureEnabledonAccount': refOf(() => true),
    }[key];
  },
}));

vi.mock('dashboard/featureFlags', () => ({
  FEATURE_FLAGS: { CAPTAIN: 'captain' },
}));

const mountComponent = () =>
  shallowMount(CopilotLauncher, {
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

describe('CopilotLauncher', () => {
  beforeEach(() => {
    testState.route.name = 'dashboard';
    testState.uiSettings.value = { is_copilot_panel_open: false };
    testState.updateUISettings.mockClear();
  });

  it('shows the launcher on non-conversation pages when the copilot panel is closed', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-icon="i-woot-captain"]').exists()).toBe(true);
  });

  it('hides the launcher on regular conversation detail pages', () => {
    testState.route.name = 'conversation_through_inbox';

    const wrapper = mountComponent();

    expect(wrapper.find('[data-icon="i-woot-captain"]').exists()).toBe(false);
  });

  it('hides the launcher on communication thread detail pages', () => {
    testState.route.name = 'communication_thread_conversation';

    const wrapper = mountComponent();

    expect(wrapper.find('[data-icon="i-woot-captain"]').exists()).toBe(false);
  });
});
