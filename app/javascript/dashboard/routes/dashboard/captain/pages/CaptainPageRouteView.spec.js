import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, beforeEach, vi } from 'vitest';

import CaptainPageRouteView from './CaptainPageRouteView.vue';

const mocks = vi.hoisted(() => ({
  route: {
    params: {
      assistantId: '42',
    },
  },
  uiSettings: {
    value: {
      last_active_assistant_id: null,
    },
  },
  updateUISettings: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: mocks.uiSettings,
    updateUISettings: mocks.updateUISettings,
  }),
}));

const mountComponent = () =>
  shallowMount(CaptainPageRouteView, {
    global: {
      stubs: {
        RouterView: true,
      },
    },
  });

describe('CaptainPageRouteView', () => {
  beforeEach(() => {
    mocks.updateUISettings.mockReset();
    mocks.route.params.assistantId = '42';
    mocks.uiSettings.value = {
      last_active_assistant_id: null,
    };
  });

  it('stores the last active assistant id from Captain routes', () => {
    mountComponent();

    expect(mocks.updateUISettings).toHaveBeenCalledWith({
      last_active_assistant_id: 42,
    });
  });
});
