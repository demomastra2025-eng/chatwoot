import crmRoutes from './crm.routes';

vi.mock('../../../../store', () => ({
  default: { getters: { 'accounts/isFeatureEnabledonAccount': () => true } },
}));

const findChild = name =>
  crmRoutes.routes
    .flatMap(route => route.children || [])
    .find(route => route.name === name);

describe('CRM settings routes', () => {
  it.each([
    ['crm_deal_fields_settings_index', 'deal'],
    ['crm_task_fields_settings_index', 'task'],
  ])('redirects %s to the %s tab of additional fields', (name, tab) => {
    expect(findChild(name).redirect({ params: { accountId: '9' } })).toEqual({
      name: 'workspace_additional_fields_settings_index',
      params: { accountId: '9' },
      query: { tab },
    });
  });

  it('no longer shows a fields tab next to pipelines and task statuses', () => {
    const tabRouteNames = crmRoutes.routes.flatMap(route =>
      route.props.tabs.map(tab => tab.routeName)
    );

    expect(tabRouteNames).toEqual([
      'crm_task_settings_index',
      'crm_settings_index',
    ]);
  });
});
