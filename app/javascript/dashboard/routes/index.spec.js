import { validateAuthenticateRoutePermission } from './index';
import store from '../store'; // This import will be mocked
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { vi } from 'vitest';

// Mock the store module
vi.mock('../store', () => ({
  default: {
    getters: {
      isLoggedIn: false,
      getCurrentUser: {
        account_id: null,
        id: null,
        accounts: [],
      },
    },
  },
}));

describe('#validateAuthenticateRoutePermission', () => {
  let next;

  beforeEach(() => {
    next = vi.fn(); // Mock the next function
    store.dispatch = vi.fn().mockResolvedValue();
    store.getters['accounts/getAccount'] = vi.fn(() => ({}));
  });

  describe('when user is not logged in', () => {
    it('should redirect to login', () => {
      const to = { name: 'some-protected-route', params: { accountId: 1 } };

      // Mock the store to simulate user not logged in
      store.getters.isLoggedIn = false;

      // Mock window.location.assign
      const mockAssign = vi.fn();
      delete window.location;
      window.location = { assign: mockAssign };

      validateAuthenticateRoutePermission(to, next);

      expect(mockAssign).toHaveBeenCalledWith('/app/login');
    });
  });

  describe('when user is logged in', () => {
    beforeEach(() => {
      // Mock the store's getter for a logged-in user
      store.getters.isLoggedIn = true;
      store.getters.getCurrentUser = {
        account_id: 1,
        id: 1,
        accounts: [
          {
            id: 1,
            role: 'agent',
            permissions: ['agent'],
            status: 'active',
          },
        ],
      };
    });

    describe('when route is not accessible to current user', () => {
      it('should redirect to dashboard', async () => {
        const to = {
          name: 'general_settings_index',
          params: { accountId: 1 },
          meta: { permissions: ['administrator'] },
        };

        await validateAuthenticateRoutePermission(to, next);

        expect(next).toHaveBeenCalledWith('/app/accounts/1/dashboard');
      });

      it('hydrates account features before choosing the fallback route', async () => {
        let hasHydratedAccount = false;
        store.dispatch = vi.fn().mockImplementation(async action => {
          if (action === 'accounts/get') {
            hasHydratedAccount = true;
          }
        });
        store.getters['accounts/getAccount'] = vi.fn(() =>
          hasHydratedAccount
            ? {
                id: 1,
                features: { [FEATURE_FLAGS.COMMUNICATION_THREADS]: true },
              }
            : { id: 1 }
        );

        const to = {
          name: 'general_settings_index',
          params: { accountId: 1 },
          meta: { permissions: ['administrator'] },
        };

        await validateAuthenticateRoutePermission(to, next);

        expect(store.dispatch).toHaveBeenCalledWith('accounts/get');
        expect(next).toHaveBeenCalledWith(
          '/app/accounts/1/communication_threads?status=open&assignee_type=me'
        );
      });
    });

    describe('when navigating to the account root', () => {
      it('redirects to communication threads when the feature is enabled', async () => {
        store.getters['accounts/getAccount'] = vi.fn(() => ({
          id: 1,
          features: { [FEATURE_FLAGS.COMMUNICATION_THREADS]: true },
        }));

        const to = {
          name: undefined,
          params: { accountId: 1 },
          meta: {},
        };

        await validateAuthenticateRoutePermission(to, next);

        expect(next).toHaveBeenCalledWith(
          '/app/accounts/1/communication_threads?status=open&assignee_type=me'
        );
      });

      it('hydrates account features when the cached account record is incomplete', async () => {
        let hasHydratedAccount = false;
        store.dispatch = vi.fn().mockImplementation(async action => {
          if (action === 'accounts/get') {
            hasHydratedAccount = true;
          }
        });
        store.getters['accounts/getAccount'] = vi.fn(() =>
          hasHydratedAccount
            ? {
                id: 1,
                features: { [FEATURE_FLAGS.COMMUNICATION_THREADS]: true },
              }
            : { id: 1 }
        );

        const to = {
          name: undefined,
          params: { accountId: 1 },
          meta: {},
        };

        await validateAuthenticateRoutePermission(to, next);

        expect(store.dispatch).toHaveBeenCalledWith('accounts/get');
        expect(next).toHaveBeenCalledWith(
          '/app/accounts/1/communication_threads?status=open&assignee_type=me'
        );
      });

      it('redirects the legacy dashboard route to communication threads when the feature is enabled', async () => {
        store.getters['accounts/getAccount'] = vi.fn(() => ({
          id: 1,
          features: { [FEATURE_FLAGS.COMMUNICATION_THREADS]: true },
        }));

        const to = {
          name: 'home',
          params: { accountId: 1 },
          meta: { permissions: ['agent'] },
        };

        await validateAuthenticateRoutePermission(to, next);

        expect(next).toHaveBeenCalledWith(
          '/app/accounts/1/communication_threads?status=open&assignee_type=me'
        );
      });
    });

    describe('when route is accessible to current user', () => {
      beforeEach(() => {
        // Adjust store getters to reflect the user has admin permissions
        store.getters.getCurrentUser = {
          account_id: 1,
          id: 1,
          accounts: [
            {
              id: 1,
              role: 'administrator',
              permissions: ['administrator'],
              status: 'active',
            },
          ],
        };
      });

      it('should go to the intended route', async () => {
        const to = {
          name: 'general_settings_index',
          params: { accountId: 1 },
          meta: { permissions: ['administrator'] },
        };

        await validateAuthenticateRoutePermission(to, next);

        expect(next).toHaveBeenCalledWith();
      });

      it('hydrates account features before guarding feature-flag routes', async () => {
        let hasHydratedAccount = false;
        store.dispatch = vi.fn().mockImplementation(async action => {
          if (action === 'accounts/get') {
            hasHydratedAccount = true;
          }
        });
        store.getters['accounts/getAccount'] = vi.fn(() =>
          hasHydratedAccount
            ? {
                id: 1,
                features: { [FEATURE_FLAGS.INBOX_MANAGEMENT]: true },
              }
            : {}
        );

        const to = {
          name: 'settings_inbox_list',
          params: { accountId: 1 },
          meta: {
            permissions: ['administrator'],
            featureFlag: FEATURE_FLAGS.INBOX_MANAGEMENT,
          },
        };

        await validateAuthenticateRoutePermission(to, next);

        expect(store.dispatch).toHaveBeenCalledWith('accounts/get');
        expect(next).toHaveBeenCalledWith();
      });
    });
  });
});
