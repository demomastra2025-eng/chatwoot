import { actions } from '../../conversationSearch';
import types from '../../../mutation-types';
import axios from 'axios';

const commit = vi.fn();
const dispatch = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#actions', () => {
  beforeEach(() => {
    actions.clearSearchResults({ commit });
    commit.mockClear();
    dispatch.mockReset();
    axios.get.mockReset();
  });

  describe('#get', () => {
    it('sends correct actions if no query param is provided', () => {
      actions.get({ commit }, { q: '' });
      expect(commit.mock.calls).toEqual([[types.SEARCH_CONVERSATIONS_SET, []]]);
    });

    it('sends correct actions if query param is provided and API call is success', async () => {
      axios.get.mockResolvedValue({
        data: {
          payload: [{ messages: [{ id: 1, content: 'value testing' }], id: 1 }],
        },
      });

      await actions.get({ commit }, { q: 'value' });
      expect(commit.mock.calls).toEqual([
        [types.SEARCH_CONVERSATIONS_SET, []],
        [types.SEARCH_CONVERSATIONS_SET_UI_FLAG, { isFetching: true }],
        [
          types.SEARCH_CONVERSATIONS_SET,
          [{ messages: [{ id: 1, content: 'value testing' }], id: 1 }],
        ],
        [types.SEARCH_CONVERSATIONS_SET_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('sends correct actions if query param is provided and API call is errored', async () => {
      axios.get.mockRejectedValue({});
      await actions.get({ commit }, { q: 'value' });
      expect(commit.mock.calls).toEqual([
        [types.SEARCH_CONVERSATIONS_SET, []],
        [types.SEARCH_CONVERSATIONS_SET_UI_FLAG, { isFetching: true }],
        [types.SEARCH_CONVERSATIONS_SET_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#fullSearch', () => {
    it('should not dispatch any actions if no query provided', async () => {
      await actions.fullSearch({ commit, dispatch }, { q: '' });
      expect(dispatch).not.toHaveBeenCalled();
    });

    it('should dispatch all search actions and set UI flags correctly', async () => {
      await actions.fullSearch({ commit, dispatch }, { q: 'test' });

      expect(commit.mock.calls).toEqual([
        [
          types.FULL_SEARCH_SET_UI_FLAG,
          { isFetching: true, isSearchCompleted: false },
        ],
        [
          types.FULL_SEARCH_SET_UI_FLAG,
          { isFetching: false, isSearchCompleted: true },
        ],
      ]);

      expect(dispatch).toHaveBeenCalledWith('contactSearch', { q: 'test' });
      expect(dispatch).toHaveBeenCalledWith('conversationSearch', {
        q: 'test',
      });
      expect(dispatch).toHaveBeenCalledWith('messageSearch', { q: 'test' });
      expect(dispatch).toHaveBeenCalledWith('articleSearch', { q: 'test' });
    });

    it('should pass filters to all search actions including articleSearch', async () => {
      const payload = { q: 'test', since: 1700000000, until: 1732000000 };
      await actions.fullSearch({ commit, dispatch }, payload);

      expect(dispatch).toHaveBeenCalledWith('contactSearch', payload);
      expect(dispatch).toHaveBeenCalledWith('conversationSearch', payload);
      expect(dispatch).toHaveBeenCalledWith('messageSearch', payload);
      expect(dispatch).toHaveBeenCalledWith('articleSearch', payload);
    });

    it('passes one abort signal to all requests in the current search', async () => {
      const signals = [];
      const payloadByPath = {
        contacts: { contacts: [] },
        conversations: { conversations: [] },
        messages: { messages: [] },
        articles: { articles: [] },
      };
      axios.get.mockImplementation((url, config) => {
        const path = url.split('/').at(-1);
        signals.push(config.signal);
        return Promise.resolve({ data: { payload: payloadByPath[path] } });
      });
      dispatch.mockImplementation((action, actionPayload) =>
        actions[action]({ commit }, actionPayload)
      );

      await actions.fullSearch({ commit, dispatch }, { q: 'test' });

      expect(signals).toHaveLength(4);
      expect(signals.every(signal => signal instanceof AbortSignal)).toBe(true);
      expect(new Set(signals)).toHaveLength(1);
    });

    it('aborts the previous full search and only completes the current one', async () => {
      const requests = [];
      const payloadByPath = {
        contacts: { contacts: [] },
        conversations: { conversations: [] },
        messages: { messages: [] },
        articles: { articles: [] },
      };
      axios.get.mockImplementation((url, config) => {
        return new Promise((resolve, reject) => {
          const request = { url, signal: config.signal, resolve };
          requests.push(request);
          config.signal.addEventListener('abort', () =>
            reject(new Error('aborted'))
          );
        });
      });
      dispatch.mockImplementation((action, actionPayload) =>
        actions[action]({ commit }, actionPayload)
      );

      const previousSearch = actions.fullSearch(
        { commit, dispatch },
        { q: 'previous' }
      );
      const currentSearch = actions.fullSearch(
        { commit, dispatch },
        { q: 'current' }
      );

      expect(
        requests.slice(0, 4).every(request => request.signal.aborted)
      ).toBe(true);
      requests.slice(4).forEach(request => {
        const path = request.url.split('/').at(-1);
        request.resolve({ data: { payload: payloadByPath[path] } });
      });
      await Promise.all([previousSearch, currentSearch]);

      const completedSearchCommits = commit.mock.calls.filter(
        ([type, flags]) =>
          type === types.FULL_SEARCH_SET_UI_FLAG && flags.isSearchCompleted
      );
      expect(completedSearchCommits).toHaveLength(1);
    });

    it('keeps active request controllers isolated between store instances', async () => {
      const firstCommit = vi.fn();
      const secondCommit = vi.fn();
      let resolveFirstDispatch;
      const pendingDispatch = new Promise(resolve => {
        resolveFirstDispatch = resolve;
      });
      const firstDispatch = vi.fn(() => pendingDispatch);
      const secondDispatch = vi.fn(() => Promise.resolve());
      const abortSpy = vi.spyOn(AbortController.prototype, 'abort');

      const firstSearch = actions.fullSearch(
        { commit: firstCommit, dispatch: firstDispatch },
        { q: 'first store' }
      );
      await actions.fullSearch(
        { commit: secondCommit, dispatch: secondDispatch },
        { q: 'second store' }
      );

      expect(abortSpy).not.toHaveBeenCalled();
      resolveFirstDispatch();
      await firstSearch;
      abortSpy.mockRestore();
    });
  });

  describe('#contactSearch', () => {
    it('should handle successful contact search', async () => {
      axios.get.mockResolvedValue({
        data: { payload: { contacts: [{ id: 1 }] } },
      });

      await actions.contactSearch({ commit }, { q: 'test', page: 1 });
      expect(commit.mock.calls).toEqual([
        [types.CONTACT_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.CONTACT_SEARCH_SET, [{ id: 1 }]],
        [types.CONTACT_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('should handle failed contact search', async () => {
      axios.get.mockRejectedValue({});
      await actions.contactSearch({ commit }, { q: 'test' });
      expect(commit.mock.calls).toEqual([
        [types.CONTACT_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.CONTACT_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#conversationSearch', () => {
    it('should handle successful conversation search', async () => {
      axios.get.mockResolvedValue({
        data: { payload: { conversations: [{ id: 1 }] } },
      });

      await actions.conversationSearch({ commit }, { q: 'test', page: 1 });
      expect(commit.mock.calls).toEqual([
        [types.CONVERSATION_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.CONVERSATION_SEARCH_SET, [{ id: 1 }]],
        [types.CONVERSATION_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('should handle failed conversation search', async () => {
      axios.get.mockRejectedValue({});
      await actions.conversationSearch({ commit }, { q: 'test' });
      expect(commit.mock.calls).toEqual([
        [types.CONVERSATION_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.CONVERSATION_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('ignores a stale response after search results are cleared', async () => {
      let resolveOld;
      let resolveCurrent;
      axios.get
        .mockReturnValueOnce(
          new Promise(resolve => {
            resolveOld = resolve;
          })
        )
        .mockReturnValueOnce(
          new Promise(resolve => {
            resolveCurrent = resolve;
          })
        );

      const oldSearch = actions.conversationSearch({ commit }, { q: 'old' });
      actions.clearSearchResults({ commit });
      commit.mockClear();
      const currentSearch = actions.conversationSearch(
        { commit },
        { q: 'current' }
      );

      resolveCurrent({
        data: { payload: { conversations: [{ id: 'current' }] } },
      });
      await currentSearch;
      resolveOld({ data: { payload: { conversations: [{ id: 'old' }] } } });
      await oldSearch;

      expect(commit.mock.calls).toEqual([
        [types.CONVERSATION_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.CONVERSATION_SEARCH_SET, [{ id: 'current' }]],
        [types.CONVERSATION_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#messageSearch', () => {
    it('should handle successful message search', async () => {
      axios.get.mockResolvedValue({
        data: { payload: { messages: [{ id: 1 }] } },
      });

      await actions.messageSearch({ commit }, { q: 'test', page: 1 });
      expect(commit.mock.calls).toEqual([
        [types.MESSAGE_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.MESSAGE_SEARCH_SET, [{ id: 1 }]],
        [types.MESSAGE_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('should handle failed message search', async () => {
      axios.get.mockRejectedValue({});
      await actions.messageSearch({ commit }, { q: 'test' });
      expect(commit.mock.calls).toEqual([
        [types.MESSAGE_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.MESSAGE_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#articleSearch', () => {
    it('should handle successful article search', async () => {
      axios.get.mockResolvedValue({
        data: { payload: { articles: [{ id: 1 }] } },
      });

      await actions.articleSearch({ commit }, { q: 'test', page: 1 });
      expect(commit.mock.calls).toEqual([
        [types.ARTICLE_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.ARTICLE_SEARCH_SET, [{ id: 1 }]],
        [types.ARTICLE_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('should handle article search with date filters', async () => {
      axios.get.mockResolvedValue({
        data: { payload: { articles: [{ id: 1 }] } },
      });

      await actions.articleSearch(
        { commit },
        { q: 'test', page: 1, since: 1700000000, until: 1732000000 }
      );
      expect(commit.mock.calls).toEqual([
        [types.ARTICLE_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.ARTICLE_SEARCH_SET, [{ id: 1 }]],
        [types.ARTICLE_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('should handle failed article search', async () => {
      axios.get.mockRejectedValue({});
      await actions.articleSearch({ commit }, { q: 'test' });
      expect(commit.mock.calls).toEqual([
        [types.ARTICLE_SEARCH_SET_UI_FLAG, { isFetching: true }],
        [types.ARTICLE_SEARCH_SET_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#clearSearchResults', () => {
    it('should commit clear search results mutation', () => {
      actions.clearSearchResults({ commit });
      expect(commit).toHaveBeenCalledWith(types.CLEAR_SEARCH_RESULTS);
    });
  });
});
