import automationRoutes from './automation.routes';

describe('automation routes', () => {
  it('does not expose the retired reminder plan page', () => {
    const settingsRoute = automationRoutes.routes.find(route =>
      route.path.includes('settings/automation')
    );

    expect(settingsRoute.children.map(route => route.name)).not.toContain(
      'automation_touch_plans_index'
    );
  });
});
