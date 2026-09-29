import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import campaignsRoutes from 'dashboard/routes/dashboard/campaigns/campaigns.routes';
import Sidebar from './Sidebar.vue';
import SidebarGroup from './SidebarGroup.vue';
import SidebarSecondaryColumn from './SidebarSecondaryColumn.vue';

const ACCOUNT_ID = 1;

const mocks = vi.hoisted(() => ({
  route: null,
  user: null,
  accountSettings: {},
  knownRoutes: new Map(),
  crmStore: {
    pipelines: [],
    ui: { isLoadingPipelines: false },
    loadPipelines: () => Promise.resolve(),
  },
}));

// Outbound routes keep their real paths and access meta, so the secondary
// column decides visibility exactly like the app. Other routes only need a
// stable path per name and params.
const fakePath = (name, params = {}) => {
  const known = mocks.knownRoutes.get(name);
  if (known) return known.path;

  const { accountId, ...otherParams } = params;
  const suffix = Object.values(otherParams).map(String).join('/');
  return `/app/accounts/${accountId ?? ACCOUNT_ID}/${name}${suffix ? `/${suffix}` : ''}`;
};

const router = {
  resolve: to => ({
    path: fakePath(to?.name, to?.params),
    meta: mocks.knownRoutes.get(to?.name)?.meta || {},
  }),
  getRoutes: () => [],
  push: vi.fn(),
  replace: vi.fn(),
};

vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => mocks.route,
  useRouter: () => router,
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => mocks.crmStore,
}));

vi.mock('./useSidebarKeyboardShortcuts', () => ({
  useSidebarKeyboardShortcuts: () => {},
}));

vi.mock('dashboard/composables/utils/useKbd', () => ({
  useKbd: () => ({ value: 'Ctrl K' }),
}));

vi.mock('./SidebarProfileMenu.vue', () => ({
  default: { name: 'SidebarProfileMenu', template: '<div />' },
}));
vi.mock('./SidebarAccountSwitcher.vue', () => ({
  default: { name: 'SidebarAccountSwitcher', template: '<div />' },
}));
vi.mock('./SidebarChangelogCard.vue', () => ({
  default: { name: 'SidebarChangelogCard', template: '<div />' },
}));
vi.mock('./SidebarChangelogButton.vue', () => ({
  default: { name: 'SidebarChangelogButton', template: '<div />' },
}));
vi.mock(
  'dashboard/components-next/NewConversation/ComposeConversation.vue',
  () => ({
    default: {
      name: 'ComposeConversation',
      template: '<div />',
      methods: { toggle: () => {} },
    },
  })
);
vi.mock('dashboard/routes/dashboard/settings/labels/AddLabel.vue', () => ({
  default: { name: 'AddLabel', template: '<div />' },
}));

campaignsRoutes.routes.forEach(parentRoute => {
  (parentRoute.children || []).forEach(childRoute => {
    if (!childRoute.name) return;

    mocks.knownRoutes.set(childRoute.name, {
      path: `${parentRoute.path}/${childRoute.path}`
        .replace(':accountId', String(ACCOUNT_ID))
        .replace(/\/$/, ''),
      meta: childRoute.meta || {},
    });
  });
});

const ADMINISTRATOR = ['administrator'];
const AGENT = ['agent'];
const CRM_SETTINGS_ROLE = [
  'custom_role',
  'conversation_manage',
  'crm_settings_view',
];

const buildStore = () => ({
  getters: {
    getCurrentAccountId: ACCOUNT_ID,
    getCurrentUser: mocks.user,
    'accounts/isFeatureEnabledonAccount': () => true,
    'accounts/getAccount': () => ({
      id: ACCOUNT_ID,
      settings: mocks.accountSettings,
    }),
    'globalConfig/isOnChatwootCloud': false,
    'globalConfig/isACustomBrandedInstance': false,
    'inboxes/getInboxes': [],
    'labels/getLabelsOnSidebar': [],
    'teams/getMyTeams': [],
    'customViews/getContactCustomViews': [],
    'customViews/getConversationCustomViews': [],
    getConversationSidebarUnreadCounts: {},
    'conversationStats/getStats': {},
    getSelectedChat: null,
    getUISettings: {},
    'notifications/getUnreadCount': 0,
  },
  dispatch: vi.fn(() => Promise.resolve()),
});

// Installs the fake store the way Vuex does, for `useStore` from vuex and for
// `$store` in `dashboard/composables/store`.
const storePlugin = store => ({
  install(app) {
    app.provide('store', store);
    app.config.globalProperties.$store = store;
  },
});

const mountSidebar = async ({ permissions, routeName }) => {
  mocks.user = {
    id: 7,
    name: 'Employee',
    accounts: [{ id: ACCOUNT_ID, permissions }],
  };
  mocks.route = {
    name: routeName,
    path: fakePath(routeName, { accountId: ACCOUNT_ID }),
    params: { accountId: String(ACCOUNT_ID) },
    query: {},
  };
  const store = buildStore();

  const wrapper = mount(Sidebar, {
    global: {
      plugins: [storePlugin(store)],
      stubs: {
        teleport: true,
        RouterLink: {
          name: 'RouterLink',
          props: ['to'],
          template: '<a><slot /></a>',
        },
        SidebarGroupLeaf: {
          name: 'SidebarGroupLeaf',
          props: ['name', 'label', 'active'],
          template:
            '<li data-test="sidebar-leaf" :data-name="name" :data-active="active ? \'true\' : \'false\'">{{ label }}</li>',
        },
        SidebarSubGroup: true,
        SidebarAssigneeTabs: true,
      },
    },
  });
  await flushPromises();
  return wrapper;
};

const sidebarGroup = (wrapper, name) =>
  wrapper
    .findAllComponents(SidebarGroup)
    .find(group => group.props('name') === name);

const groupNames = wrapper =>
  wrapper.findAllComponents(SidebarGroup).map(group => group.props('name'));

const navigationChildNames = group =>
  (group.props('children') || [])
    .filter(child => child.type !== 'section')
    .map(child => child.name);

const sectionNames = group =>
  (group.props('children') || [])
    .filter(child => child.type === 'section')
    .map(child => child.name);

const secondaryColumn = wrapper =>
  wrapper.findComponent(SidebarSecondaryColumn);

const renderedLeaves = wrapper =>
  secondaryColumn(wrapper)
    .findAll('[data-test="sidebar-leaf"]')
    .map(leaf => ({
      name: leaf.attributes('data-name'),
      active: leaf.attributes('data-active') === 'true',
    }));

describe('Sidebar', () => {
  beforeEach(() => {
    mocks.accountSettings = {};
    mocks.crmStore.pipelines = [];
  });

  describe('for an administrator', () => {
    it('shows the whole sectioned settings hub', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'general_settings_index',
      });
      const settings = sidebarGroup(wrapper, 'Settings');

      expect(settings.props('defaultChildName')).toBe('Workspace');
      expect(sectionNames(settings)).toEqual([
        'Settings Section Company',
        'Settings Section Conversations',
        'Settings Section Channels',
        'Settings Section Automation',
        'Settings Section Team',
        'Settings Section Data',
        'Settings Section AI',
      ]);
      // SLA needs a Cloud or Enterprise installation, which this suite is not.
      expect(navigationChildNames(settings)).toEqual([
        'Workspace',
        'Navigation',
        'Settings Billing',
        'Conversation Settings',
        'Conversation Navigation',
        'Conversation Closure',
        'Settings Quick Replies',
        'Settings Macros',
        'Channels',
        'Settings WhatsApp Templates',
        'Lead Forms',
        'Settings Integrations',
        'Settings Agent Bots',
        'Settings Automation',
        'Employees',
        'Teams',
        'Roles',
        'Policies',
        'Audit Logs',
        'Additional Fields',
        'Tags',
        'Settings Captain',
      ]);
      expect(secondaryColumn(wrapper).props('label')).toBe(
        settings.props('label')
      );
      expect(renderedLeaves(wrapper).filter(leaf => leaf.active)).toEqual([
        { name: 'Workspace', active: true },
      ]);
    });

    it('keeps quick replies and WhatsApp templates in the hub instead of Outbound', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'outbound_whatsapp_templates_index',
      });

      expect(navigationChildNames(sidebarGroup(wrapper, 'Campaigns'))).toEqual([
        'Touches',
        'Mass broadcasts',
      ]);
      expect(secondaryColumn(wrapper).props('label')).toBe(
        sidebarGroup(wrapper, 'Settings').props('label')
      );
      expect(renderedLeaves(wrapper).filter(leaf => leaf.active)).toEqual([
        { name: 'Settings WhatsApp Templates', active: true },
      ]);
    });

    it('replaces the Contacts gear with the hub', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'contacts_dashboard_index',
      });
      const contacts = sidebarGroup(wrapper, 'Contacts');

      expect(contacts.props('actionIcon')).toBe('');
      expect(contacts.props('actionTo')).toBe('');
    });
  });

  describe('for an agent', () => {
    it('has no settings hub and keeps both template pages under Outbound', async () => {
      const wrapper = await mountSidebar({
        permissions: AGENT,
        routeName: 'outbound_templates_index',
      });

      expect(groupNames(wrapper)).not.toContain('Settings');
      expect(navigationChildNames(sidebarGroup(wrapper, 'Campaigns'))).toEqual([
        'Touches',
        'Templates',
        'WhatsApp Templates',
      ]);
      expect(renderedLeaves(wrapper)).toEqual([
        { name: 'Touches', active: false },
        { name: 'Templates', active: true },
        { name: 'WhatsApp Templates', active: false },
      ]);
    });

    it('opens WhatsApp templates from Outbound', async () => {
      const wrapper = await mountSidebar({
        permissions: AGENT,
        routeName: 'outbound_whatsapp_templates_index',
      });
      const whatsAppTemplates = sidebarGroup(wrapper, 'Campaigns')
        .props('children')
        .find(child => child.name === 'WhatsApp Templates');

      expect(whatsAppTemplates.to).toEqual({
        name: 'outbound_whatsapp_templates_index',
        params: { accountId: ACCOUNT_ID },
        query: {},
      });
      expect(secondaryColumn(wrapper).props('label')).toBe(
        sidebarGroup(wrapper, 'Campaigns').props('label')
      );
      expect(renderedLeaves(wrapper)).toEqual([
        { name: 'Touches', active: false },
        { name: 'Templates', active: false },
        { name: 'WhatsApp Templates', active: true },
      ]);
    });

    it('keeps the tag settings shortcut next to Contacts', async () => {
      const wrapper = await mountSidebar({
        permissions: AGENT,
        routeName: 'contacts_dashboard_index',
      });
      const contacts = sidebarGroup(wrapper, 'Contacts');

      expect(contacts.props('actionIcon')).toBe('i-lucide-settings-2');
      expect(contacts.props('actionTo')).toMatchObject({ name: 'labels_list' });
    });
  });

  describe('for a custom role with CRM settings access', () => {
    it('shows only the additional fields in the settings hub', async () => {
      const wrapper = await mountSidebar({
        permissions: CRM_SETTINGS_ROLE,
        routeName: 'workspace_additional_fields_settings_index',
      });
      const settings = sidebarGroup(wrapper, 'Settings');

      expect(settings.props('defaultChildName')).toBe('Additional Fields');
      expect(sectionNames(settings)).toEqual(['Settings Section Data']);
      expect(navigationChildNames(settings)).toEqual(['Additional Fields']);
      expect(renderedLeaves(wrapper)).toEqual([
        { name: 'Additional Fields', active: true },
      ]);
    });

    it('keeps both template pages under Outbound and the Contacts gear', async () => {
      const wrapper = await mountSidebar({
        permissions: CRM_SETTINGS_ROLE,
        routeName: 'outbound_whatsapp_templates_index',
      });

      expect(navigationChildNames(sidebarGroup(wrapper, 'Campaigns'))).toEqual([
        'Touches',
        'Templates',
        'WhatsApp Templates',
      ]);
      expect(renderedLeaves(wrapper)).toEqual([
        { name: 'Touches', active: false },
        { name: 'Templates', active: false },
        { name: 'WhatsApp Templates', active: true },
      ]);
      expect(sidebarGroup(wrapper, 'Contacts').props('actionIcon')).toBe(
        'i-lucide-settings-2'
      );
    });
  });
});
