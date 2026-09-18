import { throwErrorMessage } from 'dashboard/store/utils/api';
import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import * as types from '../mutation-types';
import CustomRoleAPI from '../../api/customRole';
import AccessRoleAPI from '../../api/accessRole';

export const state = {
  records: [],
  accessRoleCatalog: {
    records: [],
    resources: {},
    accessScopes: [],
    error: false,
  },
  accessRoleCatalogRequestId: 0,
  uiFlags: {
    fetchingList: false,
    fetchingAccessRoleCatalog: false,
    creatingItem: false,
    updatingItem: false,
    deletingItem: false,
  },
};

export const getters = {
  getCustomRoles($state) {
    return $state.records;
  },
  getAccessRoleCatalog($state) {
    return $state.accessRoleCatalog;
  },
  getUIFlags($state) {
    return $state.uiFlags;
  },
};

export const actions = {
  fetchAccessRoleCatalog: async function fetchAccessRoleCatalog({
    commit,
    state: $state,
  }) {
    const requestId = $state.accessRoleCatalogRequestId + 1;
    commit(types.default.SET_ACCESS_ROLE_CATALOG_REQUEST_ID, requestId);
    commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, {
      fetchingAccessRoleCatalog: true,
    });
    commit(types.default.SET_ACCESS_ROLE_CATALOG_ERROR, false);
    try {
      const response = await AccessRoleAPI.get();
      if ($state.accessRoleCatalogRequestId !== requestId) return;
      const { data = [], meta = {} } = response.data;
      commit(types.default.SET_ACCESS_ROLE_CATALOG, {
        records: data,
        resources: meta.resources || {},
        accessScopes: meta.access_scopes || [],
      });
    } catch (error) {
      if ($state.accessRoleCatalogRequestId !== requestId) return;
      commit(types.default.SET_ACCESS_ROLE_CATALOG_ERROR, true);
    } finally {
      if ($state.accessRoleCatalogRequestId === requestId) {
        commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, {
          fetchingAccessRoleCatalog: false,
        });
      }
    }
  },

  getCustomRole: async function getCustomRole({ commit }) {
    commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { fetchingList: true });
    try {
      const response = await CustomRoleAPI.get();
      commit(types.default.SET_CUSTOM_ROLE, response.data);
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { fetchingList: false });
    } catch (error) {
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { fetchingList: false });
    }
  },

  createCustomRole: async function createCustomRole(
    { commit, dispatch },
    customRoleObj
  ) {
    commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { creatingItem: true });
    try {
      const response = await CustomRoleAPI.create(customRoleObj);
      commit(types.default.ADD_CUSTOM_ROLE, response.data);
      await dispatch('fetchAccessRoleCatalog');
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { creatingItem: false });
      return response.data;
    } catch (error) {
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { creatingItem: false });
      return throwErrorMessage(error);
    }
  },

  updateCustomRole: async function updateCustomRole(
    { commit, dispatch },
    { id, ...updateObj }
  ) {
    commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { updatingItem: true });
    try {
      const response = await CustomRoleAPI.update(id, updateObj);
      commit(types.default.EDIT_CUSTOM_ROLE, response.data);
      await dispatch('fetchAccessRoleCatalog');
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { updatingItem: false });
      return response.data;
    } catch (error) {
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { updatingItem: false });
      return throwErrorMessage(error);
    }
  },

  deleteCustomRole: async function deleteCustomRole({ commit, dispatch }, id) {
    commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { deletingItem: true });
    try {
      await CustomRoleAPI.delete(id);
      commit(types.default.DELETE_CUSTOM_ROLE, id);
      await dispatch('fetchAccessRoleCatalog');
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { deletingItem: false });
      return id;
    } catch (error) {
      commit(types.default.SET_CUSTOM_ROLE_UI_FLAG, { deletingItem: false });
      return throwErrorMessage(error);
    }
  },
};

export const mutations = {
  [types.default.SET_CUSTOM_ROLE_UI_FLAG](_state, data) {
    _state.uiFlags = {
      ..._state.uiFlags,
      ...data,
    };
  },

  [types.default.SET_CUSTOM_ROLE]: MutationHelpers.set,
  [types.default.SET_ACCESS_ROLE_CATALOG](_state, data) {
    _state.accessRoleCatalog = {
      ..._state.accessRoleCatalog,
      ...data,
      error: false,
    };
  },
  [types.default.SET_ACCESS_ROLE_CATALOG_ERROR](_state, error) {
    _state.accessRoleCatalog.error = error;
  },
  [types.default.SET_ACCESS_ROLE_CATALOG_REQUEST_ID](_state, requestId) {
    _state.accessRoleCatalogRequestId = requestId;
  },
  [types.default.ADD_CUSTOM_ROLE]: MutationHelpers.create,
  [types.default.EDIT_CUSTOM_ROLE]: MutationHelpers.update,
  [types.default.DELETE_CUSTOM_ROLE]: MutationHelpers.destroy,
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
