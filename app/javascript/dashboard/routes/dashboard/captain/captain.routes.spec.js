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
});
