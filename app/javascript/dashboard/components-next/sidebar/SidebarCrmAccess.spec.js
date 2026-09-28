import { h, ref } from 'vue';
import { mount } from '@vue/test-utils';
import { vi } from 'vitest';
import { routeIsAccessibleFor } from 'dashboard/helper/routeHelpers';
import { routes as crmRoutes } from 'dashboard/routes/dashboard/crm/routes';
import SidebarGroup from './SidebarGroup.vue';
import { provideSidebarContext } from './provider';

const { currentUser, featureEnabled, push } = vi.hoisted(() => ({
  currentUser: { value: null },
  featureEnabled: { value: true },
  push: vi.fn(),
}));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => {
    if (key === 'getCurrentUser') return currentUser;
    if (key === 'accounts/isFeatureEnabledonAccount')
      return { value: () => featureEnabled.value };
    return { value: false };
  },
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId: { value: 2 } }),
}));
vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({ isEnterprise: true, enterprisePlanName: 'Enterprise' }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'home', path: '/', params: {}, query: {} }),
  useRouter: () => ({
    push,
    getRoutes: () => crmRoutes,
    resolve: to => ({
      ...to,
      meta: crmRoutes.find(r => r.name === to.name)?.meta,
    }),
  }),
}));

const account = (mode, permissions, scopes, capabilities) => ({
  id: 2,
  status: 'active',
  access_control_mode: mode,
  permissions,
  features: { crm_deals: true, crm_tasks: true },
  crm_grant_scopes: scopes,
  crm_capabilities: capabilities,
});

const routes = ['deals', 'tasks'].map(resource =>
  crmRoutes.find(route => route.name === `crm_${resource}_index`)
);
const Host = {
  setup() {
    provideSidebarContext({
      expandedItem: ref(''),
      setExpandedItem: () => {},
      isCollapsed: ref(false),
    });
    return () =>
      h(
        'nav',
        routes.map((route, index) =>
          h(SidebarGroup, {
            name: index ? 'Tasks' : 'Deals',
            label: index ? 'Tasks' : 'Deals',
            to: { name: route.name, params: { accountId: 2 } },
          })
        )
      );
  },
};

const mountLinks = () =>
  mount(Host, {
    global: {
      stubs: {
        Icon: true,
        SidebarGroupHeader: {
          props: ['label', 'to'],
          template:
            '<a v-if="to" :data-route="to.name" @click="$router.push(to)">{{ label }}</a>',
        },
      },
      mocks: { $router: { push } },
    },
  });

it.each([
  [
    'canonical observer',
    account('enforced', ['agent'], {
      deals: { view: 'all' },
      tasks: { view: 'all' },
    }),
    ['crm_deals_index', 'crm_tasks_index'],
  ],
  [
    'canonical without legacy tokens',
    account('enforced', [], {
      deals: { view: 'all' },
      tasks: { view: 'all' },
    }),
    ['crm_deals_index', 'crm_tasks_index'],
  ],
  [
    'canonical none despite role token',
    account('enforced', ['agent'], {
      deals: { view: 'none' },
      tasks: { view: 'none' },
    }),
    [],
  ],
  [
    'tasks only',
    account('enforced', ['crm_deal_view'], {
      deals: { view: 'none' },
      tasks: { view: 'own' },
    }),
    ['crm_tasks_index'],
  ],
  ['legacy', account('legacy', ['crm_deal_view']), ['crm_deals_index']],
  ['shadow', account('shadow', ['crm_task_view']), ['crm_tasks_index']],
  [
    'old-web canonical capabilities',
    account('enforced', [], undefined, { tasks: ['view'] }),
    ['crm_tasks_index'],
  ],
])(
  'renders only permitted CRM links and navigates in %s mode',
  (_, membership, expected) => {
    currentUser.value = { id: 1, accounts: [membership] };
    featureEnabled.value = true;
    push.mockClear();
    const wrapper = mountLinks();
    const links = wrapper.findAll('a[data-route]');
    expect(links.map(link => link.attributes('data-route'))).toEqual(expected);
    routes.forEach(route => {
      expect(
        routeIsAccessibleFor(
          route,
          membership.permissions,
          membership,
          currentUser.value
        )
      ).toBe(expected.includes(route.name));
    });
    links.forEach(link => link.trigger('click'));
    expect(push.mock.calls.map(([to]) => to.name)).toEqual(expected);
    wrapper.unmount();
  }
);

it('hides disabled CRM links even when grant is present', () => {
  currentUser.value = {
    id: 1,
    accounts: [
      account('enforced', [], {
        deals: { view: 'all' },
        tasks: { view: 'all' },
      }),
    ],
  };
  featureEnabled.value = false;
  const wrapper = mountLinks();
  expect(wrapper.findAll('a[data-route]')).toHaveLength(0);
  wrapper.unmount();
});
