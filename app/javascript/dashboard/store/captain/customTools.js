import CaptainCustomTools from 'dashboard/api/captain/customTools';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainCustomTool',
  API: CaptainCustomTools,
  actions: mutations => ({
    update: async ({ commit }, { id, ...updateObj }) => {
      commit(mutations.SET_UI_FLAG, { updatingItem: true });
      try {
        const response = await CaptainCustomTools.update(id, updateObj);
        commit(mutations.EDIT, response.data);
        commit(mutations.SET_UI_FLAG, { updatingItem: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { updatingItem: false });
        return throwErrorMessage(error);
      }
    },

    delete: async ({ commit }, id) => {
      commit(mutations.SET_UI_FLAG, { deletingItem: true });
      try {
        await CaptainCustomTools.delete(id);
        commit(mutations.DELETE, id);
        commit(mutations.SET_UI_FLAG, { deletingItem: false });
        return id;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { deletingItem: false });
        return throwErrorMessage(error);
      }
    },

    previewTool: async ({ commit }, payload) => {
      commit(mutations.SET_UI_FLAG, { previewingTool: true });
      try {
        const response = await CaptainCustomTools.preview(payload);
        commit(mutations.SET_UI_FLAG, { previewingTool: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { previewingTool: false });
        return throwErrorMessage(error);
      }
    },

    testTool: async ({ commit }, payload) => {
      commit(mutations.SET_UI_FLAG, { testingTool: true });
      try {
        const response = await CaptainCustomTools.test(payload);
        commit(mutations.SET_UI_FLAG, { testingTool: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { testingTool: false });
        return throwErrorMessage(error);
      }
    },
  }),
});
