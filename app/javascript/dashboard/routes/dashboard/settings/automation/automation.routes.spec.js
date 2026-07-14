import automationRoutes from './automation.routes';

describe('automation routes', () => {
  it('moves the legacy touch-plans URL into the Captain assistant workspace', () => {
    const settingsRoute = automationRoutes.routes.find(route =>
      route.path.includes('settings/automation')
    );
    const touchPlansRoute = settingsRoute.children.find(
      route => route.name === 'automation_touch_plans_index'
    );

    expect(
      touchPlansRoute.redirect({
        params: { accountId: '1' },
        query: { remindable_id: '7' },
      })
    ).toEqual({
      name: 'captain_assistants_index',
      params: {
        accountId: '1',
        navigationPath: 'captain_assistants_follow_ups_index',
      },
      query: { remindable_id: '7' },
    });
  });
});
