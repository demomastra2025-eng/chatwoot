import axios from 'axios';
import { actions } from '../../agents';
import * as types from '../../../mutation-types';
import agentList from './fixtures';

const commit = vi.fn();
const dispatch = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#actions', () => {
  describe('#get', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({ data: agentList });
      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_FETCHING_STATUS, true],
        [types.default.SET_AGENTS, agentList],
        [types.default.SET_AGENT_FETCHING_STATUS, false],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_FETCHING_STATUS, true],
        [types.default.SET_AGENT_FETCHING_STATUS, false],
      ]);
    });

    it('propagates an API error when an authoritative refresh is requested', async () => {
      const error = { message: 'Refresh failed' };
      axios.get.mockRejectedValue(error);

      await expect(
        actions.get({ commit }, { throwOnError: true })
      ).rejects.toBe(error);
    });

    it('does not publish agents from a stale account request', async () => {
      const deferred = () => {
        let resolve;
        const promise = new Promise(resolvePromise => {
          resolve = resolvePromise;
        });
        return { promise, resolve };
      };
      const accountARequest = deferred();
      const accountBRequest = deferred();
      const accountAAgents = [{ id: 1, name: 'Account A agent' }];
      const accountBAgents = [{ id: 2, name: 'Account B agent' }];
      axios.get
        .mockReturnValueOnce(accountARequest.promise)
        .mockReturnValueOnce(accountBRequest.promise);

      window.history.pushState({}, '', '/app/accounts/1/settings/agents');
      const accountAPromise = actions.get({ commit });
      window.history.pushState({}, '', '/app/accounts/2/settings/agents');
      const accountBPromise = actions.get({ commit });

      accountBRequest.resolve({ data: accountBAgents });
      await accountBPromise;
      accountARequest.resolve({ data: accountAAgents });
      await accountAPromise;

      expect(commit).toHaveBeenCalledWith(
        types.default.SET_AGENTS,
        accountBAgents
      );
      expect(commit).not.toHaveBeenCalledWith(
        types.default.SET_AGENTS,
        accountAAgents
      );
      expect(
        commit.mock.calls.filter(
          ([type, value]) =>
            type === types.default.SET_AGENT_FETCHING_STATUS && value === false
        )
      ).toHaveLength(1);
    });
  });

  describe('#create', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: agentList[0] });
      await actions.create({ commit }, agentList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_CREATING_STATUS, true],
        [types.default.ADD_AGENT, agentList[0]],
        [types.default.SET_AGENT_CREATING_STATUS, false],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.create({ commit })).rejects.toEqual({
        message: 'Incorrect header',
      });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_CREATING_STATUS, true],
        [types.default.SET_AGENT_CREATING_STATUS, false],
      ]);
    });
  });

  describe('#update', () => {
    it('sends correct actions if API is success', async () => {
      axios.patch.mockResolvedValue({ data: agentList[0] });
      await actions.update({ commit }, agentList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_UPDATING_STATUS, true],
        [types.default.EDIT_AGENT, agentList[0]],
        [types.default.SET_AGENT_UPDATING_STATUS, false],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      const error = {
        message: 'Incorrect header',
        response: { data: { code: 'TEST_ERROR' } },
      };
      axios.patch.mockRejectedValue(error);
      await expect(actions.update({ commit }, agentList[0])).rejects.toBe(
        error
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_UPDATING_STATUS, true],
        [types.default.SET_AGENT_UPDATING_STATUS, false],
      ]);
    });
  });

  describe('#delete', () => {
    it('sends correct actions if API is success', async () => {
      axios.delete.mockResolvedValue({ data: agentList[0] });
      await actions.delete({ commit }, agentList[0].id);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_DELETING_STATUS, true],
        [types.default.DELETE_AGENT, agentList[0].id],
        [types.default.SET_AGENT_DELETING_STATUS, false],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.delete({ commit }, agentList[0].id)).rejects.toThrow(
        Error
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_AGENT_DELETING_STATUS, true],
        [types.default.SET_AGENT_DELETING_STATUS, false],
      ]);
    });
  });

  describe('#updatePresence', () => {
    it('sends correct actions', async () => {
      const data = { users: { 1: 'online' }, contacts: { 2: 'online' } };
      actions.updatePresence({ commit, dispatch }, data);
      expect(commit.mock.calls).toEqual([
        [types.default.UPDATE_AGENTS_PRESENCE, data],
      ]);
    });
  });

  describe('#updateSingleAgentPresence', () => {
    it('sends correct actions', async () => {
      const data = { id: 1, availabilityStatus: 'online' };
      actions.updateSingleAgentPresence({ commit, dispatch }, data);
      expect(commit.mock.calls).toEqual([
        [types.default.UPDATE_SINGLE_AGENT_PRESENCE, data],
      ]);
    });
  });
});
