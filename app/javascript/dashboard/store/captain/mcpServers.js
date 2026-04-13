import CaptainMcpServers from 'dashboard/api/captain/mcpServers';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainMcpServer',
  API: CaptainMcpServers,
  actions: mutations => ({
    testServer: async ({ commit }, payload) => {
      commit(mutations.SET_UI_FLAG, { testingServer: true });
      try {
        const response = await CaptainMcpServers.test(payload);
        commit(mutations.SET_UI_FLAG, { testingServer: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { testingServer: false });
        return throwErrorMessage(error);
      }
    },
    getSurface: async ({ commit }, { id }) => {
      commit(mutations.SET_UI_FLAG, { fetchingSurface: true });
      try {
        const response = await CaptainMcpServers.surface(id);
        commit(mutations.SET_UI_FLAG, { fetchingSurface: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { fetchingSurface: false });
        return throwErrorMessage(error);
      }
    },
    readResource: async ({ commit }, { id, uri }) => {
      commit(mutations.SET_UI_FLAG, { performingSurfaceAction: true });
      try {
        const response = await CaptainMcpServers.readResource(id, { uri });
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return throwErrorMessage(error);
      }
    },
    fetchResourceTemplate: async (
      { commit },
      { id, name, arguments: templateArguments }
    ) => {
      commit(mutations.SET_UI_FLAG, { performingSurfaceAction: true });
      try {
        const response = await CaptainMcpServers.fetchResourceTemplate(id, {
          name,
          arguments: templateArguments,
        });
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return throwErrorMessage(error);
      }
    },
    fetchPrompt: async (
      { commit },
      { id, name, arguments: promptArguments }
    ) => {
      commit(mutations.SET_UI_FLAG, { performingSurfaceAction: true });
      try {
        const response = await CaptainMcpServers.fetchPrompt(id, {
          name,
          arguments: promptArguments,
        });
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return throwErrorMessage(error);
      }
    },
    taskGet: async ({ commit }, { id, taskId }) => {
      commit(mutations.SET_UI_FLAG, { performingSurfaceAction: true });
      try {
        const response = await CaptainMcpServers.taskGet(id, { taskId });
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return throwErrorMessage(error);
      }
    },
    taskResult: async ({ commit }, { id, taskId }) => {
      commit(mutations.SET_UI_FLAG, { performingSurfaceAction: true });
      try {
        const response = await CaptainMcpServers.taskResult(id, { taskId });
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return throwErrorMessage(error);
      }
    },
    taskCancel: async ({ commit }, { id, taskId }) => {
      commit(mutations.SET_UI_FLAG, { performingSurfaceAction: true });
      try {
        const response = await CaptainMcpServers.taskCancel(id, { taskId });
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingSurfaceAction: false });
        return throwErrorMessage(error);
      }
    },
    startOAuth: async ({ commit }, { id, returnUrl }) => {
      commit(mutations.SET_UI_FLAG, { performingOAuth: true });
      try {
        const response = await CaptainMcpServers.startOAuth(id, { returnUrl });
        commit(mutations.SET_UI_FLAG, { performingOAuth: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingOAuth: false });
        return throwErrorMessage(error);
      }
    },
    disconnectOAuth: async ({ commit }, { id }) => {
      commit(mutations.SET_UI_FLAG, { performingOAuth: true });
      try {
        const response = await CaptainMcpServers.disconnectOAuth(id);
        commit(mutations.SET_UI_FLAG, { performingOAuth: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { performingOAuth: false });
        return throwErrorMessage(error);
      }
    },
  }),
});
