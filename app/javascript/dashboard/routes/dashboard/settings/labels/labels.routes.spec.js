import labelsRoutes from './labels.routes';

const expectedPermissions = ['administrator', 'agent', 'custom_role'];

describe('label settings routes', () => {
  it('allows every account member role to manage labels', () => {
    const rootRoute = labelsRoutes.routes[0];
    const wrapperRoute = rootRoute.children.find(
      route => route.name === 'labels_wrapper'
    );
    const listRoute = rootRoute.children.find(
      route => route.name === 'labels_list'
    );

    expect(wrapperRoute.meta.permissions).toEqual(expectedPermissions);
    expect(listRoute.meta.permissions).toEqual(expectedPermissions);
  });
});
