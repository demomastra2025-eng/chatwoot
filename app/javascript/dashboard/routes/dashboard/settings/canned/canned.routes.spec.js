import { describe, expect, it } from 'vitest';

import cannedRoutes from './canned.routes';

describe('canned.routes', () => {
  it('redirects canned list to outbound templates', () => {
    const cannedListRoute = cannedRoutes.routes[0].children.find(
      child => child.name === 'canned_list'
    );

    expect(cannedListRoute.redirect({ params: { accountId: '1' } })).toEqual({
      name: 'outbound_templates_index',
      params: { accountId: '1' },
    });
  });
});
