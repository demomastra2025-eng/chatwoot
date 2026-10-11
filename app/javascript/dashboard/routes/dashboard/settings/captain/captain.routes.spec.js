import captainSettingsRoutes from './captain.routes';

describe('Captain settings routes', () => {
  it('redirects the former AI settings URL to global conversation settings', () => {
    expect(captainSettingsRoutes.routes).toHaveLength(1);
    const [legacyRoute] = captainSettingsRoutes.routes;

    expect(legacyRoute.path).toContain('/settings/captain');
    expect(
      legacyRoute.redirect({
        params: { accountId: '7' },
        query: { tab: 'models' },
        hash: '#model',
      })
    ).toEqual({
      name: 'workspace_conversation_settings_index',
      params: { accountId: '7' },
      query: { tab: 'models' },
      hash: '#model',
    });
  });

  it('leaves captain/settings to the AI settings page', () => {
    const paths = captainSettingsRoutes.routes.map(route => route.path);

    expect(paths.some(path => path.endsWith('/captain/settings'))).toBe(false);
    expect(
      captainSettingsRoutes.routes.some(
        route => route.name === 'captain_settings_index'
      )
    ).toBe(false);
  });
});
