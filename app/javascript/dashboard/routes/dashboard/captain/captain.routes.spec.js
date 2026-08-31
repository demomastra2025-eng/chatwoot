import { describe, expect, it } from 'vitest';
import { routes } from './captain.routes';

const flattenRoutes = items =>
  items.flatMap(route => [
    route,
    ...(route.children ? flattenRoutes(route.children) : []),
  ]);

describe('captain routes', () => {
  it('does not expose the removed AI evaluations page', () => {
    const evaluationRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_evaluations_index'
    );

    expect(evaluationRoute).toBeUndefined();
  });

  it('exposes the assistant sandbox at the playground route', () => {
    const playgroundRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_assistants_playground_index'
    );

    expect(playgroundRoute).toBeTruthy();
    expect(playgroundRoute.path).toContain('/captain/:assistantId/playground');
    expect(playgroundRoute.component).toBeTypeOf('function');
    expect(playgroundRoute.redirect).toBeUndefined();
  });

  it('redirects the legacy outcomes route to the assistant profile', () => {
    const outcomesRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_assistants_outcomes_index'
    );

    expect(outcomesRoute).toBeTruthy();
    expect(outcomesRoute.path).toContain('/captain/:assistantId/outcomes');
    expect(outcomesRoute.component).toBeUndefined();
    expect(
      outcomesRoute.redirect({ params: { assistantId: '42' }, query: {} })
    ).toEqual({
      name: 'captain_assistants_settings_index',
      params: { assistantId: '42' },
      query: { tab: 'profile' },
    });
  });

  it('redirects the removed channels page to channel settings', () => {
    const channelsRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_assistants_channels_index'
    );

    expect(channelsRoute).toBeTruthy();
    expect(channelsRoute.path).toContain('/captain/:assistantId/channels');
    expect(channelsRoute.component).toBeUndefined();
    expect(
      channelsRoute.redirect({
        params: { accountId: '1', assistantId: '2' },
        query: { source: 'legacy' },
      })
    ).toEqual({
      name: 'settings_inbox_list',
      params: { accountId: '1' },
      query: { source: 'legacy' },
    });
  });

  it('hides assistant configuration routes from ordinary agents', () => {
    const managedRouteNames = [
      'captain_assistants_create_index',
      'captain_assistants_follow_ups_index',
      'captain_assistants_prompts_index',
      'captain_assistants_settings_index',
    ];

    managedRouteNames.forEach(routeName => {
      const route = flattenRoutes(routes).find(item => item.name === routeName);
      expect(route.meta.permissions).toEqual([
        'administrator',
        'captain_manage',
      ]);
    });
  });
});
