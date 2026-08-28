import types from '../mutation-types';
import BulkActionsAPI from '../../api/bulkActions';

const waitFor = delay =>
  new Promise(resolve => {
    setTimeout(resolve, delay);
  });

export const state = {
  selectedConversationIds: [],
  uiFlags: {
    isUpdating: false,
  },
  currentBulkActionRun: null,
  serverSelection: null,
};

export const getters = {
  getUIFlags(_state) {
    return _state.uiFlags;
  },
  getSelectedConversationIds(_state) {
    return _state.selectedConversationIds;
  },
  getCurrentBulkActionRun(_state) {
    return _state.currentBulkActionRun;
  },
  getServerSelection(_state) {
    return _state.serverSelection;
  },
};

export const actions = {
  process: async function processAction(
    { commit, dispatch, state: $state = {} },
    payload
  ) {
    commit(types.SET_BULK_ACTIONS_FLAG, { isUpdating: true });
    commit(types.SET_BULK_ACTION_RUN, null);
    try {
      const {
        data: { payload: bulkActionRun },
      } = await BulkActionsAPI.create(
        $state.serverSelection
          ? { ...payload, ids: [], selection: $state.serverSelection }
          : payload
      );
      commit(types.SET_BULK_ACTION_RUN, bulkActionRun);
      return await dispatch('pollRunStatus', bulkActionRun.id);
    } finally {
      commit(types.SET_BULK_ACTIONS_FLAG, { isUpdating: false });
    }
  },
  pollRunStatus: async function pollRunStatus({ commit }, id) {
    const poll = async attempt => {
      const {
        data: { payload: bulkActionRun },
      } = await BulkActionsAPI.show(id);
      commit(types.SET_BULK_ACTION_RUN, bulkActionRun);

      if (bulkActionRun.status === 'completed') {
        return bulkActionRun;
      }

      if (bulkActionRun.status === 'failed') {
        const error = new Error(
          bulkActionRun.error_message || 'Bulk action failed'
        );
        error.failedCount = Number(bulkActionRun.failed_count || 0);
        throw error;
      }

      if (attempt >= 239) {
        throw new Error('Bulk action status polling timed out');
      }

      await waitFor(750);
      return poll(attempt + 1);
    };

    return poll(0);
  },
  setSelectedConversationIds({ commit }, id) {
    commit(types.SET_SELECTED_CONVERSATION_IDS, id);
  },
  removeSelectedConversationIds({ commit }, id) {
    commit(types.REMOVE_SELECTED_CONVERSATION_IDS, id);
  },
  clearSelectedConversationIds({ commit }) {
    commit(types.CLEAR_SELECTED_CONVERSATION_IDS);
    commit(types.SET_BULK_SELECTION, null);
  },
  setServerSelection({ commit }, selection) {
    commit(types.SET_BULK_SELECTION, selection);
  },
  clearCurrentBulkActionRun({ commit }) {
    commit(types.SET_BULK_ACTION_RUN, null);
  },
};

export const mutations = {
  [types.SET_BULK_ACTIONS_FLAG](_state, data) {
    _state.uiFlags = {
      ..._state.uiFlags,
      ...data,
    };
  },
  [types.SET_SELECTED_CONVERSATION_IDS](_state, ids) {
    // Check if ids is an array, if not, convert it to an array
    const idsArray = Array.isArray(ids) ? ids : [ids];

    // Concatenate the new IDs ensuring no duplicates
    _state.selectedConversationIds = [
      ...new Set([..._state.selectedConversationIds, ...idsArray]),
    ];
  },
  [types.REMOVE_SELECTED_CONVERSATION_IDS](_state, id) {
    _state.selectedConversationIds = _state.selectedConversationIds.filter(
      item => item !== id
    );
  },
  [types.CLEAR_SELECTED_CONVERSATION_IDS](_state) {
    _state.selectedConversationIds = [];
  },
  [types.SET_BULK_ACTION_RUN](_state, bulkActionRun) {
    _state.currentBulkActionRun = bulkActionRun;
  },
  [types.SET_BULK_SELECTION](_state, selection) {
    _state.serverSelection = selection;
  },
};

export default {
  namespaced: true,
  actions,
  state,
  getters,
  mutations,
};
