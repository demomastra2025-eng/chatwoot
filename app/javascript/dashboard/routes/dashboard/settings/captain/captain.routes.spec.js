import captainSettingsRoutes from './captain.routes';

const childRoutes = () =>
  captainSettingsRoutes.routes.flatMap(route =>
    (route.children || []).map(child => ({ parent: route, child }))
  );

describe('Captain settings routes', () => {
  it('keeps the AI settings page and adds the usage page for «Расходы»', () => {
    const routeNames = childRoutes().map(({ child }) => child.name);

    expect(routeNames).toContain('captain_settings_index');
    expect(routeNames).toContain('captain_usage_index');
  });

  it('opens only the usage section for administrators with Captain', () => {
    const { parent, child } = childRoutes().find(
      ({ child: route }) => route.name === 'captain_usage_index'
    );

    expect(child.props).toEqual({ section: 'usage' });
    expect(parent.path).toContain('captain/usage');
    expect(child.meta.permissions).toEqual(['administrator']);
    expect(child.meta.featureFlag).toBeTruthy();
  });

  it('opens the full AI settings page without a section filter', () => {
    const { parent, child } = childRoutes().find(
      ({ child: route }) => route.name === 'captain_settings_index'
    );

    expect(child.props).toBeUndefined();
    expect(parent.path).toContain('captain/settings');
  });

  it('redirects the former settings URL to the AI section route', () => {
    const legacyRoute = captainSettingsRoutes.routes.find(route =>
      route.path.endsWith('/settings/captain')
    );

    expect(
      legacyRoute.redirect({
        params: { accountId: '7' },
        query: { tab: 'models' },
        hash: '#model',
      })
    ).toEqual({
      name: 'captain_settings_index',
      params: { accountId: '7' },
      query: { tab: 'models' },
      hash: '#model',
    });
  });
});
