import { vi } from 'vitest';
import { createMemoryHistory, createRouter } from 'vue-router';
import { routes } from './routes';
import store from '../../../store';
import { validateLoggedInRoutes } from '../../../helper/routeHelpers';
import { frontendURL } from '../../../helper/URLHelper';

vi.mock('../../../store', () => ({
  default: {
    getters: {
      getCurrentUser: null,
      'accounts/isFeatureEnabledonAccount': () => true,
    },
  },
}));

const routeEndingWith = suffix =>
  routes.find(route => route.path.endsWith(suffix));

describe('CRM dashboard routes', () => {
  it('chooses canonical granted landing before legacy role tokens', () => {
    const account = {
      id: 43,
      access_control_mode: 'enforced',
      permissions: ['crm_deal_view'],
      crm_grant_scopes: { deals: { view: 'none' }, tasks: { view: 'all' } },
    };
    store.getters.getCurrentUser = { accounts: [account] };
    try {
      expect(
        routeEndingWith('/crm').beforeEnter({ params: { accountId: '43' } })
          .name
      ).toBe('crm_tasks_index');
      account.crm_grant_scopes.tasks.view = 'none';
      expect(
        routeEndingWith('/crm').beforeEnter({ params: { accountId: '43' } })
          .name
      ).toBe('home');
    } finally {
      store.getters.getCurrentUser = null;
    }
  });

  it('waits for authenticated profile hydration before choosing the direct CRM landing', async () => {
    const account = {
      id: 43,
      status: 'active',
      access_control_mode: 'enforced',
      permissions: [],
      features: { crm_deals: true, crm_tasks: true },
      crm_grant_scopes: { deals: { view: 'all' }, tasks: { view: 'all' } },
    };
    const user = { accounts: [account] };
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        ...routes.map(route => ({
          ...route,
          component: { template: '<div />' },
        })),
        {
          path: frontendURL('accounts/:accountId/dashboard'),
          name: 'home',
          component: { template: '<div />' },
        },
      ],
    });
    store.getters.getCurrentUser = null;
    router.beforeEach(async to => {
      await Promise.resolve();
      store.getters.getCurrentUser = user;
      const redirect = validateLoggedInRoutes(to, user);
      return redirect ? frontendURL(redirect) : true;
    });
    try {
      await router.push(frontendURL('accounts/43/crm'));
      expect(router.currentRoute.value.name).toBe('crm_deals_index');
      expect(router.currentRoute.value.path).toBe(
        frontendURL('accounts/43/deals')
      );
      account.crm_grant_scopes.deals.view = 'none';
      await router.push(frontendURL('accounts/43/crm'));
      expect(router.currentRoute.value.name).toBe('crm_tasks_index');
    } finally {
      store.getters.getCurrentUser = null;
    }
  });

  it('uses top-level deals and tasks URLs as the canonical routes', () => {
    expect(
      routes.find(route => route.name === 'crm_deals_index')
    ).toMatchObject({
      name: 'crm_deals_index',
      path: expect.stringMatching(/\/accounts\/:accountId\/deals$/),
    });
    expect(
      routes.find(route => route.name === 'crm_tasks_index')
    ).toMatchObject({
      name: 'crm_tasks_index',
      path: expect.stringMatching(/\/accounts\/:accountId\/tasks$/),
    });
  });
  it.each([
    ['crm/deals', 'crm_deals_index'],
    ['crm/tasks', 'crm_tasks_index'],
  ])('redirects legacy %s deep links without losing state', (suffix, name) => {
    const legacyRoute = routeEndingWith(`/${suffix}`);
    const location = {
      hash: '#details',
      params: { accountId: '43' },
      query: { action: 'new', dealId: '15' },
    };
    expect(legacyRoute.redirect(location)).toEqual({
      hash: '#details',
      name,
      params: location.params,
      query: location.query,
    });
  });
});
