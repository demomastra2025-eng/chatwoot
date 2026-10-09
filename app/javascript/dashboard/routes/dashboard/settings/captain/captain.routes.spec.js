import captainSettingsRoutes from './captain.routes';

describe('Captain settings routes', () => {
  it('redirects both former AI settings URLs to global conversation settings', () => {
    expect(captainSettingsRoutes.routes).toHaveLength(2);
    const legacyRoutes = captainSettingsRoutes.routes;

    for (const legacyRoute of legacyRoutes) {
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
    }
  });
});
