import { defineComponent, h, nextTick, ref } from 'vue';
import { mount } from '@vue/test-utils';
import { useStore } from 'vuex';
import {
  useConversationListSearch,
  MIN_SERVER_SEARCH_LENGTH,
  SERVER_SEARCH_DELAY,
} from '../useConversationListSearch';

vi.mock('vuex');

const searchResponse = (ids, meta = {}) => ({
  conversations: ids.map(id => ({ id })),
  meta: { total_count: ids.length, per_page: 25, current_page: 1, ...meta },
});

describe('useConversationListSearch', () => {
  let store;
  let query;
  let communicationThreadMode;
  let search;

  const mountComposable = () =>
    mount(
      defineComponent({
        setup() {
          search = useConversationListSearch({
            query,
            communicationThreadMode,
          });
          return () => h('div');
        },
      })
    );

  const typeQuery = async value => {
    query.value = value;
    await nextTick();
  };

  const flushSearch = async () => {
    await vi.advanceTimersByTimeAsync(SERVER_SEARCH_DELAY);
    await nextTick();
  };

  beforeEach(() => {
    vi.useFakeTimers();
    query = ref('');
    communicationThreadMode = ref(false);
    store = {
      dispatch: vi.fn(async () => searchResponse([7, 8])),
      getters: { getConversationById: vi.fn(() => undefined) },
    };
    useStore.mockReturnValue(store);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('does not search on the server for a query shorter than the minimum', async () => {
    mountComposable();
    await typeQuery('a'.repeat(MIN_SERVER_SEARCH_LENGTH - 1));
    await flushSearch();

    expect(search.isActive.value).toBe(false);
    expect(store.dispatch).not.toHaveBeenCalled();
  });

  it('sends only the query and the page after the debounce, never any list filter', async () => {
    mountComposable();
    await typeQuery('иван');
    expect(store.dispatch).not.toHaveBeenCalled();
    await flushSearch();

    expect(store.dispatch).toHaveBeenCalledTimes(1);
    expect(store.dispatch).toHaveBeenCalledWith('fetchListSearchResults', {
      q: 'иван',
      page: 1,
      communicationThreadMode: false,
    });
    expect(search.results.value.map(chat => chat.id)).toEqual([7, 8]);
    expect(search.total.value).toBe(2);
    expect(search.isLoading.value).toBe(false);
  });

  it('searches communication threads in thread mode', async () => {
    communicationThreadMode.value = true;
    mountComposable();
    await typeQuery('87072817060');
    await flushSearch();

    expect(store.dispatch).toHaveBeenCalledWith(
      'fetchListSearchResults',
      expect.objectContaining({ communicationThreadMode: true })
    );
    expect(search.results.value).toHaveLength(2);
    expect(store.getters.getConversationById).toHaveBeenCalledWith(
      7,
      'communication_thread'
    );
  });

  it('shows the store copy of a result so realtime updates reach it', async () => {
    store.getters.getConversationById.mockImplementation(id => ({
      id,
      unread_count: 3,
    }));
    mountComposable();
    await typeQuery('иван');
    await flushSearch();

    expect(search.results.value[0]).toEqual({ id: 7, unread_count: 3 });
  });

  it('debounces typing into a single request for the last query', async () => {
    mountComposable();
    await typeQuery('ива');
    await vi.advanceTimersByTimeAsync(SERVER_SEARCH_DELAY - 50);
    await typeQuery('иван');
    await flushSearch();

    expect(store.dispatch).toHaveBeenCalledTimes(1);
    expect(store.dispatch).toHaveBeenCalledWith(
      'fetchListSearchResults',
      expect.objectContaining({ q: 'иван' })
    );
  });

  it('ignores a response that arrives after the query changed', async () => {
    let resolveFirst;
    store.dispatch
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveFirst = resolve;
          })
      )
      .mockImplementationOnce(async () => searchResponse([99]));
    mountComposable();
    await typeQuery('иван');
    await flushSearch();
    await typeQuery('петр');
    await flushSearch();
    resolveFirst(searchResponse([1, 2, 3]));
    await nextTick();

    expect(search.results.value.map(chat => chat.id)).toEqual([99]);
  });

  it('loads the next page while there are more results and appends it', async () => {
    store.dispatch
      .mockResolvedValueOnce(
        searchResponse([1, 2], { total_count: 3, per_page: 2 })
      )
      .mockResolvedValueOnce(
        searchResponse([3], { total_count: 3, per_page: 2, current_page: 2 })
      );
    mountComposable();
    await typeQuery('иван');
    await flushSearch();

    expect(search.hasMore.value).toBe(true);
    search.loadMore();
    await nextTick();
    await nextTick();

    expect(store.dispatch).toHaveBeenLastCalledWith('fetchListSearchResults', {
      q: 'иван',
      page: 2,
      communicationThreadMode: false,
    });
    expect(search.results.value.map(chat => chat.id)).toEqual([1, 2, 3]);
    expect(search.hasMore.value).toBe(false);
  });

  it('reports a capped total so the count can be shown as "100+"', async () => {
    store.dispatch.mockResolvedValue(
      searchResponse([1], { total_count: 100, capped: true })
    );
    mountComposable();
    await typeQuery('иван');
    await flushSearch();

    expect(search.isCapped.value).toBe(true);
    expect(search.total.value).toBe(100);
  });

  it('reports a partial search, whose message text ran out of time', async () => {
    store.dispatch.mockResolvedValue(
      searchResponse([1], { total_count: 1, partial: true })
    );
    mountComposable();
    await typeQuery('иван');
    await flushSearch();

    expect(search.isPartial.value).toBe(true);

    await typeQuery('');
    expect(search.isPartial.value).toBe(false);
  });

  it('clears the results when the query is cleared', async () => {
    mountComposable();
    await typeQuery('иван');
    await flushSearch();
    await typeQuery('');

    expect(search.isActive.value).toBe(false);
    expect(search.results.value).toEqual([]);
    expect(search.total.value).toBe(0);
  });

  it('keeps an error state and searches again from the start on retry', async () => {
    store.dispatch
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValueOnce(searchResponse([5]));
    mountComposable();
    await typeQuery('иван');
    await flushSearch();

    expect(search.hasError.value).toBe(true);
    expect(search.isLoading.value).toBe(false);

    search.retry();
    await nextTick();
    await nextTick();

    expect(search.hasError.value).toBe(false);
    expect(search.results.value.map(chat => chat.id)).toEqual([5]);
  });
});
