import captainSettingsRoutes from './captain.routes';

describe('Captain settings routes', () => {
  it('keeps usage available and removes workspace AI settings', () => {
    const routeNames = captainSettingsRoutes.routes.flatMap(route =>
      (route.children || []).map(child => child.name)
    );

    expect(routeNames).toContain('captain_usage_index');
    expect(routeNames).not.toContain('captain_settings_index');
  });
});
