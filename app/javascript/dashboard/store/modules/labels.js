import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import types from '../mutation-types';
import LabelsAPI from '../../api/labels';
import AnalyticsHelper from '../../helper/AnalyticsHelper';
import { LABEL_EVENTS } from '../../helper/AnalyticsHelper/events';
import { sortLabelsByDisplayTitle } from '../../helper/labels';

export const state = {
  records: [],
  uiFlags: {
    isFetching: false,
    isFetchingItem: false,
    isCreating: false,
    isDeleting: false,
  },
};

export const getters = {
  getLabels(_state) {
    return _state.records;
  },
  getUIFlags(_state) {
    return _state.uiFlags;
  },
  getLabelsOnSidebar(_state) {
    return sortLabelsByDisplayTitle(_state.records);
  },
  getLabelById: _state => id => {
    return _state.records.find(record => record.id === Number(id)) || {};
  },
};

const currentRouteAccountId = () => LabelsAPI.accountIdFromRoute;
const isCurrentRouteAccountId = accountId =>
  String(LabelsAPI.accountIdFromRoute) === String(accountId);

export const actions = {
  revalidate: async function revalidate({ commit }, { newKey }) {
    const accountId = currentRouteAccountId();
    try {
      const isExistingKeyValid = await LabelsAPI.validateCacheKey(
        newKey,
        accountId
      );
      if (!isExistingKeyValid) {
        const response = await LabelsAPI.refetchAndCommit(newKey, accountId);
        if (!isCurrentRouteAccountId(accountId)) return;

        commit(types.SET_LABELS, response.data.payload);
      }
    } catch (error) {
      // Ignore error
    }
  },

  get: async function getLabels({ commit }) {
    const accountId = currentRouteAccountId();
    commit(types.SET_LABEL_UI_FLAG, { isFetching: true });
    try {
      const response = await LabelsAPI.get(true);
      if (!isCurrentRouteAccountId(accountId)) return;

      const sortedLabels = sortLabelsByDisplayTitle(response.data.payload);
      commit(types.SET_LABELS, sortedLabels);
    } catch (error) {
      // Ignore error
    } finally {
      if (isCurrentRouteAccountId(accountId)) {
        commit(types.SET_LABEL_UI_FLAG, { isFetching: false });
      }
    }
  },

  create: async function createLabels({ commit }, cannedObj) {
    commit(types.SET_LABEL_UI_FLAG, { isCreating: true });
    try {
      const response = await LabelsAPI.create(cannedObj);
      AnalyticsHelper.track(LABEL_EVENTS.CREATE);
      commit(types.ADD_LABEL, response.data);
    } catch (error) {
      const errorMessage = error?.response?.data?.message;
      throw new Error(errorMessage);
    } finally {
      commit(types.SET_LABEL_UI_FLAG, { isCreating: false });
    }
  },

  update: async function updateLabels({ commit }, { id, ...updateObj }) {
    commit(types.SET_LABEL_UI_FLAG, { isUpdating: true });
    try {
      const response = await LabelsAPI.update(id, updateObj);
      AnalyticsHelper.track(LABEL_EVENTS.UPDATE);
      commit(types.EDIT_LABEL, response.data);
    } catch (error) {
      throw new Error(error);
    } finally {
      commit(types.SET_LABEL_UI_FLAG, { isUpdating: false });
    }
  },

  delete: async function deleteLabels({ commit }, id) {
    commit(types.SET_LABEL_UI_FLAG, { isDeleting: true });
    try {
      await LabelsAPI.delete(id);
      AnalyticsHelper.track(LABEL_EVENTS.DELETED);
      commit(types.DELETE_LABEL, id);
    } catch (error) {
      throw new Error(error);
    } finally {
      commit(types.SET_LABEL_UI_FLAG, { isDeleting: false });
    }
  },
};

export const mutations = {
  [types.SET_LABEL_UI_FLAG](_state, data) {
    _state.uiFlags = {
      ..._state.uiFlags,
      ...data,
    };
  },

  [types.SET_LABELS]: MutationHelpers.set,
  [types.ADD_LABEL]: MutationHelpers.create,
  [types.EDIT_LABEL]: MutationHelpers.update,
  [types.DELETE_LABEL]: MutationHelpers.destroy,
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
