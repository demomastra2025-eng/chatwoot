import types from '../mutation-types';
import ConversationApi from '../../api/inbox/conversation';
import CommunicationThreadApi from '../../api/inbox/communicationThread';
import { debounce } from '@chatwoot/utils';

const state = {
  mineCount: 0,
  unAssignedCount: 0,
  allCount: 0,
  mineUnreadCount: 0,
  unAssignedUnreadCount: 0,
  assignedUnreadCount: 0,
  allUnreadCount: 0,
};

export const getters = {
  getStats: $state => $state,
};

// Create a debounced version of the actual API call function
const fetchMetaData = async (commit, params) => {
  try {
    const statsApi = params?.communicationThreadMode
      ? CommunicationThreadApi
      : ConversationApi;
    const response = await statsApi.meta(params);
    const {
      data: { meta },
    } = response;
    commit(types.SET_CONV_TAB_META, meta);
  } catch (error) {
    // ignore
  }
};

const debouncedFetchMetaData = debounce(fetchMetaData, 500, false, 2000);
const longDebouncedFetchMetaData = debounce(fetchMetaData, 5000, false, 10000);
const superLongDebouncedFetchMetaData = debounce(
  fetchMetaData,
  10000,
  false,
  20000
);

export const actions = {
  get: async ({ commit, state: $state }, params) => {
    if ($state.allCount > 2000) {
      superLongDebouncedFetchMetaData(commit, params);
    } else if ($state.allCount > 100) {
      longDebouncedFetchMetaData(commit, params);
    } else {
      debouncedFetchMetaData(commit, params);
    }
  },
  set({ commit }, meta) {
    commit(types.SET_CONV_TAB_META, meta);
  },
};

export const mutations = {
  [types.SET_CONV_TAB_META](
    $state,
    {
      mine_count: mineCount,
      unassigned_count: unAssignedCount,
      all_count: allCount,
      mine_unread_count: mineUnreadCount,
      unassigned_unread_count: unAssignedUnreadCount,
      assigned_unread_count: assignedUnreadCount,
      all_unread_count: allUnreadCount,
    } = {}
  ) {
    $state.mineCount = Number(mineCount ?? 0);
    $state.allCount = Number(allCount ?? 0);
    $state.unAssignedCount = Number(unAssignedCount ?? 0);
    $state.mineUnreadCount = Number(mineUnreadCount ?? 0);
    $state.unAssignedUnreadCount = Number(unAssignedUnreadCount ?? 0);
    $state.assignedUnreadCount = Number(assignedUnreadCount ?? 0);
    $state.allUnreadCount = Number(allUnreadCount ?? 0);
    $state.updatedOn = new Date();
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
