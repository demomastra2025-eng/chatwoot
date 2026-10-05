import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import campaignsRoutes from 'dashboard/routes/dashboard/campaigns/campaigns.routes';
import enSettings from 'dashboard/i18n/locale/en/settings.json';
import Sidebar from './Sidebar.vue';
import SidebarGroup from './SidebarGroup.vue';
import SidebarSecondaryColumn from './SidebarSecondaryColumn.vue';

const ACCOUNT_ID = 1;

const mocks = vi.hoisted(() => ({
  route: null,
  user: null,
  accountSettings: {},
  sidebarUnreadCounts: {},
  labels: [],
  teams: [],
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
    'labels/getLabelsOnSidebar': mocks.labels,
    'teams/getMyTeams': mocks.teams,
    'customViews/getContactCustomViews': [],
    'customViews/getConversationCustomViews': [],
    getConversationSidebarUnreadCounts: mocks.sidebarUnreadCounts,
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
        // Covered by Sidebar.notifications.spec.js.
        SidebarNotificationBell: true,
        SidebarPhoneToggle: true,
        NotificationPanel: true,
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
    // The rail footer reads the phone widget store (notifications track).
    setActivePinia(createPinia());
    mocks.accountSettings = {};
    mocks.sidebarUnreadCounts = {};
    mocks.labels = [];
    mocks.teams = [];
    mocks.crmStore.pipelines = [];
  });

  const conversationChild = (wrapper, name) =>
    sidebarGroup(wrapper, 'Conversation')
      .props('children')
      .find(child => child.name === name);

  describe('icons', () => {
    it('uses the aset/dev icons for deals and the navigation settings', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'general_settings_index',
      });
      const settingsChild = name =>
        sidebarGroup(wrapper, 'Settings')
          .props('children')
          .find(child => child.name === name);

      expect(sidebarGroup(wrapper, 'CRM').props('icon')).toBe(
        'i-lucide-briefcase-business'
      );
      expect(settingsChild('Navigation').icon).toBe('i-lucide-eye');
      expect(settingsChild('Conversation Navigation').icon).toBe(
        'i-lucide-panel-left'
      );
    });
  });

  describe('AI group', () => {
    it('is labelled «AI Агенты» and lists the AI pages without icons', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'captain_usage_index',
      });
      const captain = sidebarGroup(wrapper, 'Captain');

      expect(captain.props('label')).toBe(enSettings.SIDEBAR.CAPTAIN);
      expect(captain.props('label')).not.toBe('AI');
      expect(navigationChildNames(captain)).toEqual([
        'Profile',
        'Prompts',
        'Sandbox',
        'Follow-up scenarios',
        'Tools',
        'Observability',
        'Knowledge Base',
        'AI expenses',
      ]);
      captain
        .props('children')
        .forEach(child => expect(child.icon).toBeUndefined());
      const children = captain.props('children');
      expect(children.find(child => child.name === 'Sandbox').to).toMatchObject(
        {
          name: 'captain_assistants_index',
          params: { navigationPath: 'captain_assistants_playground_index' },
        }
      );
      expect(
        children.find(child => child.name === 'AI expenses').to
      ).toMatchObject({ name: 'captain_usage_index' });
      expect(renderedLeaves(wrapper).filter(leaf => leaf.active)).toEqual([
        { name: 'AI expenses', active: true },
      ]);
      // The AI settings page stays in the settings hub.
      expect(navigationChildNames(sidebarGroup(wrapper, 'Settings'))).toContain(
        'Settings Captain'
      );
    });

    it('highlights only «Площадка» while the sandbox page is open', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'captain_assistants_playground_index',
      });

      expect(renderedLeaves(wrapper).filter(leaf => leaf.active)).toEqual([
        { name: 'Sandbox', active: true },
      ]);
    });

    it('hides «Расходы» from employees', async () => {
      const wrapper = await mountSidebar({
        permissions: AGENT,
        routeName: 'contacts_dashboard_index',
      });

      expect(navigationChildNames(sidebarGroup(wrapper, 'Captain'))).toEqual([
        'Profile',
        'Prompts',
        'Sandbox',
        'Follow-up scenarios',
        'Tools',
        'Observability',
        'Knowledge Base',
      ]);
    });
  });

  describe('tags in the sidebar', () => {
    const markerClass = child => child.icon.props.class;

    it('shows tags without counters and with small markers, teams keep badges', async () => {
      mocks.labels = [
        { id: 1, title: 'vip', color: '#ff0000' },
        {
          id: 2,
          title: 'urgent',
          color: '#00ff00',
          marker_type: 'emoji',
          emoji: '🔥',
        },
      ];
      mocks.sidebarUnreadCounts = {
        labels: { vip: 4, urgent: 2 },
        teams: { 5: 3 },
      };
      mocks.teams = [{ id: 5, name: 'Sales' }];
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'communication_threads_dashboard',
      });
      const tags = conversationChild(wrapper, 'Labels');

      expect(tags.hideTopSeparator).toBe(true);
      tags.children.forEach(tag => {
        expect(tag.badge).toBeUndefined();
        expect(tag.count).toBeUndefined();
        expect(tag.iconClass).toBeUndefined();
        expect(tag.compactIconGap).toBeUndefined();
      });
      const classes = tags.children.map(markerClass);
      expect(classes).toEqual([
        'size-2.5 rounded-sm',
        'inline-flex size-[14px] items-center justify-center overflow-hidden text-sm leading-none',
      ]);
      const [team] = conversationChild(wrapper, 'Teams').children;
      expect(team.badge).toBe(3);
      expect(classes.join(' ')).not.toContain('text-xl');
      expect(classes.join(' ')).not.toContain('size-3');
    });

    it('uses the same small markers under Contacts', async () => {
      mocks.labels = [{ id: 1, title: 'vip', color: '#ff0000' }];
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'contacts_dashboard_index',
      });
      const taggedWith = sidebarGroup(wrapper, 'Contacts')
        .props('children')
        .find(child => child.name === 'Tagged With');

      expect(taggedWith.children.map(markerClass)).toEqual([
        'size-2.5 rounded-sm',
      ]);
      expect(taggedWith.children[0].badge).toBeUndefined();
    });
  });

  describe('conversation business sections', () => {
    it('shows pipelines as plain labels without counters', async () => {
      mocks.crmStore.pipelines = [
        {
          id: 1,
          name: 'Main pipeline',
          default: true,
          active: true,
          position: 1,
          dialog_deal_count: 12,
          stages: [
            {
              id: 11,
              name: 'New',
              active: true,
              position: 1,
              color: '#f00',
              dialog_deal_count: 0,
            },
            {
              id: 12,
              name: 'Won',
              active: true,
              position: 2,
              dialog_deal_count: 4,
            },
          ],
        },
      ];
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'communication_threads_dashboard',
      });
      const pipeline = conversationChild(wrapper, 'Pipeline:1');

      expect(pipeline.label).toBe('Main pipeline');
      expect(pipeline.to).toBeUndefined();
      expect(pipeline.count).toBeUndefined();
      expect(pipeline.active).toBeUndefined();
      expect(pipeline.children.map(stage => stage.name)).toEqual([
        'PipelineStage:1:11',
        'PipelineStage:1:12',
      ]);
      pipeline.children.forEach(stage => {
        expect(stage.count).toBeUndefined();
        expect(stage.badge).toBeUndefined();
      });
      expect(pipeline.children[0].to.query).toMatchObject({
        crm_pipeline_id: 1,
        crm_stage_id: 11,
      });
    });

    it('shows «Записи» as a plain label and keeps the status counters', async () => {
      mocks.sidebarUnreadCounts = {
        appointment_statuses: { any: 9, scheduled: 3, confirmed: 2 },
      };
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'communication_threads_dashboard',
      });
      const appointments = conversationChild(wrapper, 'AppointmentStatuses');

      expect(appointments.to).toBeUndefined();
      expect(appointments.count).toBeUndefined();
      expect(appointments.active).toBeUndefined();
      expect(
        Object.fromEntries(
          appointments.children.map(child => [child.name, child.count])
        )
      ).toMatchObject({
        'AppointmentStatus:scheduled': 3,
        'AppointmentStatus:confirmed': 2,
      });
      expect(appointments.children[0].to.query).toMatchObject({
        appointment_status: 'scheduled',
      });
    });
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
        'Settings Reminders',
        'Employees',
        'Teams',
        'Roles',
        'Policies',
        'Audit Logs',
        'Storage',
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

    it('keeps quick replies and WhatsApp templates only in the hub', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'outbound_whatsapp_templates_index',
      });

      expect(groupNames(wrapper)).not.toContain('Campaigns');
      expect(secondaryColumn(wrapper).props('label')).toBe(
        sidebarGroup(wrapper, 'Settings').props('label')
      );
      expect(renderedLeaves(wrapper).filter(leaf => leaf.active)).toEqual([
        { name: 'Settings WhatsApp Templates', active: true },
      ]);
    });

    it('shows broadcasts as one top-level item without a secondary column', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'outbound_broadcasts_index',
      });
      const broadcasts = sidebarGroup(wrapper, 'Mass broadcasts');

      expect(groupNames(wrapper)).not.toContain('Campaigns');
      expect(broadcasts.props('label')).toBe(
        enSettings.SIDEBAR.MASS_BROADCASTS
      );
      expect(broadcasts.props('icon')).toBe('i-lucide-megaphone');
      expect(broadcasts.props('children') || []).toEqual([]);
      expect(broadcasts.props('to')).toMatchObject({
        name: 'outbound_broadcasts_index',
      });
      expect(secondaryColumn(wrapper).exists()).toBe(false);
    });

    it('opens the reminders list (former touches) from the settings hub', async () => {
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'outbound_touches_index',
      });
      const reminders = sidebarGroup(wrapper, 'Settings')
        .props('children')
        .find(child => child.name === 'Settings Reminders');

      expect(reminders.label).toBe(enSettings.SIDEBAR.TOUCHES);
      expect(reminders.to).toMatchObject({ name: 'outbound_touches_index' });
      expect(secondaryColumn(wrapper).props('label')).toBe(
        sidebarGroup(wrapper, 'Settings').props('label')
      );
      expect(renderedLeaves(wrapper).filter(leaf => leaf.active)).toEqual([
        { name: 'Settings Reminders', active: true },
      ]);
    });

    it('has no status group in the conversation navigation', async () => {
      // Saved settings that show every list: before version 21 they showed
      // the status group (AI, Открыто, Отложено, Закрыто).
      mocks.accountSettings = {
        dashboard_sidebar_hidden_items: [],
        dashboard_sidebar_hidden_items_version: 20,
      };
      const wrapper = await mountSidebar({
        permissions: ADMINISTRATOR,
        routeName: 'communication_threads_dashboard',
      });

      expect(
        navigationChildNames(sidebarGroup(wrapper, 'Conversation'))
      ).not.toContain('Statuses');
      expect(
        navigationChildNames(sidebarGroup(wrapper, 'Conversation'))
      ).toEqual(
        expect.arrayContaining(['Assignee:all', 'AppointmentStatuses', 'Teams'])
      );
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
    it('has no settings hub and no outbound entry', async () => {
      const wrapper = await mountSidebar({
        permissions: AGENT,
        routeName: 'outbound_templates_index',
      });

      expect(groupNames(wrapper)).not.toContain('Settings');
      expect(groupNames(wrapper)).not.toContain('Campaigns');
      expect(groupNames(wrapper)).not.toContain('Mass broadcasts');
    });

    it('opens a template page by its link without an outbound column', async () => {
      const wrapper = await mountSidebar({
        permissions: AGENT,
        routeName: 'outbound_whatsapp_templates_index',
      });

      expect(groupNames(wrapper)).not.toContain('Campaigns');
      expect(secondaryColumn(wrapper).exists()).toBe(false);
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

    it('has no outbound entry and keeps the Contacts gear', async () => {
      const wrapper = await mountSidebar({
        permissions: CRM_SETTINGS_ROLE,
        routeName: 'outbound_whatsapp_templates_index',
      });

      expect(groupNames(wrapper)).not.toContain('Campaigns');
      expect(groupNames(wrapper)).not.toContain('Mass broadcasts');
      expect(navigationChildNames(sidebarGroup(wrapper, 'Settings'))).toEqual([
        'Additional Fields',
      ]);
      expect(sidebarGroup(wrapper, 'Contacts').props('actionIcon')).toBe(
        'i-lucide-settings-2'
      );
    });
  });
});
