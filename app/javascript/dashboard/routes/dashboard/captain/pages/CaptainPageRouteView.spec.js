import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, beforeEach, vi } from 'vitest';

import CaptainPageRouteView from './CaptainPageRouteView.vue';
import { CAPTAIN_COPILOT_PANEL_CLOSED_SESSION_KEY } from 'dashboard/helper/captainCopilotPanel';

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
    window.sessionStorage.clear();
    mocks.updateUISettings.mockReset();
    mocks.route.params.assistantId = '42';
    mocks.uiSettings.value = {
      is_copilot_panel_open: false,
      last_active_assistant_id: null,
    };
  });

  it('opens the copilot panel by default inside Captain pages', () => {
    mountComponent();

    expect(mocks.updateUISettings).toHaveBeenCalledWith(
      expect.objectContaining({
        is_copilot_panel_open: true,
        is_contact_sidebar_open: false,
        is_crm_deal_panel_open: false,
        is_touch_sidebar_open: false,
      })
    );
  });

  it('does not reopen the copilot panel if it was closed earlier in the session', () => {
    window.sessionStorage.setItem(
      CAPTAIN_COPILOT_PANEL_CLOSED_SESSION_KEY,
      'true'
    );

    mountComponent();

    expect(mocks.updateUISettings).toHaveBeenCalledWith(
      expect.objectContaining({
        last_active_assistant_id: 42,
      })
    );
    expect(mocks.updateUISettings).not.toHaveBeenCalledWith(
      expect.objectContaining({
        is_copilot_panel_open: true,
      })
    );
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
