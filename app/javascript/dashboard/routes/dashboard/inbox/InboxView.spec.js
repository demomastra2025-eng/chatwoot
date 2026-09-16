import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import InboxView from './InboxView.vue';
import {
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  CONVERSATION_PIPELINES_VISIBILITY_KEY,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const mocks = vi.hoisted(() => ({
  currentChat: { __v_isRef: true, value: { id: 42 } },
  currentAccount: { __v_isRef: true, value: { settings: {} } },
  dispatch: vi.fn(() => Promise.resolve()),
  uiSettings: { __v_isRef: true, value: {} },
  isFeatureEnabledonAccount: {
    __v_isRef: true,
    value: vi.fn(() => true),
  },
}));

vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => ({ params: { accountId: '1', id: '42', inboxId: '7' } }),
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: name => {
    const getters = {
      'notifications/getFilteredNotifications': {
        __v_isRef: true,
        value: () => [],
      },
      getSelectedChat: mocks.currentChat,
      getConversationById: {
        __v_isRef: true,
        value: () => ({ id: 42 }),
      },
      'notifications/getUIFlags': {
        __v_isRef: true,
        value: { isFetching: false },
      },
      'notifications/getMeta': { __v_isRef: true, value: { count: 1 } },
      getCurrentAccountId: { __v_isRef: true, value: 1 },
      'accounts/isFeatureEnabledonAccount': mocks.isFeatureEnabledonAccount,
      getCurrentUser: {
        __v_isRef: true,
        value: {
          accounts: [
            {
              id: 1,
              permissions: ['administrator', 'crm_manage', 'scheduling_manage'],
            },
          ],
        },
      },
    };
    return getters[name];
  },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: mocks.uiSettings }),
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: { __v_isRef: true, value: 1 },
    currentAccount: mocks.currentAccount,
  }),
}));

vi.mock('dashboard/composables', () => ({ useTrack: vi.fn() }));
vi.mock('shared/helpers/mitt', () => ({ emitter: { emit: vi.fn() } }));

describe('InboxView', () => {
  beforeEach(() => {
    mocks.currentChat.value = { id: 42 };
    mocks.currentAccount.value = { settings: {} };
    mocks.isFeatureEnabledonAccount.value = vi.fn(() => true);
    mocks.dispatch.mockClear();
  });

  it.each([
    ['is_crm_deal_panel_open', CONVERSATION_PIPELINES_VISIBILITY_KEY],
    [
      'is_scheduling_appointments_panel_open',
      CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
    ],
  ])(
    'renders the route sidebar for %s when its navigation item is hidden',
    async (setting, hiddenKey) => {
      mocks.currentAccount.value = {
        settings: {
          [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [hiddenKey],
          [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
            SIDEBAR_VISIBILITY_CURRENT_VERSION,
        },
      };
      mocks.uiSettings.value = {
        is_contact_sidebar_open: false,
        is_crm_deal_panel_open: false,
        is_scheduling_appointments_panel_open: false,
        is_touch_sidebar_open: false,
        [setting]: true,
      };

      const wrapper = shallowMount(InboxView, {
        global: {
          mocks: { $t: key => key },
        },
      });
      await wrapper.vm.$nextTick();

      expect(
        wrapper.findComponent({ name: 'ConversationSidebar' }).exists()
      ).toBe(true);
    }
  );
});
