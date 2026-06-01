import { mount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import CopilotContainer from './CopilotContainer.vue';

const testState = vi.hoisted(() => {
  const listeners = new WeakMap();
  const onClickOutsideDirective = {
    mounted(el, binding) {
      const listener = event => {
        const [handler, options = {}] = Array.isArray(binding.value)
          ? binding.value
          : [binding.value, {}];

        if (el.contains(event.target)) return;
        if (
          options.ignore?.some(selector => event.target.closest?.(selector))
        ) {
          return;
        }

        handler(event);
      };

      listeners.set(el, listener);
      document.addEventListener('click', listener);
    },
    unmounted(el) {
      document.removeEventListener('click', listeners.get(el));
      listeners.delete(el);
    },
  };

  return {
    updateUISettings: vi.fn(),
    storeDispatch: vi.fn(() => Promise.resolve({ id: 7 })),
    windowWidth: { value: 480 },
    uiSettings: {
      value: {
        is_copilot_panel_open: true,
        preferred_captain_assistant_id: null,
      },
    },
    route: { name: 'home', path: '/app/accounts/1/dashboard', query: {} },
    onClickOutsideDirective,
  };
});

vi.mock('@vueuse/components', async importOriginal => ({
  ...(await importOriginal()),
  vOnClickOutside: testState.onClickOutsideDirective,
}));

vi.mock('@vueuse/core', async importOriginal => ({
  ...(await importOriginal()),
  useEventListener: () => {},
  useWindowSize: () => ({ width: testState.windowWidth }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    getters: {
      'copilotMessages/getMessagesByThreadId': () => [],
      'copilotThreads/getRecord': () => null,
    },
    dispatch: testState.storeDispatch,
  }),
  useMapGetter: key => {
    const refOf = value => ({ __v_isRef: true, value });

    return {
      'captainAssistants/getRecords': refOf([{ id: 1 }]),
      'captainAssistants/getUIFlags': refOf({ fetchingList: false }),
      getCopilotAssistant: refOf(null),
      getSelectedChat: refOf({ id: 42 }),
      getCurrentAccountId: refOf(1),
      'accounts/isFeatureEnabledonAccount': refOf(() => true),
    }[key];
  },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: testState.uiSettings,
    updateUISettings: testState.updateUISettings,
  }),
}));

vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({ isEnterprise: true }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => testState.route,
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('dashboard/featureFlags', () => ({
  FEATURE_FLAGS: { CAPTAIN: 'captain' },
}));

vi.mock('dashboard/helper/captainUiActions', () => ({
  executeCaptainUiAction: vi.fn(),
}));

vi.mock('dashboard/constants/globals', () => ({
  default: { SMALL_SCREEN_BREAKPOINT: 768 },
}));

const mountComponent = () =>
  mount(CopilotContainer, {
    props: { conversationInboxType: 'Channel::WebWidget' },
    attachTo: document.body,
    global: {
      stubs: {
        Copilot: true,
      },
    },
  });

describe('CopilotContainer', () => {
  beforeEach(() => {
    testState.updateUISettings.mockClear();
    testState.storeDispatch.mockClear();
    testState.windowWidth.value = 480;
    testState.uiSettings.value = {
      is_copilot_panel_open: true,
      preferred_captain_assistant_id: null,
    };
    testState.route.name = 'home';
    testState.route.path = '/app/accounts/1/dashboard';
    testState.route.query = {};
  });

  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('does not close the small-screen panel when clicking inside the centered copilot modal', () => {
    const wrapper = mountComponent();
    testState.updateUISettings.mockClear();

    const modal = document.createElement('div');
    modal.setAttribute('data-copilot-modal', '');
    document.body.appendChild(modal);

    modal.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(testState.updateUISettings).not.toHaveBeenCalledWith(
      expect.objectContaining({ is_copilot_panel_open: false })
    );

    const outside = document.createElement('button');
    document.body.appendChild(outside);
    outside.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(testState.updateUISettings).toHaveBeenCalledWith({
      is_contact_sidebar_open: false,
      is_copilot_panel_open: false,
      is_crm_deal_panel_open: false,
      is_touch_sidebar_open: false,
    });

    wrapper.unmount();
  });

  it('opens the copilot panel automatically on Captain settings routes', () => {
    testState.uiSettings.value = {
      is_copilot_panel_open: false,
      preferred_captain_assistant_id: null,
    };
    testState.route.name = 'captain_settings_index';
    testState.route.path = '/app/accounts/1/settings/captain';

    const wrapper = mountComponent();

    expect(testState.updateUISettings).toHaveBeenCalledWith({
      is_contact_sidebar_open: false,
      is_copilot_panel_open: true,
      is_crm_deal_panel_open: false,
      is_touch_sidebar_open: false,
    });

    wrapper.unmount();
  });
});
