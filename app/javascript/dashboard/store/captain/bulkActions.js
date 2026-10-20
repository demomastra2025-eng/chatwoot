import CaptainBulkActionsAPI from 'dashboard/api/captain/bulkActions';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainBulkAction',
  API: CaptainBulkActionsAPI,
  actions: mutations => ({
    processBulkAction: async function processBulkAction(
      { commit },
      { type, actionType, ids }
    ) {
      commit(mutations.SET_UI_FLAG, { isUpdating: true });
      try {
        const response = await CaptainBulkActionsAPI.create({
          type: type,
          ids,
          fields: { status: actionType },
        });
        commit(mutations.SET_UI_FLAG, { isUpdating: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { isUpdating: false });
        return throwErrorMessage(error);
      }
    },

    handleBulkDelete: async function handleBulkDelete(
      { dispatch },
      { type = 'AssistantResponse', ids }
    ) {
      const response = await dispatch('processBulkAction', {
        type,
        actionType: 'delete',
        ids,
      });

      if (type === 'AssistantResponse') {
        await dispatch('captainResponses/removeBulkResponses', ids, {
          root: true,
        });
      } else if (type === 'AssistantDocument') {
        await dispatch('captainDocuments/removeBulkRecords', ids, {
          root: true,
        });
      }
      return response;
    },

    handleBulkApprove: async function handleBulkApprove({ dispatch }, ids) {
      const response = await dispatch('processBulkAction', {
        type: 'AssistantResponse',
        actionType: 'approve',
        ids,
      });

      await dispatch(
        'captainResponses/updateBulkResponses',
        { responses: response, consumedIds: ids },
        { root: true }
      );
      return response;
    },

    handleBulkMerge: async function handleBulkMerge({ dispatch }, ids) {
      const response = await dispatch('processBulkAction', {
        type: 'AssistantResponse',
        actionType: 'merge',
        ids,
      });

      await dispatch(
        'captainResponses/updateBulkResponses',
        { responses: response, consumedIds: ids },
        { root: true }
      );
      return response;
    },
  }),
});
