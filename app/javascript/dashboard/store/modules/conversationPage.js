import * as types from '../mutation-types';

const state = {
  currentPage: {
    me: 0,
    unassigned: 0,
    all: 0,
    appliedFilters: 0,
  },
  hasEndReached: {
    me: false,
    unassigned: false,
    all: false,
  },
  totalCount: {
    me: 0,
    unassigned: 0,
    all: 0,
    appliedFilters: 0,
  },
};

export const getters = {
  getHasEndReached: $state => filter => {
    return Boolean($state.hasEndReached[filter]);
  },
  getCurrentPageFilter: $state => filter => {
    return Number($state.currentPage[filter] || 0);
  },
  getCurrentPage: $state => {
    return $state.currentPage;
  },
  getTotalCount: $state => filter => {
    return $state.totalCount[filter] || 0;
  },
};

export const actions = {
  setCurrentPage({ commit }, { filter, page }) {
    commit(types.default.SET_CURRENT_PAGE, { filter, page });
  },
  setEndReached({ commit }, { filter }) {
    commit(types.default.SET_CONVERSATION_END_REACHED, { filter });
  },
  setTotalCount({ commit }, { filter, count }) {
    commit(types.default.SET_CONVERSATION_TOTAL_COUNT, { filter, count });
  },
  reset({ commit }) {
    commit(types.default.CLEAR_CONVERSATION_PAGE);
  },
};

export const mutations = {
  [types.default.SET_CURRENT_PAGE]: ($state, { filter, page }) => {
    $state.currentPage = {
      ...$state.currentPage,
      [filter]: page,
    };
  },
  [types.default.SET_CONVERSATION_END_REACHED]: ($state, { filter }) => {
    if (filter === 'all') {
      $state.hasEndReached = {
        ...$state.hasEndReached,
        unassigned: true,
        me: true,
      };
    }
    $state.hasEndReached = {
      ...$state.hasEndReached,
      [filter]: true,
    };
  },
  [types.default.SET_CONVERSATION_TOTAL_COUNT]: ($state, { filter, count }) => {
    $state.totalCount = {
      ...$state.totalCount,
      [filter]: Number(count || 0),
    };
  },
  [types.default.CLEAR_CONVERSATION_PAGE]: $state => {
    $state.currentPage = {
      me: 0,
      unassigned: 0,
      all: 0,
      appliedFilters: 0,
    };

    $state.hasEndReached = {
      me: false,
      unassigned: false,
      all: false,
      appliedFilters: false,
    };
    $state.totalCount = {
      me: 0,
      unassigned: 0,
      all: 0,
      appliedFilters: 0,
    };
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
