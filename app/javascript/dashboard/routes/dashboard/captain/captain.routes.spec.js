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

  it('exposes the assistant playground page', () => {
    const playgroundRoute = flattenRoutes(routes).find(
      route => route.name === 'captain_assistants_playground_index'
    );

    expect(playgroundRoute).toBeTruthy();
    expect(playgroundRoute.path).toContain('/captain/:assistantId/playground');
    expect(playgroundRoute.component).toBeTypeOf('function');
    expect(playgroundRoute.redirect).toBeUndefined();
  });
});
