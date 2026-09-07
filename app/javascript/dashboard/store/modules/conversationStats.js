import types from '../mutation-types';
import ConversationApi from '../../api/inbox/conversation';
import CommunicationThreadApi from '../../api/inbox/communicationThread';
import { debounce } from '@chatwoot/utils';

const state = {
  mineCount: 0,
  unAssignedCount: 0,
  allCount: 0,
  assigneeCounts: {
    mine: 0,
    assigned: 0,
    unassigned: 0,
    all: 0,
  },
  mineUnreadCount: 0,
  unAssignedUnreadCount: 0,
  assignedUnreadCount: 0,
  allUnreadCount: 0,
};

let conversationStatsRequestGeneration = 0;

export const getters = {
  getStats: $state => $state,
};

// Create a debounced version of the actual API call function
const fetchMetaData = async (context, params, requestGeneration) => {
  try {
    if (requestGeneration !== conversationStatsRequestGeneration) return;

    const { commit } = context;
    const statsApi = params?.communicationThreadMode
      ? CommunicationThreadApi
      : ConversationApi;
    const response = await statsApi.meta(params);
    if (requestGeneration !== conversationStatsRequestGeneration) return;

    const {
      data: { meta },
    } = response;
    commit(types.SET_CONV_TAB_META, meta);
  } catch (error) {
    // ignore
  }
};

const debouncedFetchMetaData = debounce(fetchMetaData, 1500, false, 5000);
const longDebouncedFetchMetaData = debounce(fetchMetaData, 5000, false, 10000);
const superLongDebouncedFetchMetaData = debounce(
  fetchMetaData,
  10000,
  false,
  20000
);

export const actions = {
  get: async (context, params) => {
    const { state: $state } = context;
    conversationStatsRequestGeneration += 1;
    const requestGeneration = conversationStatsRequestGeneration;
    if ($state.allCount > 2000) {
      superLongDebouncedFetchMetaData(context, params, requestGeneration);
    } else if ($state.allCount > 100) {
      longDebouncedFetchMetaData(context, params, requestGeneration);
    } else {
      debouncedFetchMetaData(context, params, requestGeneration);
    }
  },
  set({ commit }, meta) {
    conversationStatsRequestGeneration += 1;
    commit(types.SET_CONV_TAB_META, meta);
  },
};

const toNumber = value => Number(value ?? 0);

const normalizeAssigneeCounts = (counts, fallback = {}) => {
  return {
    mine: toNumber(counts?.mine_count ?? counts?.mine ?? fallback.mine),
    assigned: toNumber(
      counts?.assigned_count ?? counts?.assigned ?? fallback.assigned
    ),
    unassigned: toNumber(
      counts?.unassigned_count ?? counts?.unassigned ?? fallback.unassigned
    ),
    all: toNumber(counts?.all_count ?? counts?.all ?? fallback.all),
  };
};

export const mutations = {
  [types.SET_CONV_TAB_META](
    $state,
    {
      mine_count: mineCount,
      unassigned_count: unAssignedCount,
      all_count: allCount,
      assigned_count: assignedCount,
      mine_unread_count: mineUnreadCount,
      unassigned_unread_count: unAssignedUnreadCount,
      assigned_unread_count: assignedUnreadCount,
      all_unread_count: allUnreadCount,
      assignee_counts: assigneeCounts,
    } = {}
  ) {
    $state.mineCount = toNumber(mineCount);
    $state.allCount = toNumber(allCount);
    $state.unAssignedCount = toNumber(unAssignedCount);
    $state.assigneeCounts = normalizeAssigneeCounts(assigneeCounts, {
      mine: mineCount,
      assigned: assignedCount,
      unassigned: unAssignedCount,
      all: allCount,
    });
    $state.mineUnreadCount = toNumber(mineUnreadCount);
    $state.unAssignedUnreadCount = toNumber(unAssignedUnreadCount);
    $state.assignedUnreadCount = toNumber(assignedUnreadCount);
    $state.allUnreadCount = toNumber(allUnreadCount);
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
