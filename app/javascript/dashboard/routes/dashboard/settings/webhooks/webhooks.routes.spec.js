import { describe, expect, it } from 'vitest';

import integrationsRoutes from '../integrations/integrations.routes';
import webhooksRoutes from './webhooks.routes';

describe('webhooks.routes', () => {
  it('serves the Вебхуки page on its own route for administrators', () => {
    const [page] = webhooksRoutes.routes;
    const [child] = page.children;

    expect(page.path).toMatch(/accounts\/:accountId\/settings\/webhooks$/);
    expect(child.name).toBe('settings_webhooks');
    expect(child.meta.permissions).toEqual(['administrator']);
  });

  it('sends the old settings path to the page and keeps the url parts', () => {
    const legacy = webhooksRoutes.routes.find(route => route.redirect);

    expect(legacy.path).toMatch(/settings\/agent-bots$/);
    expect(
      legacy.redirect({
        params: { accountId: '7' },
        query: { page: '2' },
        hash: '#new',
      })
    ).toEqual({
      name: 'settings_webhooks',
      params: { accountId: '7' },
      query: { page: '2' },
      hash: '#new',
    });
  });

  it('sends the integrations webhook path to the page', () => {
    const integrations = integrationsRoutes.routes.find(
      route => route.children
    );
    const legacy = integrations.children.find(
      child => child.name === 'settings_integrations_webhook'
    );

    expect(
      legacy.redirect({ params: { accountId: '7' }, query: {}, hash: '' })
    ).toMatchObject({ name: 'settings_webhooks', params: { accountId: '7' } });
  });
});
