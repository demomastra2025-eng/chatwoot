import axios from 'axios';
import actions from '../../conversations/actions';
import types from '../../../mutation-types';

global.axios = axios;
vi.mock('axios');

describe('#fetchListSearchResults', () => {
  const listSearchResponse = (payload, meta = {}) => ({
    data: {
      data: { meta: { total_count: payload.length, ...meta }, payload },
    },
  });

  it('asks the list_search endpoint with the query and page only and stores the results', async () => {
    const localCommit = vi.fn();
    const localDispatch = vi.fn();
    axios.get.mockResolvedValue(
      listSearchResponse([
        { id: 5, meta: { sender: { id: 9 } } },
        { id: 6, meta: { sender: { id: 10 } } },
      ])
    );

    const result = await actions.fetchListSearchResults(
      { commit: localCommit, dispatch: localDispatch },
      { q: 'иван', page: 2 }
    );

    const [url, config] = axios.get.mock.calls.at(-1);
    expect(url).toMatch(/\/conversations\/list_search$/);
    expect(config.params).toEqual({ q: 'иван', page: 2 });
    expect(localCommit).toHaveBeenCalledWith(
      types.SET_ALL_CONVERSATION,
      expect.arrayContaining([expect.objectContaining({ id: 5 })])
    );
    expect(localCommit).toHaveBeenCalledWith('contacts/SET_CONTACTS', [
      { id: 9 },
      { id: 10 },
    ]);
    expect(result.conversations).toHaveLength(2);
    expect(result.meta.total_count).toBe(2);
  });

  it('searches communication threads in thread mode and keeps them as list entries', async () => {
    const localCommit = vi.fn();
    axios.get.mockResolvedValue(
      listSearchResponse([
        { id: 3, channels: [], messages: [], meta: { sender: { id: 9 } } },
      ])
    );

    const result = await actions.fetchListSearchResults(
      { commit: localCommit, dispatch: vi.fn() },
      { q: 'иван', communicationThreadMode: true }
    );

    expect(axios.get.mock.calls.at(-1)[0]).toMatch(
      /\/communication_threads\/list_search$/
    );
    expect(result.conversations[0]).toEqual(
      expect.objectContaining({ id: 3, is_communication_thread: true })
    );
  });

  it('passes the meta of the server on, partial and capped included', async () => {
    axios.get.mockResolvedValue(
      listSearchResponse([], { partial: true, capped: true })
    );

    const result = await actions.fetchListSearchResults(
      { commit: vi.fn(), dispatch: vi.fn() },
      { q: 'иван' }
    );

    expect(result.meta).toEqual(
      expect.objectContaining({ partial: true, capped: true })
    );
  });

  it('does not touch the list pagination, counters or loading state', async () => {
    const localCommit = vi.fn();
    const localDispatch = vi.fn();
    axios.get.mockResolvedValue(listSearchResponse([]));

    await actions.fetchListSearchResults(
      { commit: localCommit, dispatch: localDispatch },
      { q: 'иван' }
    );

    expect(localDispatch).not.toHaveBeenCalledWith(
      'conversationStats/set',
      expect.anything()
    );
    expect(localDispatch).not.toHaveBeenCalledWith(
      'conversationPage/setCurrentPage',
      expect.anything(),
      expect.anything()
    );
    expect(localCommit).not.toHaveBeenCalledWith(types.SET_LIST_LOADING_STATUS);
    expect(localCommit).not.toHaveBeenCalledWith(
      types.REPLACE_ALL_CONVERSATION,
      expect.anything()
    );
  });
});
