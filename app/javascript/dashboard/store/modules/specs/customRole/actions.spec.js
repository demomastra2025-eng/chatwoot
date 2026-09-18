import axios from 'axios';
import { actions } from '../../customRole';
import * as types from '../../../mutation-types';
import { accessRoleCatalog, customRoleList } from './fixtures';

const commit = vi.fn();
const dispatch = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#actions', () => {
  describe('#fetchAccessRoleCatalog', () => {
    const buildContext = () => {
      const state = { accessRoleCatalogRequestId: 0 };
      const catalogCommit = vi.fn((type, payload) => {
        if (type === types.default.SET_ACCESS_ROLE_CATALOG_REQUEST_ID) {
          state.accessRoleCatalogRequestId = payload;
        }
      });
      return { state, commit: catalogCommit };
    };

    it('stores the canonical catalog if API is successful', async () => {
      const context = buildContext();
      axios.get.mockResolvedValue({ data: accessRoleCatalog });

      await actions.fetchAccessRoleCatalog(context);

      expect(context.commit.mock.calls).toEqual([
        [types.default.SET_ACCESS_ROLE_CATALOG_REQUEST_ID, 1],
        [
          types.default.SET_CUSTOM_ROLE_UI_FLAG,
          { fetchingAccessRoleCatalog: true },
        ],
        [types.default.SET_ACCESS_ROLE_CATALOG_ERROR, false],
        [
          types.default.SET_ACCESS_ROLE_CATALOG,
          {
            records: accessRoleCatalog.data,
            resources: accessRoleCatalog.meta.resources,
            accessScopes: accessRoleCatalog.meta.access_scopes,
            mutationsEnabled: accessRoleCatalog.meta.mutations_enabled,
            legacyMutationsEnabled:
              accessRoleCatalog.meta.legacy_mutations_enabled,
            loaded: true,
          },
        ],
        [
          types.default.SET_CUSTOM_ROLE_UI_FLAG,
          { fetchingAccessRoleCatalog: false },
        ],
      ]);
    });

    it('keeps the legacy writer for an older API without capability fields', async () => {
      const context = buildContext();
      const legacyResponse = {
        data: accessRoleCatalog.data,
        meta: {
          resources: accessRoleCatalog.meta.resources,
          access_scopes: accessRoleCatalog.meta.access_scopes,
        },
      };
      axios.get.mockResolvedValue({ data: legacyResponse });

      await actions.fetchAccessRoleCatalog(context);

      expect(context.commit).toHaveBeenCalledWith(
        types.default.SET_ACCESS_ROLE_CATALOG,
        expect.objectContaining({
          mutationsEnabled: false,
          legacyMutationsEnabled: true,
          loaded: true,
        })
      );
    });

    it('stores an error and clears loading if API fails', async () => {
      const context = buildContext();
      axios.get.mockRejectedValue({ message: 'Request failed' });

      await actions.fetchAccessRoleCatalog(context);

      expect(context.commit.mock.calls).toEqual([
        [types.default.SET_ACCESS_ROLE_CATALOG_REQUEST_ID, 1],
        [
          types.default.SET_CUSTOM_ROLE_UI_FLAG,
          { fetchingAccessRoleCatalog: true },
        ],
        [types.default.SET_ACCESS_ROLE_CATALOG_ERROR, false],
        [types.default.SET_ACCESS_ROLE_CATALOG_ERROR, true],
        [
          types.default.SET_CUSTOM_ROLE_UI_FLAG,
          { fetchingAccessRoleCatalog: false },
        ],
      ]);
    });

    it('rejects a required authoritative refresh if the API fails', async () => {
      const context = buildContext();
      const refreshError = new Error('Catalog refresh failed');
      axios.get.mockRejectedValue(refreshError);

      await expect(
        actions.fetchAccessRoleCatalog(context, { throwOnError: true })
      ).rejects.toBe(refreshError);

      expect(context.commit).toHaveBeenCalledWith(
        types.default.SET_ACCESS_ROLE_CATALOG_ERROR,
        true
      );
    });

    it('ignores a stale response that finishes after a newer request', async () => {
      const context = buildContext();
      let resolveFirst;
      let resolveSecond;
      const firstResponse = new Promise(resolve => {
        resolveFirst = resolve;
      });
      const secondResponse = new Promise(resolve => {
        resolveSecond = resolve;
      });
      const newerCatalog = {
        ...accessRoleCatalog,
        data: [{ ...accessRoleCatalog.data[0], name: 'New catalog' }],
      };
      axios.get
        .mockReturnValueOnce(firstResponse)
        .mockReturnValueOnce(secondResponse);

      const firstRequest = actions.fetchAccessRoleCatalog(context);
      const secondRequest = actions.fetchAccessRoleCatalog(context);
      resolveSecond({ data: newerCatalog });
      await secondRequest;
      resolveFirst({ data: accessRoleCatalog });
      await firstRequest;

      const catalogCommits = context.commit.mock.calls.filter(
        ([type]) => type === types.default.SET_ACCESS_ROLE_CATALOG
      );
      expect(catalogCommits).toEqual([
        [
          types.default.SET_ACCESS_ROLE_CATALOG,
          {
            records: newerCatalog.data,
            resources: newerCatalog.meta.resources,
            accessScopes: newerCatalog.meta.access_scopes,
            mutationsEnabled: newerCatalog.meta.mutations_enabled,
            legacyMutationsEnabled: newerCatalog.meta.legacy_mutations_enabled,
            loaded: true,
          },
        ],
      ]);
      expect(context.state.accessRoleCatalogRequestId).toBe(2);
    });

    it('rejects a required stale request when the newer refresh fails', async () => {
      const context = buildContext();
      let resolveFirst;
      let rejectSecond;
      const firstResponse = new Promise(resolve => {
        resolveFirst = resolve;
      });
      const refreshError = new Error('Newer catalog refresh failed');
      const secondResponse = new Promise((resolve, reject) => {
        rejectSecond = reject;
      });
      axios.get
        .mockReturnValueOnce(firstResponse)
        .mockReturnValueOnce(secondResponse);

      const requiredRequest = actions.fetchAccessRoleCatalog(context, {
        throwOnError: true,
      });
      const newerRequest = actions.fetchAccessRoleCatalog(context);
      rejectSecond(refreshError);
      await expect(newerRequest).resolves.toBe(false);
      resolveFirst({ data: accessRoleCatalog });

      await expect(requiredRequest).rejects.toBe(refreshError);
    });
  });

  describe('normalized access role mutations', () => {
    const accessRole = {
      id: 10,
      name: 'Support',
      description: 'Supports customers',
      lock_version: 4,
      grants: [
        {
          resource: 'contacts',
          capability: 'view',
          access_scope: 'team',
        },
      ],
    };

    it('creates a role and waits for the authoritative catalog refresh', async () => {
      dispatch.mockResolvedValue();
      axios.post.mockResolvedValue({ data: { data: accessRole } });

      await expect(
        actions.createAccessRole(
          { commit, dispatch },
          {
            name: accessRole.name,
            description: accessRole.description,
            grants: accessRole.grants,
          }
        )
      ).resolves.toEqual(accessRole);

      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/access_roles'),
        {
          access_role: {
            name: accessRole.name,
            description: accessRole.description,
            grants: accessRole.grants,
          },
        }
      );
      expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog', {
        throwOnError: true,
      });
      expect(commit).toHaveBeenLastCalledWith(
        types.default.SET_CUSTOM_ROLE_UI_FLAG,
        { creatingItem: false }
      );
    });

    it('refreshes before reporting a stale update', async () => {
      dispatch.mockResolvedValue();
      axios.patch.mockRejectedValue({
        response: {
          data: {
            code: 'STALE_ACCESS_ROLE',
            error: 'Access role has been changed by another request',
          },
        },
      });

      await expect(
        actions.updateAccessRole(
          { commit, dispatch },
          { id: accessRole.id, lock_version: 3, name: 'Stale name' }
        )
      ).rejects.toMatchObject({ code: 'STALE_ACCESS_ROLE' });

      expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog', {
        throwOnError: true,
      });
      expect(commit).toHaveBeenLastCalledWith(
        types.default.SET_CUSTOM_ROLE_UI_FLAG,
        { updatingItem: false }
      );
    });

    it.each([
      [404, undefined, 'ACCESS_ROLE_NOT_FOUND'],
      [
        409,
        'ACCESS_ROLE_MUTATIONS_NOT_ENABLED',
        'ACCESS_ROLE_MUTATIONS_NOT_ENABLED',
      ],
      [409, 'ACCESS_CONTROL_NOT_ENFORCED', 'ACCESS_CONTROL_NOT_ENFORCED'],
    ])(
      'refreshes capabilities after mutation error %s/%s',
      async (status, responseCode, expectedCode) => {
        dispatch.mockResolvedValue();
        axios.patch.mockRejectedValue({
          response: {
            status,
            data: {
              code: responseCode,
              error: 'Mutation mode changed',
            },
          },
        });

        await expect(
          actions.updateAccessRole(
            { commit, dispatch },
            { id: accessRole.id, lock_version: 4, name: 'Updated name' }
          )
        ).rejects.toMatchObject({ code: expectedCode });

        expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog', {
          throwOnError: true,
        });
      }
    );

    it.each([
      [404, undefined],
      [409, 'ACCESS_ROLE_MUTATIONS_NOT_ENABLED'],
      [409, 'ACCESS_CONTROL_NOT_ENFORCED'],
      [409, 'STALE_ACCESS_ROLE'],
    ])(
      'does not report conflict %s/%s before the required refresh succeeds',
      async (status, responseCode) => {
        const refreshError = new Error('Catalog refresh failed');
        dispatch.mockRejectedValue(refreshError);
        axios.patch.mockRejectedValue({
          response: {
            status,
            data: { code: responseCode, error: 'Mutation conflict' },
          },
        });

        await expect(
          actions.updateAccessRole(
            { commit, dispatch },
            { id: accessRole.id, lock_version: 4, name: 'Updated name' }
          )
        ).rejects.toBe(refreshError);
      }
    );

    it('does not report mutation success if its required refresh fails', async () => {
      const refreshError = new Error('Catalog refresh failed');
      dispatch.mockRejectedValue(refreshError);
      axios.post.mockResolvedValue({ data: { data: accessRole } });

      await expect(
        actions.createAccessRole(
          { commit, dispatch },
          {
            name: accessRole.name,
            description: accessRole.description,
            grants: accessRole.grants,
          }
        )
      ).rejects.toBe(refreshError);
    });

    it('sends lock_version in the delete request body', async () => {
      dispatch.mockResolvedValue();
      axios.delete.mockResolvedValue({ data: {} });

      await actions.deleteAccessRole(
        { commit, dispatch },
        { id: accessRole.id, lockVersion: accessRole.lock_version }
      );

      expect(axios.delete).toHaveBeenCalledWith(
        expect.stringContaining(`/access_roles/${accessRole.id}`),
        {
          data: {
            access_role: { lock_version: accessRole.lock_version },
          },
        }
      );
      expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog', {
        throwOnError: true,
      });
    });
  });

  describe('#getCustomRole', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({ data: customRoleList });
      await actions.getCustomRole({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { fetchingList: true }],
        [types.default.SET_CUSTOM_ROLE, customRoleList],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { fetchingList: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.getCustomRole({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { fetchingList: true }],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { fetchingList: false }],
      ]);
    });
  });

  describe('#createCustomRole', () => {
    it('sends correct actions if API is success', async () => {
      dispatch.mockResolvedValue();
      axios.post.mockResolvedValue({ data: customRoleList[0] });
      await actions.createCustomRole({ commit, dispatch }, customRoleList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { creatingItem: true }],
        [types.default.ADD_CUSTOM_ROLE, customRoleList[0]],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { creatingItem: false }],
      ]);
      expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog');
    });

    it('keeps creation loading until the catalog refresh finishes', async () => {
      let resolveRefresh;
      dispatch.mockReturnValueOnce(
        new Promise(resolve => {
          resolveRefresh = resolve;
        })
      );
      axios.post.mockResolvedValue({ data: customRoleList[0] });

      const request = actions.createCustomRole(
        { commit, dispatch },
        customRoleList[0]
      );
      await vi.waitFor(() => {
        expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog');
      });

      expect(commit).not.toHaveBeenCalledWith(
        types.default.SET_CUSTOM_ROLE_UI_FLAG,
        { creatingItem: false }
      );
      resolveRefresh();
      await request;
      expect(commit).toHaveBeenLastCalledWith(
        types.default.SET_CUSTOM_ROLE_UI_FLAG,
        { creatingItem: false }
      );
    });

    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.createCustomRole({ commit, dispatch })
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { creatingItem: true }],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { creatingItem: false }],
      ]);
      expect(dispatch).not.toHaveBeenCalled();
    });
  });

  describe('#updateCustomRole', () => {
    it('sends correct actions if API is success', async () => {
      dispatch.mockResolvedValue();
      axios.patch.mockResolvedValue({ data: customRoleList[0] });
      await actions.updateCustomRole(
        { commit, dispatch },
        { id: 1, ...customRoleList[0] }
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { updatingItem: true }],
        [types.default.EDIT_CUSTOM_ROLE, customRoleList[0]],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { updatingItem: false }],
      ]);
      expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog');
    });
    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.updateCustomRole({ commit, dispatch }, { id: 1 })
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { updatingItem: true }],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { updatingItem: false }],
      ]);
      expect(dispatch).not.toHaveBeenCalled();
    });
  });

  describe('#deleteCustomRole', () => {
    it('sends correct actions if API is success', async () => {
      dispatch.mockResolvedValue();
      axios.delete.mockResolvedValue({ data: customRoleList[0] });
      await actions.deleteCustomRole({ commit, dispatch }, 1);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { deletingItem: true }],
        [types.default.DELETE_CUSTOM_ROLE, 1],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { deletingItem: false }],
      ]);
      expect(dispatch).toHaveBeenCalledWith('fetchAccessRoleCatalog');
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.deleteCustomRole({ commit, dispatch }, 1)
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { deletingItem: true }],
        [types.default.SET_CUSTOM_ROLE_UI_FLAG, { deletingItem: false }],
      ]);
      expect(dispatch).not.toHaveBeenCalled();
    });
  });
});
