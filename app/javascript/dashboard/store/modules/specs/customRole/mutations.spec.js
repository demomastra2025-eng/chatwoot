import types from '../../../mutation-types';
import { mutations } from '../../customRole';
import { accessRoleCatalog, customRoleList } from './fixtures';

describe('#mutations', () => {
  describe('#SET_CUSTOM_ROLE', () => {
    it('set custom role records', () => {
      const state = { records: [] };
      mutations[types.SET_CUSTOM_ROLE](state, customRoleList);
      expect(state.records).toEqual(customRoleList);
    });
  });

  describe('#SET_ACCESS_ROLE_CATALOG', () => {
    it('sets canonical records and metadata and clears the error', () => {
      const state = {
        accessRoleCatalog: {
          records: [],
          resources: {},
          accessScopes: [],
          error: true,
        },
      };
      const data = {
        records: accessRoleCatalog.data,
        resources: accessRoleCatalog.meta.resources,
        accessScopes: accessRoleCatalog.meta.access_scopes,
      };

      mutations[types.SET_ACCESS_ROLE_CATALOG](state, data);

      expect(state.accessRoleCatalog).toEqual({ ...data, error: false });
    });
  });

  describe('#SET_ACCESS_ROLE_CATALOG_ERROR', () => {
    it('sets the catalog error state', () => {
      const state = { accessRoleCatalog: { error: false } };

      mutations[types.SET_ACCESS_ROLE_CATALOG_ERROR](state, true);

      expect(state.accessRoleCatalog.error).toBe(true);
    });
  });

  describe('#SET_ACCESS_ROLE_CATALOG_REQUEST_ID', () => {
    it('sets the latest catalog request id', () => {
      const state = { accessRoleCatalogRequestId: 0 };

      mutations[types.SET_ACCESS_ROLE_CATALOG_REQUEST_ID](state, 2);

      expect(state.accessRoleCatalogRequestId).toBe(2);
    });
  });

  describe('#ADD_CUSTOM_ROLE', () => {
    it('push newly created custom role to the store', () => {
      const state = { records: [customRoleList[0]] };
      mutations[types.ADD_CUSTOM_ROLE](state, customRoleList[1]);
      expect(state.records).toEqual([customRoleList[0], customRoleList[1]]);
    });
  });

  describe('#EDIT_CUSTOM_ROLE', () => {
    it('update custom role record', () => {
      const state = { records: [customRoleList[0]] };
      const updatedRole = { ...customRoleList[0], name: 'Updated Role' };
      mutations[types.EDIT_CUSTOM_ROLE](state, updatedRole);
      expect(state.records).toEqual([updatedRole]);
    });
  });

  describe('#DELETE_CUSTOM_ROLE', () => {
    it('delete custom role record', () => {
      const state = { records: [customRoleList[0], customRoleList[1]] };
      mutations[types.DELETE_CUSTOM_ROLE](state, customRoleList[0].id);
      expect(state.records).toEqual([customRoleList[1]]);
    });
  });

  describe('#SET_CUSTOM_ROLE_UI_FLAG', () => {
    it('set custom role UI flags', () => {
      const state = { uiFlags: {} };
      mutations[types.SET_CUSTOM_ROLE_UI_FLAG](state, {
        fetchingList: true,
      });
      expect(state.uiFlags).toEqual({ fetchingList: true });
    });
  });
});
