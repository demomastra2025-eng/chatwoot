import { describe, expect, it } from 'vitest';
import storageRoutes from './storage.routes';

describe('storage.routes', () => {
  it('defines storage settings index route with administrator permission', () => {
    const parentRoute = storageRoutes.routes[0];
    expect(parentRoute.path).toContain('settings/storage');

    const indexRoute = parentRoute.children.find(
      child => child.name === 'storage_settings_index'
    );
    expect(indexRoute).toBeDefined();
    expect(indexRoute.meta.permissions).toEqual(['administrator']);
  });
});
