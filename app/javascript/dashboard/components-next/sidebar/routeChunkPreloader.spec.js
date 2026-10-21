import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  preloadRouteComponents,
  preloadSidebarMenuTargets,
  resetPreloadedRouteComponentsForTests,
} from './routeChunkPreloader';

describe('routeChunkPreloader', () => {
  beforeEach(() => {
    resetPreloadedRouteComponentsForTests();
  });

  it('preloads lazy route components once per resolved route', () => {
    const contactsChunk = vi.fn(() => Promise.resolve({}));
    const router = {
      resolve: vi.fn(() => ({
        name: 'contacts_dashboard_index',
        path: '/app/accounts/1/contacts',
        matched: [{ components: { default: contactsChunk } }],
      })),
    };

    preloadRouteComponents(router, { name: 'contacts_dashboard_index' });
    preloadRouteComponents(router, { name: 'contacts_dashboard_index' });

    expect(contactsChunk).toHaveBeenCalledTimes(1);
  });

  it('preloads default child targets for sidebar menu items', () => {
    const contactsChunk = vi.fn(() => Promise.resolve({}));
    const dealsChunk = vi.fn(() => Promise.resolve({}));
    const router = {
      resolve: vi.fn(to => ({
        name: to.name,
        path: `/app/accounts/1/${to.name}`,
        matched: [
          {
            components: {
              default:
                to.name === 'contacts_dashboard_index'
                  ? contactsChunk
                  : dealsChunk,
            },
          },
        ],
      })),
    };

    preloadSidebarMenuTargets(router, [
      {
        name: 'Contacts',
        defaultChildName: 'All Contacts',
        children: [
          {
            name: 'All Contacts',
            to: { name: 'contacts_dashboard_index' },
          },
        ],
      },
      {
        name: 'CRM',
        to: { name: 'crm_deals_index' },
      },
    ]);

    expect(contactsChunk).toHaveBeenCalledTimes(1);
    expect(dealsChunk).toHaveBeenCalledTimes(1);
  });
});
