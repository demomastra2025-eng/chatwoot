import axios from 'axios';
import { actions } from '../../integrations';
import types from '../../../mutation-types';
import integrationsList from './fixtures';

const commit = vi.fn();
global.axios = axios;
vi.mock('axios');

const errorMessage = { message: 'Incorrect header' };
describe('#actions', () => {
  describe('#get', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({ data: integrationsList });
      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isFetching: true }],
        [types.SET_INTEGRATIONS, integrationsList.payload],
        [types.SET_INTEGRATIONS_UI_FLAG, { isFetching: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue(errorMessage);
      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isFetching: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#connectSlack:', () => {
    it('sends correct actions if API is success', async () => {
      let data = { hooks: [{ id: 'slack', enabled: false }] };
      axios.post.mockResolvedValue({ data: data });
      await actions.connectSlack({ commit });
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingSlack: true }],
        [types.ADD_INTEGRATION, data],
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingSlack: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue(errorMessage);
      await expect(actions.connectSlack({ commit })).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingSlack: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingSlack: false }],
      ]);
    });
  });

  describe('#updateSlack', () => {
    it('sends correct actions if API is success', async () => {
      let data = { hooks: [{ id: 'slack', enabled: false }] };
      axios.patch.mockResolvedValue({ data: data });
      await actions.updateSlack({ commit }, { referenceId: '12345' });
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingSlack: true }],
        [types.ADD_INTEGRATION, data],
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingSlack: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue(errorMessage);
      await expect(actions.updateSlack({ commit })).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingSlack: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingSlack: false }],
      ]);
    });
  });

  describe('#deleteIntegration:', () => {
    it('sends correct actions if API is success', async () => {
      let data = { id: 'slack', enabled: false };
      axios.delete.mockResolvedValue({ data: data });
      await actions.deleteIntegration({ commit }, data.id);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeleting: true }],
        [types.DELETE_INTEGRATION, data],
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeleting: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue(errorMessage);
      await actions.deleteIntegration({ commit });
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeleting: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeleting: false }],
      ]);
    });
  });

  describe('#createHooks', () => {
    it('sends correct actions if API is success', async () => {
      let data = { id: 'slack', enabled: false };
      axios.post.mockResolvedValue({ data: data });
      await actions.createHook({ commit }, data);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingHook: true }],
        [types.ADD_INTEGRATION_HOOKS, data],
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingHook: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue(errorMessage);
      await expect(actions.createHook({ commit })).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingHook: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isCreatingHook: false }],
      ]);
    });
  });

  describe('#deleteHook', () => {
    it('sends correct actions if API is success', async () => {
      let data = { appId: 'dialogflow', hookId: 2 };
      axios.delete.mockResolvedValue({ data });
      await actions.deleteHook({ commit }, data);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeletingHook: true }],
        [types.DELETE_INTEGRATION_HOOKS, { appId: 'dialogflow', hookId: 2 }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeletingHook: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue(errorMessage);
      await expect(actions.deleteHook({ commit }, {})).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeletingHook: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isDeletingHook: false }],
      ]);
    });
  });

  describe('#updateHook', () => {
    it('sends correct actions if API is success', async () => {
      let data = { id: 2, app_id: 'webhook', status: true };
      axios.patch.mockResolvedValue({ data });
      await actions.updateHook({ commit }, { hookId: 2, hookData: data });
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingHook: true }],
        [types.ADD_INTEGRATION_HOOKS, data],
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingHook: false }],
      ]);
    });

    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue(errorMessage);
      await expect(
        actions.updateHook({ commit }, { hookId: 2, hookData: {} })
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingHook: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isUpdatingHook: false }],
      ]);
    });
  });

  describe('#runHookSync', () => {
    it('sends correct actions if API is success', async () => {
      const data = { message: 'queued' };
      axios.post.mockResolvedValue({ data });
      await expect(actions.runHookSync({ commit }, 2)).resolves.toEqual(data);
      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/2/run_sync'),
        {}
      );
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isRunningHookSync: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isRunningHookSync: false }],
      ]);
    });

    it('sends selected phases for a conflict retry', async () => {
      axios.post.mockResolvedValue({ data: { message: 'queued' } });

      await actions.runHookSync(
        { commit },
        { hookId: 2, phases: ['services'] }
      );

      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/2/run_sync'),
        { phases: ['services'] }
      );
    });

    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue(errorMessage);
      await expect(actions.runHookSync({ commit }, 2)).rejects.toEqual(
        errorMessage
      );
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isRunningHookSync: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isRunningHookSync: false }],
      ]);
    });
  });

  describe('#getHookSyncStatus', () => {
    it('returns the persisted run status', async () => {
      const data = { run: { id: 1, status: 'running' }, conflicts: [] };
      axios.get.mockResolvedValue({ data });

      await expect(actions.getHookSyncStatus({}, 2)).resolves.toEqual(data);
      expect(axios.get).toHaveBeenCalledWith(
        expect.stringContaining('/2/sync_status')
      );
    });
  });

  describe('#updateHookSyncConflict', () => {
    it('sends an administrator conflict decision', async () => {
      const data = { conflicts: [] };
      axios.patch.mockResolvedValue({ data });

      await expect(
        actions.updateHookSyncConflict(
          {},
          { hookId: 2, conflictId: 9, resolution: 'ignore' }
        )
      ).resolves.toEqual(data);
      expect(axios.patch).toHaveBeenCalledWith(
        expect.stringContaining('/2/sync_conflict'),
        { conflict_id: 9, resolution: 'ignore' }
      );
    });
  });

  describe('#importHookCatalog', () => {
    const file = new File(['{}'], 'catalog.json', {
      type: 'application/json',
    });

    it('sends correct actions if API is success', async () => {
      const data = { result: { specialists: { imported_count: 1 } } };
      axios.post.mockResolvedValue({ data });
      await expect(
        actions.importHookCatalog({ commit }, { hookId: 2, file })
      ).resolves.toEqual(data);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isImportingHookCatalog: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isImportingHookCatalog: false }],
      ]);
    });

    it('resets the loading flag if API is error', async () => {
      axios.post.mockRejectedValue(errorMessage);
      await expect(
        actions.importHookCatalog({ commit }, { hookId: 2, file })
      ).rejects.toEqual(errorMessage);
      expect(commit.mock.calls).toEqual([
        [types.SET_INTEGRATIONS_UI_FLAG, { isImportingHookCatalog: true }],
        [types.SET_INTEGRATIONS_UI_FLAG, { isImportingHookCatalog: false }],
      ]);
    });
  });
});
