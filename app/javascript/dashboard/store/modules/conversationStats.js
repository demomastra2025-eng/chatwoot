import types from '../mutation-types';
import ConversationApi from '../../api/inbox/conversation';
import CommunicationThreadApi from '../../api/inbox/communicationThread';

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

// Bumped whenever newer stats are known (a new request starts or `set` is called),
// so a response that was requested before that can no longer overwrite them.
let conversationStatsRequestGeneration = 0;

// Every refresh request goes through this one trailing debounce: a burst of events, or the same
// event seen by several components, ends in a single /meta request. The wait grows with the
// account size to spare the server on big inboxes.
const refreshTiming = (allCount, isRealtime) => {
  if (isRealtime) return { wait: 75, maxWait: 500 };
  if (allCount > 2000) return { wait: 10000, maxWait: 20000 };
  if (allCount > 100) return { wait: 5000, maxWait: 10000 };
  return { wait: 1500, maxWait: 5000 };
};

const refreshScheduler = {
  context: null,
  params: undefined,
  timer: null,
  firstRequestedAt: null,
  isInFlight: false,
  runAgain: false,
  refreshOnVisible: false,
  isRealtime: false,
};

const isTabHidden = () =>
  typeof document !== 'undefined' && document.visibilityState === 'hidden';

export const getters = {
  getStats: $state => $state,
};

const fetchMetaData = async (context, params, requestGeneration) => {
  try {
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
    if (meta?.unread_counts) {
      commit(types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS, meta.unread_counts, {
        root: true,
      });
    }
  } catch (error) {
    // ignore
  }
};

const runMetaRefresh = async () => {
  refreshScheduler.timer = null;
  refreshScheduler.firstRequestedAt = null;
  // A hidden tab does not poll the server on events; it refreshes once when it is shown again.
  if (isTabHidden()) {
    refreshScheduler.refreshOnVisible = true;
    return;
  }
  if (refreshScheduler.isInFlight) {
    refreshScheduler.runAgain = true;
    return;
  }

  refreshScheduler.isInFlight = true;
  conversationStatsRequestGeneration += 1;
  const { context, params } = refreshScheduler;
  refreshScheduler.isRealtime = false;
  try {
    await fetchMetaData(context, params, conversationStatsRequestGeneration);
  } finally {
    refreshScheduler.isInFlight = false;
    if (refreshScheduler.runAgain) {
      refreshScheduler.runAgain = false;
      // eslint-disable-next-line no-use-before-define
      scheduleMetaRefresh(
        refreshScheduler.context,
        refreshScheduler.params,
        refreshScheduler.isRealtime
      );
    }
  }
};

const scheduleMetaRefresh = (context, params, isRealtime = false) => {
  refreshScheduler.context = context;
  refreshScheduler.params = params;
  refreshScheduler.isRealtime ||= isRealtime;
  clearTimeout(refreshScheduler.timer);
  refreshScheduler.timer = null;
  if (isTabHidden()) {
    refreshScheduler.refreshOnVisible = true;
    return;
  }

  const now = Date.now();
  if (refreshScheduler.firstRequestedAt === null) {
    refreshScheduler.firstRequestedAt = now;
  }
  const { wait, maxWait } = refreshTiming(
    context?.state?.allCount ?? 0,
    refreshScheduler.isRealtime
  );
  const delay = Math.max(
    0,
    Math.min(wait, refreshScheduler.firstRequestedAt + maxWait - now)
  );
  refreshScheduler.timer = setTimeout(runMetaRefresh, delay);
};

const onVisibilityChange = () => {
  if (isTabHidden() || !refreshScheduler.refreshOnVisible) return;

  refreshScheduler.refreshOnVisible = false;
  clearTimeout(refreshScheduler.timer);
  runMetaRefresh();
};

if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', onVisibilityChange);
}

// Drops any pending refresh. Used by the unit tests to isolate the module level scheduler.
export const resetMetaRefresh = () => {
  clearTimeout(refreshScheduler.timer);
  Object.assign(refreshScheduler, {
    context: null,
    params: undefined,
    timer: null,
    firstRequestedAt: null,
    isInFlight: false,
    runAgain: false,
    refreshOnVisible: false,
    isRealtime: false,
  });
  conversationStatsRequestGeneration += 1;
};

export const actions = {
  get: async (context, params) => {
    const { refreshPriority, ...filters } = params || {};
    scheduleMetaRefresh(context, filters, refreshPriority === 'realtime');
  },
  // Exact stats that arrive together with a list. They invalidate a response that is still on its
  // way (it was requested earlier), but never cancel a refresh that is waiting to run.
  set({ commit }, meta) {
    conversationStatsRequestGeneration += 1;
    if (refreshScheduler.isInFlight) refreshScheduler.runAgain = true;
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
