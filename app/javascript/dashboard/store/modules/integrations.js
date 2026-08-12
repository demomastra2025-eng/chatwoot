/* eslint no-param-reassign: 0 */
import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import * as types from '../mutation-types';
import IntegrationsAPI from '../../api/integrations';
import {
  parseAPIErrorResponse,
  throwErrorMessage,
} from 'dashboard/store/utils/api';

const normalizeApiError = error =>
  Object.assign(new Error(parseAPIErrorResponse(error)), error);

const state = {
  records: [],
  uiFlags: {
    isCreating: false,
    isFetching: false,
    isFetchingItem: false,
    isUpdating: false,
    isCreatingHook: false,
    isUpdatingHook: false,
    isDeletingHook: false,
    isRunningHookSync: false,
    isImportingHookCatalog: false,
    isCreatingSlack: false,
    isUpdatingSlack: false,
    isFetchingSlackChannels: false,
  },
};

export const getters = {
  getAppIntegrations($state) {
    return $state.records;
  },
  getIntegration:
    $state =>
    (integrationId, defaultValue = {}) => {
      const [integration] = $state.records.filter(
        record => record.id === integrationId
      );
      return integration || defaultValue;
    },
  getUIFlags($state) {
    return $state.uiFlags;
  },
};

export const actions = {
  get: async ({ commit }) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isFetching: true });
    try {
      const response = await IntegrationsAPI.get();
      commit(types.default.SET_INTEGRATIONS, response.data.payload);
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isFetching: false });
    } catch (error) {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isFetching: false });
    }
  },

  connectSlack: async ({ commit }, code) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isCreatingSlack: true });
    try {
      const response = await IntegrationsAPI.connectSlack(code);
      commit(types.default.ADD_INTEGRATION, response.data);
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, {
        isCreatingSlack: false,
      });
    }
  },
  updateSlack: async ({ commit }, slackObj) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isUpdatingSlack: true });
    try {
      const response = await IntegrationsAPI.updateSlack(slackObj);
      commit(types.default.ADD_INTEGRATION, response.data);
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, {
        isUpdatingSlack: false,
      });
    }
  },
  listAllSlackChannels: async ({ commit }) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, {
      isFetchingSlackChannels: true,
    });
    try {
      const response = await IntegrationsAPI.listAllSlackChannels();
      return response.data;
    } catch (error) {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, {
        isFetchingSlackChannels: false,
      });
    }
    return null;
  },

  deleteIntegration: async ({ commit }, integrationId) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isDeleting: true });
    try {
      await IntegrationsAPI.delete(integrationId);
      commit(types.default.DELETE_INTEGRATION, {
        id: integrationId,
        enabled: false,
      });
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isDeleting: false });
    } catch (error) {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isDeleting: false });
    }
  },
  showHook: async ({ commit }, hookId) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isFetchingItem: true });
    try {
      const response = await IntegrationsAPI.showHook(hookId);
      commit(types.default.ADD_INTEGRATION_HOOKS, response.data);
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isFetchingItem: false });
    } catch (error) {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isFetchingItem: false });
      throw normalizeApiError(error);
    }
  },
  createHook: async ({ commit }, hookData) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isCreatingHook: true });
    try {
      const response = await IntegrationsAPI.createHook(hookData);
      commit(types.default.ADD_INTEGRATION_HOOKS, response.data);
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isCreatingHook: false });
    } catch (error) {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isCreatingHook: false });
      throw normalizeApiError(error);
    }
  },
  updateHook: async ({ commit }, { hookId, hookData }) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isUpdatingHook: true });
    try {
      const response = await IntegrationsAPI.updateHook(hookId, hookData);
      commit(types.default.ADD_INTEGRATION_HOOKS, response.data);
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isUpdatingHook: false });
    } catch (error) {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isUpdatingHook: false });
      throw normalizeApiError(error);
    }
  },
  deleteHook: async ({ commit }, { appId, hookId }) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isDeletingHook: true });
    try {
      await IntegrationsAPI.deleteHook(hookId);
      commit(types.default.DELETE_INTEGRATION_HOOKS, { appId, hookId });
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isDeletingHook: false });
    } catch (error) {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isDeletingHook: false });
      throw normalizeApiError(error);
    }
  },
  runHookSync: async ({ commit }, payload) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, { isRunningHookSync: true });
    try {
      const hookId = typeof payload === 'object' ? payload.hookId : payload;
      const phases = typeof payload === 'object' ? payload.phases : undefined;
      const response = await IntegrationsAPI.runHookSync(hookId, {
        ...(phases?.length ? { phases } : {}),
      });
      return response.data;
    } finally {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, {
        isRunningHookSync: false,
      });
    }
  },
  getHookSyncStatus: async (_, payload) => {
    const hookId = typeof payload === 'object' ? payload.hookId : payload;
    const conflictPage =
      typeof payload === 'object' ? payload.conflictPage : undefined;
    const response = await IntegrationsAPI.getHookSyncStatus(hookId, {
      ...(conflictPage ? { conflict_page: conflictPage } : {}),
      ...(typeof payload === 'object' ? payload.filters : {}),
    });
    return response.data;
  },
  updateHookSyncConflict: async (_, { hookId, conflictId, resolution }) => {
    const response = await IntegrationsAPI.updateHookSyncConflict(hookId, {
      conflict_id: conflictId,
      resolution,
    });
    return response.data;
  },
  resolveHookSyncConflict: async (_, { hookId, conflictId, ...resolution }) => {
    const response = await IntegrationsAPI.resolveHookSyncConflict(hookId, {
      conflict_id: conflictId,
      ...resolution,
    });
    return response.data;
  },
  importHookCatalog: async ({ commit }, { hookId, file }) => {
    commit(types.default.SET_INTEGRATIONS_UI_FLAG, {
      isImportingHookCatalog: true,
    });
    try {
      const response = await IntegrationsAPI.importHookCatalog(hookId, file);
      return response.data;
    } finally {
      commit(types.default.SET_INTEGRATIONS_UI_FLAG, {
        isImportingHookCatalog: false,
      });
    }
  },
};

export const mutations = {
  [types.default.SET_INTEGRATIONS_UI_FLAG]($state, uiFlag) {
    $state.uiFlags = { ...$state.uiFlags, ...uiFlag };
  },
  [types.default.SET_INTEGRATIONS]: MutationHelpers.set,
  [types.default.ADD_INTEGRATION]: MutationHelpers.updateAttributes,
  [types.default.DELETE_INTEGRATION]: MutationHelpers.updateAttributes,
  [types.default.ADD_INTEGRATION_HOOKS]: ($state, data) => {
    $state.records = $state.records.map(record => {
      if (record.id === data.app_id) {
        const hooks = record.hooks.some(hook => hook.id === data.id)
          ? record.hooks.map(hook => (hook.id === data.id ? data : hook))
          : [...record.hooks, data];

        return {
          ...record,
          hooks,
          enabled: hooks.some(hook => hook.status),
        };
      }
      return record;
    });
  },
  [types.default.DELETE_INTEGRATION_HOOKS]: ($state, { appId, hookId }) => {
    $state.records = $state.records.map(record => {
      if (record.id === appId) {
        const hooks = record.hooks.filter(hook => hook.id !== hookId);

        return {
          ...record,
          hooks,
          enabled: hooks.some(hook => hook.status),
        };
      }
      return record;
    });
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
