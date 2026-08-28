import axios from 'axios';
import { actions } from '../../bulkActions';
import * as types from '../../../mutation-types';
import payload from './fixtures';

const commit = vi.fn();
const dispatch = vi.fn();
global.axios = axios;
vi.mock('axios');

const bulkActionRun = {
  id: 42,
  status: 'completed',
  action_name: 'assign_agent',
  total_count: 2,
  processed_count: 2,
  failed_count: 0,
};

describe('#actions', () => {
  beforeEach(() => {
    commit.mockClear();
    dispatch.mockReset();
    axios.post.mockReset();
    axios.get.mockReset();
  });

  describe('#create', () => {
    it('sends correct actions if API is success', async () => {
      dispatch.mockResolvedValue(bulkActionRun);
      axios.post.mockResolvedValue({ data: { payload: bulkActionRun } });

      await actions.process({ commit, dispatch }, payload);

      expect(dispatch).toHaveBeenCalledWith('pollRunStatus', bulkActionRun.id);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: true }],
        [types.default.SET_BULK_ACTION_RUN, null],
        [types.default.SET_BULK_ACTION_RUN, bulkActionRun],
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: false }],
      ]);
    });

    it('replaces explicit ids with the server-side selection contract', async () => {
      const selection = {
        mode: 'all_matching',
        filters: { status: 'open', assignee_type: 'all' },
        excluded_ids: [9],
      };
      dispatch.mockResolvedValue(bulkActionRun);
      axios.post.mockResolvedValue({ data: { payload: bulkActionRun } });

      await actions.process(
        { commit, dispatch, state: { serverSelection: selection } },
        payload
      );

      expect(axios.post).toHaveBeenCalledWith(
        expect.any(String),
        expect.objectContaining({ ids: [], selection })
      );
    });

    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });

      await expect(
        actions.process({ commit, dispatch }, payload)
      ).rejects.toMatchObject({ message: 'Incorrect header' });

      expect(commit.mock.calls).toEqual([
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: true }],
        [types.default.SET_BULK_ACTION_RUN, null],
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: false }],
      ]);
    });

    it('preserves the failed record count from polling errors', async () => {
      const pollingError = new Error('2 records failed');
      pollingError.failedCount = 2;
      axios.post.mockResolvedValue({ data: { payload: bulkActionRun } });
      dispatch.mockRejectedValue(pollingError);

      await expect(actions.process({ commit, dispatch }, payload)).rejects.toBe(
        pollingError
      );
      expect(pollingError.failedCount).toBe(2);
    });
  });

  describe('#pollRunStatus', () => {
    it('polls and commits completed bulk action run status', async () => {
      axios.get.mockResolvedValue({ data: { payload: bulkActionRun } });

      await expect(
        actions.pollRunStatus({ commit }, bulkActionRun.id)
      ).resolves.toEqual(bulkActionRun);

      expect(commit.mock.calls).toEqual([
        [types.default.SET_BULK_ACTION_RUN, bulkActionRun],
      ]);
    });
  });

  describe('#setSelectedConversationIds', () => {
    it('sends correct actions if API is success', async () => {
      await actions.setSelectedConversationIds({ commit }, payload.ids);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_SELECTED_CONVERSATION_IDS, payload.ids],
      ]);
    });
  });

  describe('#removeSelectedConversationIds', () => {
    it('sends correct actions if API is success', async () => {
      await actions.removeSelectedConversationIds({ commit }, payload.ids);
      expect(commit.mock.calls).toEqual([
        [types.default.REMOVE_SELECTED_CONVERSATION_IDS, payload.ids],
      ]);
    });
  });

  describe('#clearSelectedConversationIds', () => {
    it('sends correct actions if API is success', async () => {
      await actions.clearSelectedConversationIds({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.CLEAR_SELECTED_CONVERSATION_IDS],
        [types.default.SET_BULK_SELECTION, null],
      ]);
    });
  });
});
