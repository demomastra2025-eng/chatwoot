import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';
import enInbox from 'dashboard/i18n/locale/en/inbox.json';
import ruInbox from 'dashboard/i18n/locale/ru/inbox.json';
import kkInbox from 'dashboard/i18n/locale/kk/inbox.json';
import enSettings from 'dashboard/i18n/locale/en/settings.json';
import ruSettings from 'dashboard/i18n/locale/ru/settings.json';
import kkSettings from 'dashboard/i18n/locale/kk/settings.json';

const { mocks } = await vi.hoisted(async () => {
  const { reactive, ref } = await import('vue');
  return {
    mocks: {
      route: reactive({
        name: 'home',
        path: '/app/accounts/1/dashboard',
        params: { accountId: '1' },
        query: {},
      }),
      router: {
        resolve: () => ({ path: '/app/accounts/1/route' }),
        push: vi.fn(),
        replace: vi.fn(),
      },
      uiSettings: ref({}),
      getters: reactive({}),
      dispatch: vi.fn(() => Promise.resolve()),
    },
  };
});

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => mocks.router,
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));
vi.mock('vuex', () => ({
  useStore: () => ({ dispatch: mocks.dispatch, getters: {} }),
}));
vi.mock('dashboard/composables/store', async () => {
  const { computed } = await vi.importActual('vue');
  return {
    useMapGetter: key => computed(() => mocks.getters[key]),
    useStore: () => ({ dispatch: mocks.dispatch, getters: {} }),
  };
});
vi.mock('dashboard/composables/useAccount', async () => {
  const { ref } = await vi.importActual('vue');
  return {
    useAccount: () => ({
      accountScopedRoute: (name, params = {}, query = {}) => ({
        name,
        params: { accountId: 1, ...params },
        query,
      }),
      currentAccount: ref({ id: 1, settings: {} }),
      isOnChatwootCloud: ref(false),
    }),
  };
});
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true, shouldShow: () => true }),
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: mocks.uiSettings,
    updateUISettings: vi.fn(),
  }),
}));
vi.mock('dashboard/composables/utils/useKbd', async () => {
  const { ref } = await vi.importActual('vue');
  return { useKbd: () => ref('Ctrl K') };
});
vi.mock('./useSidebarKeyboardShortcuts', () => ({
  useSidebarKeyboardShortcuts: vi.fn(),
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    pipelines: [],
    loadPipelines: vi.fn(() => Promise.resolve()),
  }),
}));
vi.mock(
  'dashboard/components-next/NewConversation/ComposeConversation.vue',
  () => ({ default: { name: 'ComposeConversation', render: () => null } })
);
vi.mock('dashboard/routes/dashboard/settings/labels/AddLabel.vue', () => ({
  default: { name: 'AddLabelForm', render: () => null },
}));

import Sidebar from './Sidebar.vue';

const setWindowWidth = width => {
  window.innerWidth = width;
  window.dispatchEvent(new Event('resize'));
};

const mountSidebar = () =>
  shallowMount(Sidebar, {
    global: {
      stubs: {
        SidebarPhoneToggle: {
          name: 'SidebarPhoneToggle',
          props: ['isCollapsed'],
          template:
            '<li data-testid="phone-toggle" :data-collapsed="String(isCollapsed)" />',
        },
        SidebarNotificationBell: {
          name: 'SidebarNotificationBell',
          props: ['isCollapsed', 'label'],
          template:
            '<li data-testid="notification-bell" :data-collapsed="String(isCollapsed)" :data-label="label" />',
        },
        SidebarGroup: {
          name: 'SidebarGroup',
          inheritAttrs: false,
          props: ['name'],
          template: '<li data-testid="sidebar-group" :data-name="name" />',
        },
        RouterLink: { template: '<a><slot /></a>' },
        Teleport: true,
        'woot-modal': true,
      },
      directives: { onClickOutside: {} },
    },
  });

const testIdsIn = element =>
  [...element.querySelectorAll('[data-testid]')].map(node =>
    node.getAttribute('data-testid')
  );

describe('Sidebar notifications and phone placement', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    usePhoneWidgetStore().publishSipState({
      available: true,
      status: 'ready',
    });
    Object.assign(mocks.getters, {
      'globalConfig/isACustomBrandedInstance': false,
      getCurrentAccountId: 1,
      getCurrentUser: {
        id: 1,
        accounts: [{ id: 1, role: 'administrator', permissions: [] }],
      },
      'accounts/isFeatureEnabledonAccount': () => false,
      'inboxes/getInboxes': [],
      'labels/getLabelsOnSidebar': [],
      'teams/getMyTeams': [],
      'customViews/getContactCustomViews': [],
      'customViews/getConversationCustomViews': [],
      getConversationSidebarUnreadCounts: {},
      'conversationStats/getStats': {},
      getSelectedChat: null,
    });
    mocks.uiSettings.value = {};
  });

  it('puts the phone button just above the bell in the desktop rail footer', async () => {
    setWindowWidth(1280);
    const wrapper = mountSidebar();
    await flushPromises();

    const footer = wrapper.get('[data-testid="sidebar-rail-footer-actions"]');
    expect(testIdsIn(footer.element)).toEqual([
      'phone-toggle',
      'notification-bell',
    ]);
    // The rail itself no longer links to the notifications page.
    const rail = wrapper.get('nav');
    expect(rail.find('[data-testid="notification-bell"]').exists()).toBe(false);
    expect(rail.find('[data-name="Inbox"]').exists()).toBe(false);
  });

  it('puts the phone button just above the bell in the mobile menu', async () => {
    setWindowWidth(600);
    const wrapper = mountSidebar();
    await flushPromises();

    expect(
      wrapper.find('[data-testid="sidebar-rail-footer-actions"]').exists()
    ).toBe(false);
    const menuIds = testIdsIn(wrapper.get('nav').element);
    const bellIndex = menuIds.indexOf('notification-bell');
    expect(bellIndex).toBeGreaterThan(0);
    expect(menuIds[bellIndex - 1]).toBe('phone-toggle');
    expect(
      wrapper.get('nav [data-testid="phone-toggle"]').attributes()
    ).toMatchObject({ 'data-collapsed': 'false' });
    setWindowWidth(1280);
  });

  it.each([
    ['desktop rail footer', 1280, '[data-testid="sidebar-rail-footer-actions"]'],
    ['mobile menu', 600, 'nav'],
  ])(
    'labels the bell with the notifications panel title in the %s',
    async (_, width, container) => {
      setWindowWidth(width);
      const wrapper = mountSidebar();
      await flushPromises();

      expect(
        wrapper
          .get(`${container} [data-testid="notification-bell"]`)
          .attributes('data-label')
      ).toBe('INBOX.NOTIFICATION_MODAL.TITLE');
      setWindowWidth(1280);
    }
  );

  it.each([
    ['en', enInbox, enSettings, 'Notifications'],
    ['ru', ruInbox, ruSettings, 'Уведомления'],
    ['kk', kkInbox, kkSettings, 'Хабарландырулар'],
  ])(
    'names the bell "Notifications" in %s, also in the navigation settings',
    (_, inbox, settings, expected) => {
      expect(inbox.INBOX.NOTIFICATION_MODAL.TITLE).toBe(expected);
      expect(settings.SIDEBAR.INBOX).toBe(expected);
    }
  );

  it('shows the phone button only to employees with a browser SIP line', async () => {
    setWindowWidth(1280);
    usePhoneWidgetStore().publishSipState({ available: false });
    const wrapper = mountSidebar();
    await flushPromises();

    const footer = wrapper.get('[data-testid="sidebar-rail-footer-actions"]');
    expect(testIdsIn(footer.element)).toEqual(['notification-bell']);

    // The phone widget publishes the line once the SIP bootstrap finishes.
    usePhoneWidgetStore().publishSipState({
      available: true,
      status: 'connecting',
    });
    await flushPromises();
    expect(testIdsIn(footer.element)).toEqual([
      'phone-toggle',
      'notification-bell',
    ]);
  });
});
