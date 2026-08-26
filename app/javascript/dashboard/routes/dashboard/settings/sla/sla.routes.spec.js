import slaRoutes from './sla.routes';

describe('SLA settings legacy routes', () => {
  it.each(['sla_wrapper', 'sla_list'])(
    'redirects %s into workspace settings',
    routeName => {
      const route = slaRoutes.routes.find(item => item.name === routeName);

      expect(
        route.redirect({
          params: { accountId: '7' },
          query: { source: 'bookmark' },
        })
      ).toEqual({
        name: 'workspace_sla_settings_index',
        params: { accountId: '7' },
        query: { source: 'bookmark' },
      });
    }
  );
});
