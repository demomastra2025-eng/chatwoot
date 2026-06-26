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
      is_copilot_panel_open: false,
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
      is_copilot_panel_open: false,
      last_active_assistant_id: null,
    };
  });

  it('stores the last active assistant id from Captain routes', () => {
    mountComponent();

    expect(mocks.updateUISettings).toHaveBeenCalledWith({
      last_active_assistant_id: 42,
    });
  });

  it('does not open the copilot panel by default inside Captain pages', () => {
    mocks.uiSettings.value = {
      is_copilot_panel_open: false,
      last_active_assistant_id: 42,
    };

    mountComponent();

    expect(mocks.updateUISettings).not.toHaveBeenCalled();
  });

  it('keeps the copilot panel open when leaving Captain pages', () => {
    mocks.uiSettings.value = {
      is_copilot_panel_open: true,
      last_active_assistant_id: 42,
    };

    const wrapper = mountComponent();
    mocks.updateUISettings.mockClear();
    wrapper.unmount();

    expect(mocks.updateUISettings).not.toHaveBeenCalled();
  });
});
