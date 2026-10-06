import types from '../mutation-types';
import BulkActionsAPI from '../../api/bulkActions';

const statusUnavailableError = cause => {
  const error = new Error('Could not confirm bulk action result');
  error.code = 'bulk_action_status_unknown';
  if (cause) error.cause = cause;
  return error;
};

const isTerminalStatusError = error =>
  [401, 403, 404].includes(error?.response?.status);

export const state = {
  selectedConversationIds: [],
  allMatchingSelectionCount: 0,
  uiFlags: {
    isUpdating: false,
  },
  currentBulkActionRun: null,
};

export const getters = {
  getUIFlags(_state) {
    return _state.uiFlags;
  },
  getSelectedConversationIds(_state) {
    return _state.selectedConversationIds;
  },
  getSelectedConversationCount(_state) {
    return (
      _state.selectedConversationIds.length + _state.allMatchingSelectionCount
    );
  },
  getCurrentBulkActionRun(_state) {
    return _state.currentBulkActionRun;
  },
};

export const actions = {
  process: async function processAction({ commit, dispatch }, payload) {
    commit(types.SET_BULK_ACTIONS_FLAG, { isUpdating: true });
    commit(types.SET_BULK_ACTION_RUN, null);
    try {
      const context = BulkActionsAPI.captureContext();
      const {
        data: { payload: bulkActionRun },
      } = await BulkActionsAPI.create(payload, context);
      if (!BulkActionsAPI.isContextCurrent(context)) {
        commit(types.SET_BULK_ACTION_RUN, null);
        throw statusUnavailableError();
      }
      commit(types.SET_BULK_ACTION_RUN, bulkActionRun);
      return await dispatch('pollRunStatus', {
        id: bulkActionRun.id,
        context,
      });
    } catch (error) {
      // Keep Error instances intact so callers can read `failedCount`.
      if (error instanceof Error) throw error;
      throw new Error(error?.message || String(error));
    } finally {
      commit(types.SET_BULK_ACTIONS_FLAG, { isUpdating: false });
    }
  },
  pollRunStatus: function pollRunStatus({ commit }, run) {
    const id = typeof run === 'object' ? run.id : run;
    const context =
      typeof run === 'object' ? run.context : BulkActionsAPI.captureContext();
    return new Promise((resolve, reject) => {
      let attempt = 0;
      const scheduleNext = poll => {
        const delay = attempt < 240 ? 750 : 3000;
        attempt += 1;
        setTimeout(poll, delay);
      };

      const poll = async () => {
        if (!BulkActionsAPI.isContextCurrent(context)) {
          commit(types.SET_BULK_ACTION_RUN, null);
          reject(statusUnavailableError());
          return;
        }

        let bulkActionRun;
        try {
          ({
            data: { payload: bulkActionRun },
          } = await BulkActionsAPI.show(id, context));
        } catch (error) {
          if (
            !BulkActionsAPI.isContextCurrent(context) ||
            isTerminalStatusError(error)
          ) {
            commit(types.SET_BULK_ACTION_RUN, null);
            reject(statusUnavailableError(error));
            return;
          }

          // Network and server errors do not reveal whether the operation
          // finished. Keep checking while the account context is unchanged.
          scheduleNext(poll);
          return;
        }

        if (!BulkActionsAPI.isContextCurrent(context)) {
          commit(types.SET_BULK_ACTION_RUN, null);
          reject(statusUnavailableError());
          return;
        }

        commit(types.SET_BULK_ACTION_RUN, bulkActionRun);

        if (bulkActionRun.status === 'completed') {
          resolve(bulkActionRun);
          return;
        }

        if (bulkActionRun.status === 'failed') {
          const error = new Error(
            bulkActionRun.error_message || 'Bulk action failed'
          );
          error.failedCount = Number(bulkActionRun.failed_count || 0);
          error.skippedCount = Number(bulkActionRun.skipped_count || 0);
          error.doneCount = Number(bulkActionRun.done_count || 0);
          error.processedCount = Number(bulkActionRun.processed_count || 0);
          error.totalCount = Number(bulkActionRun.total_count || 0);
          reject(error);
          return;
        }

        scheduleNext(poll);
      };

      poll();
    });
  },
  setSelectedConversationIds({ commit }, id) {
    commit(types.SET_SELECTED_CONVERSATION_IDS, id);
  },
  removeSelectedConversationIds({ commit }, id) {
    commit(types.REMOVE_SELECTED_CONVERSATION_IDS, id);
  },
  clearSelectedConversationIds({ commit }) {
    commit(types.CLEAR_SELECTED_CONVERSATION_IDS);
    commit(types.SET_ALL_MATCHING_SELECTION_COUNT, 0);
  },
  setAllMatchingSelectionCount({ commit }, count) {
    commit(types.SET_ALL_MATCHING_SELECTION_COUNT, count);
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
  [types.SET_ALL_MATCHING_SELECTION_COUNT](_state, count) {
    _state.allMatchingSelectionCount = Math.max(0, Number(count) || 0);
  },
  [types.SET_BULK_ACTION_RUN](_state, bulkActionRun) {
    _state.currentBulkActionRun = bulkActionRun;
  },
};

export default {
  namespaced: true,
  actions,
  state,
  getters,
  mutations,
};
