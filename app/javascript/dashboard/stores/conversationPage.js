import { defineStore } from 'pinia';

const initialState = () => ({
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
    appliedFilters: false,
  },
  totalCount: {
    me: 0,
    unassigned: 0,
    all: 0,
    appliedFilters: 0,
  },
});

export const useConversationPageStore = defineStore('conversationPage', {
  state: initialState,
  getters: {
    getCurrentPageFilter: state => filter =>
      Number(state.currentPage[filter] || 0),
    getHasEndReached: state => filter => Boolean(state.hasEndReached[filter]),
    getTotalCount: state => filter => state.totalCount[filter] || 0,
  },
  actions: {
    setCurrentPage({ filter, page }) {
      this.currentPage = {
        ...this.currentPage,
        [filter]: page,
      };
    },
    setEndReached({ filter }) {
      if (filter === 'all') {
        this.hasEndReached = {
          ...this.hasEndReached,
          unassigned: true,
          me: true,
        };
      }
      this.hasEndReached = {
        ...this.hasEndReached,
        [filter]: true,
      };
    },
    setTotalCount({ filter, count }) {
      this.totalCount = {
        ...this.totalCount,
        [filter]: Number(count || 0),
      };
    },
    reset() {
      Object.assign(this, initialState());
    },
  },
});
