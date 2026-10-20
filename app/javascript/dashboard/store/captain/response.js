import CaptainResponseAPI from 'dashboard/api/captain/response';
import { createStore } from '../storeFactory';

const SET_PENDING_COUNT = 'SET_PENDING_COUNT';

export default createStore({
  name: 'CaptainResponse',
  API: CaptainResponseAPI,
  getters: {
    getPendingCount: state => state.meta.pendingCount || 0,
  },
  mutations: {
    [SET_PENDING_COUNT](state, count) {
      state.meta = {
        ...state.meta,
        pendingCount: Number(count),
      };
    },
  },
  actions: mutations => ({
    removeBulkResponses: ({ commit, state }, ids) => {
      const updatedRecords = state.records.filter(
        record => !ids.includes(record.id)
      );
      commit(mutations.SET, updatedRecords);
    },
    updateBulkResponses: ({ commit, state }, payload) => {
      const isObjectPayload =
        payload && !Array.isArray(payload) && typeof payload === 'object';
      const approvedResponses = isObjectPayload
        ? payload.responses || []
        : payload || [];
      const consumedIds = isObjectPayload ? payload.consumedIds || [] : [];

      const updatedResponsesMap = approvedResponses.reduce((map, response) => {
        map[response.id] = response;
        return map;
      }, {});
      const dropIds = new Set(
        consumedIds.filter(id => !updatedResponsesMap[id])
      );

      const updatedRecords = state.records
        .filter(record => !dropIds.has(record.id))
        .map(record => updatedResponsesMap[record.id] || record);

      commit(mutations.SET, updatedRecords);
    },
    fetchPendingCount: async ({ commit }, assistantId) => {
      try {
        const response = await CaptainResponseAPI.get({
          status: 'pending',
          page: 1,
          assistantId,
        });
        const count = response.data?.meta?.total_count || 0;
        commit(SET_PENDING_COUNT, count);
      } catch (error) {
        commit(SET_PENDING_COUNT, 0);
      }
    },
  }),
});
