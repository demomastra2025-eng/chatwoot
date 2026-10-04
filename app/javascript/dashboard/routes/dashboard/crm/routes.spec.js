import { routes } from './routes';

const routeEndingWith = suffix =>
  routes.find(route => route.path.endsWith(suffix));

describe('CRM dashboard routes', () => {
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
