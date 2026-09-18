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
          },
        ],
        [
          types.default.SET_CUSTOM_ROLE_UI_FLAG,
          { fetchingAccessRoleCatalog: false },
        ],
      ]);
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
          },
        ],
      ]);
      expect(context.state.accessRoleCatalogRequestId).toBe(2);
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
