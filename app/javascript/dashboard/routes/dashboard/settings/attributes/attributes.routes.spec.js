import attributesRoutes from './attributes.routes';

describe('additional fields legacy routes', () => {
  const routeByName = name =>
    attributesRoutes.routes.find(route => route.name === name);

  it.each([
    ['attributes_list', 'conversation_attribute'],
    ['contact_fields_settings_index', 'contact_attribute'],
    ['company_fields_settings_index', 'company_attribute'],
  ])('redirects %s to the unified workspace page', (routeName, tab) => {
    const redirect = routeByName(routeName).redirect({
      params: { accountId: '7' },
      query: { source: 'bookmark' },
    });

    expect(redirect).toEqual({
      name: 'workspace_additional_fields_settings_index',
      params: { accountId: '7' },
      query: { source: 'bookmark', tab },
    });
  });

  it('keeps the legacy contact tags route pointed at global labels', () => {
    expect(
      routeByName('contact_tags_settings_index').redirect({
        params: { accountId: '7' },
      })
    ).toEqual({ name: 'labels_list', params: { accountId: '7' } });
  });
});
