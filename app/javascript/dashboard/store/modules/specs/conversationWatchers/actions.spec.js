import axios from 'axios';
import { actions } from '../../conversationWatchers';
import types from '../../../mutation-types';

const commit = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#actions', () => {
  describe('#get', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({ data: { id: 1 } });
      await actions.show({ commit }, { conversationId: 1 });
      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isFetching: true }],
        [
          types.SET_CONVERSATION_PARTICIPANTS,
          {
            conversationId: 1,
            communicationThreadMode: false,
            data: { id: 1 },
          },
        ],
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isFetching: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.show({ commit }, { conversationId: 1 })
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isFetching: true }],
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('ignores an older response for the same participant context', async () => {
      let resolveFirst;
      let resolveSecond;
      axios.get
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              resolveFirst = resolve;
            })
        )
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              resolveSecond = resolve;
            })
        );

      const firstRequest = actions.show({ commit }, { conversationId: 1 });
      const secondRequest = actions.show({ commit }, { conversationId: 1 });
      resolveSecond({ data: [{ id: 2 }] });
      await secondRequest;
      resolveFirst({ data: [{ id: 1 }] });
      await firstRequest;

      const participantCommits = commit.mock.calls.filter(
        ([type]) => type === types.SET_CONVERSATION_PARTICIPANTS
      );
      expect(participantCommits).toEqual([
        [
          types.SET_CONVERSATION_PARTICIPANTS,
          {
            conversationId: 1,
            communicationThreadMode: false,
            data: [{ id: 2 }],
          },
        ],
      ]);
    });
  });

  describe('#update', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: [{ id: 2 }] });
      await actions.update(
        { commit, state: { records: { 2: [] } } },
        { conversationId: 2, userIds: [2], communicationThreadMode: true }
      );
      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isUpdating: true }],
        [
          types.SET_CONVERSATION_PARTICIPANTS,
          {
            conversationId: 2,
            communicationThreadMode: true,
            data: [{ id: 2 }],
          },
        ],
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isUpdating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.update(
          { commit, state: { records: { 1: [] } } },
          { conversationId: 1, userIds: [2], communicationThreadMode: true }
        )
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isUpdating: true }],
        [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, { isUpdating: false }],
      ]);
    });

    it('keeps the legacy conversation participants API when thread mode is disabled', async () => {
      axios.patch.mockResolvedValue({ data: [{ id: 2 }] });

      await actions.update(
        { commit, state: { records: { 2: [] } } },
        { conversationId: 2, userIds: [2] }
      );

      expect(axios.patch).toHaveBeenCalled();
      expect(axios.post).not.toHaveBeenCalled();
    });
  });
});
