import axios from 'axios';
import { actions, getters, state } from '../../bulkActions';
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

  it('counts snapshot selections without adding placeholder conversation IDs', () => {
    expect(
      getters.getSelectedConversationCount({
        ...state,
        selectedConversationIds: [],
        allMatchingSelectionCount: 3,
      })
    ).toBe(3);
  });

  describe('#create', () => {
    it('sends correct actions if API is success', async () => {
      dispatch.mockResolvedValue(bulkActionRun);
      axios.post.mockResolvedValue({ data: { payload: bulkActionRun } });

      await actions.process({ commit, dispatch }, payload);

      expect(dispatch).toHaveBeenCalledWith('pollRunStatus', {
        id: bulkActionRun.id,
        context: expect.objectContaining({
          accountId: expect.any(String),
          baseUrl: expect.any(String),
        }),
      });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: true }],
        [types.default.SET_BULK_ACTION_RUN, null],
        [types.default.SET_BULK_ACTION_RUN, bulkActionRun],
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: false }],
      ]);
    });

    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });

      await expect(
        actions.process({ commit, dispatch }, payload)
      ).rejects.toThrow(Error);

      expect(commit.mock.calls).toEqual([
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: true }],
        [types.default.SET_BULK_ACTION_RUN, null],
        [types.default.SET_BULK_ACTIONS_FLAG, { isUpdating: false }],
      ]);
    });
  });

  describe('#process errors', () => {
    it('keeps the failed count of a failed run for the caller', async () => {
      const failure = new Error('Bulk action failed');
      failure.failedCount = 3;
      dispatch.mockRejectedValue(failure);
      axios.post.mockResolvedValue({ data: { payload: bulkActionRun } });

      await expect(
        actions.process({ commit, dispatch }, payload)
      ).rejects.toMatchObject({ failedCount: 3 });
    });

    it('settles with an unknown result and clears the updating flag when status is inaccessible', async () => {
      axios.post.mockResolvedValue({ data: { payload: bulkActionRun } });
      axios.get.mockRejectedValue({ response: { status: 404 } });
      dispatch.mockImplementation((action, run) =>
        actions[action]({ commit, dispatch }, run)
      );

      await expect(
        actions.process({ commit, dispatch }, payload)
      ).rejects.toMatchObject({ code: 'bulk_action_status_unknown' });

      expect(commit).toHaveBeenCalledWith(
        types.default.SET_BULK_ACTION_RUN,
        null
      );
      expect(commit).toHaveBeenLastCalledWith(
        types.default.SET_BULK_ACTIONS_FLAG,
        { isUpdating: false }
      );
    });
  });

  describe('#pollRunStatus', () => {
    it('rejects with the failed count when the run fails', async () => {
      axios.get.mockResolvedValue({
        data: {
          payload: {
            ...bulkActionRun,
            status: 'failed',
            failed_count: 2,
            error_message: 'Partially failed',
          },
        },
      });

      await expect(
        actions.pollRunStatus({ commit }, bulkActionRun.id)
      ).rejects.toMatchObject({ message: 'Partially failed', failedCount: 2 });
    });

    it('polls and commits completed bulk action run status', async () => {
      axios.get.mockResolvedValue({ data: { payload: bulkActionRun } });

      await expect(
        actions.pollRunStatus({ commit }, bulkActionRun.id)
      ).resolves.toEqual(bulkActionRun);

      expect(commit.mock.calls).toEqual([
        [types.default.SET_BULK_ACTION_RUN, bulkActionRun],
      ]);
    });

    it.each([401, 403, 404])(
      'stops foreground polling when status returns %s',
      async status => {
        axios.get.mockRejectedValue({ response: { status } });

        await expect(
          actions.pollRunStatus({ commit }, bulkActionRun.id)
        ).rejects.toMatchObject({ code: 'bulk_action_status_unknown' });

        expect(axios.get).toHaveBeenCalledTimes(1);
        expect(commit).toHaveBeenCalledWith(
          types.default.SET_BULK_ACTION_RUN,
          null
        );
      }
    );

    it('retries a temporary network failure and accepts the later completed result', async () => {
      vi.useFakeTimers();
      axios.get
        .mockRejectedValueOnce(new Error('Network unavailable'))
        .mockResolvedValueOnce({ data: { payload: bulkActionRun } });

      try {
        const pendingRun = actions.pollRunStatus({ commit }, bulkActionRun.id);
        await vi.advanceTimersByTimeAsync(750);
        await expect(pendingRun).resolves.toEqual(bulkActionRun);
        expect(axios.get).toHaveBeenCalledTimes(2);
      } finally {
        vi.useRealTimers();
      }
    });

    it('keeps polling beyond the initial three-minute window until the run completes', async () => {
      vi.useFakeTimers();
      axios.get.mockImplementation(async () => {
        const status =
          axios.get.mock.calls.length >= 242 ? 'completed' : 'processing';
        return {
          data: {
            payload: { ...bulkActionRun, status },
          },
        };
      });

      try {
        const pendingRun = actions.pollRunStatus({ commit }, bulkActionRun.id);
        await vi.advanceTimersByTimeAsync(240 * 750);
        expect(axios.get).toHaveBeenCalledTimes(241);

        await vi.advanceTimersByTimeAsync(2999);
        expect(axios.get).toHaveBeenCalledTimes(241);

        await vi.advanceTimersByTimeAsync(1);
        await expect(pendingRun).resolves.toMatchObject({
          status: 'completed',
        });
        expect(axios.get).toHaveBeenCalledTimes(242);
      } finally {
        vi.useRealTimers();
      }
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
        [types.default.SET_ALL_MATCHING_SELECTION_COUNT, 0],
      ]);
    });
  });

  describe('#setAllMatchingSelectionCount', () => {
    it('stores the selected snapshot count for command bar actions', async () => {
      await actions.setAllMatchingSelectionCount({ commit }, 4);

      expect(commit).toHaveBeenCalledWith(
        types.default.SET_ALL_MATCHING_SELECTION_COUNT,
        4
      );
    });
  });
});
