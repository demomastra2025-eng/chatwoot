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

  it('does not rewrite UI settings when the assistant is already the last active one', () => {
    mocks.uiSettings.value = {
      last_active_assistant_id: 42,
    };

    mountComponent();

    expect(mocks.updateUISettings).not.toHaveBeenCalled();
  });

  it('does not touch UI settings when leaving Captain pages', () => {
    mocks.uiSettings.value = {
      last_active_assistant_id: 42,
    };

    const wrapper = mountComponent();
    mocks.updateUISettings.mockClear();
    wrapper.unmount();

    expect(mocks.updateUISettings).not.toHaveBeenCalled();
  });
});
