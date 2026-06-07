import { describe, expect, it } from 'vitest';
import { routes } from './captain.routes';

const flattenRoutes = items =>
  items.flatMap(route => [
    route,
    ...(route.children ? flattenRoutes(route.children) : []),
  ]);

describe('captain routes', () => {
  it('exposes a dedicated AI evaluations page', () => {
    const evaluationRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_evaluations_index'
    );

    expect(evaluationRoute).toBeTruthy();
    expect(evaluationRoute.path).toContain('/captain/evaluations');
    expect(evaluationRoute.meta.permissions).toEqual(['administrator']);
  });

  it('redirects the removed assistant playground page to prompts', () => {
    const playgroundRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_assistants_playground_index'
    );

    expect(playgroundRoute).toBeTruthy();
    expect(playgroundRoute.path).toContain('/captain/:assistantId/playground');
    expect(playgroundRoute.component).toBeUndefined();
    expect(
      playgroundRoute.redirect({
        params: { accountId: '1', assistantId: '2' },
        query: { source: 'legacy' },
      })
    ).toEqual({
      name: 'captain_assistants_prompts_index',
      params: { accountId: '1', assistantId: '2' },
      query: { source: 'legacy' },
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
});
