import CaptainDocumentAPI from 'dashboard/api/captain/document';
import { createStore } from '../storeFactory';

export default createStore({
  name: 'CaptainDocument',
  API: CaptainDocumentAPI,
  actions: mutationTypes => ({
    async preview({ commit }, payload) {
      commit(mutationTypes.SET_UI_FLAG, { previewingItem: true });
      try {
        const response = await CaptainDocumentAPI.preview(payload);
        return response.data;
      } finally {
        commit(mutationTypes.SET_UI_FLAG, { previewingItem: false });
      }
    },
    async resync({ commit }, id) {
      commit(mutationTypes.SET_UI_FLAG, { updatingItem: true });
      try {
        const response = await CaptainDocumentAPI.resync(id);
        commit(mutationTypes.UPSERT, response.data);
        return response.data;
      } finally {
        commit(mutationTypes.SET_UI_FLAG, { updatingItem: false });
      }
    },
    async refreshChangedOnly({ commit }, id) {
      commit(mutationTypes.SET_UI_FLAG, { updatingItem: true });
      try {
        const response = await CaptainDocumentAPI.refreshChangedOnly(id);
        commit(mutationTypes.UPSERT, response.data);
        return response.data;
      } finally {
        commit(mutationTypes.SET_UI_FLAG, { updatingItem: false });
      }
    },
    async retryFailed({ commit }, id) {
      commit(mutationTypes.SET_UI_FLAG, { updatingItem: true });
      try {
        const response = await CaptainDocumentAPI.retryFailed(id);
        commit(mutationTypes.UPSERT, response.data);
        return response.data;
      } finally {
        commit(mutationTypes.SET_UI_FLAG, { updatingItem: false });
      }
    },
    removeBulkRecords({ commit, getters }, ids) {
      const records = getters.getRecords.filter(
        record => !ids.includes(record.id)
      );
      commit(mutationTypes.SET, records);
    },
  }),
});
