import { createPinia, setActivePinia } from 'pinia';

import { useConversationSearchStore } from './conversationSearch';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  contacts: vi.fn(),
  conversations: vi.fn(),
  messages: vi.fn(),
  articles: vi.fn(),
}));

vi.mock('dashboard/api/search', () => ({
  default: apiMocks,
}));

const emptyResponses = {
  contacts: { contacts: [] },
  conversations: { conversations: [] },
  messages: { messages: [] },
  articles: { articles: [] },
};

const mockEmptyFullSearch = () => {
  Object.entries(emptyResponses).forEach(([method, payload]) => {
    apiMocks[method].mockResolvedValue({ data: { payload } });
  });
};

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
};

const expectIdleUIFlags = store => {
  expect(store.uiFlags).toEqual({
    isFetching: false,
    isSearchCompleted: false,
    contact: { isFetching: false },
    conversation: { isFetching: false },
    message: { isFetching: false },
    article: { isFetching: false },
  });
};

describe('useConversationSearchStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    Object.values(apiMocks).forEach(mock => mock.mockReset());
  });

  it('exposes the legacy search state through Pinia getters', () => {
    const store = useConversationSearchStore();
    store.$patch({
      records: [{ id: 1 }],
      contactRecords: [{ id: 2 }],
      conversationRecords: [{ id: 3 }],
      messageRecords: [{ id: 4 }],
      articleRecords: [{ id: 5 }],
    });

    expect(store.getConversations).toEqual([{ id: 1 }]);
    expect(store.getContactRecords).toEqual([{ id: 2 }]);
    expect(store.getConversationRecords).toEqual([{ id: 3 }]);
    expect(store.getMessageRecords).toEqual([{ id: 4 }]);
    expect(store.getArticleRecords).toEqual([{ id: 5 }]);
    expect(store.getUIFlags).toBe(store.uiFlags);
  });

  it('clears quick-search records without making an empty request', async () => {
    const store = useConversationSearchStore();
    store.records = [{ id: 1 }];
    store.uiFlags.isFetching = true;

    await store.get({ q: '' });

    expect(store.records).toEqual([]);
    expect(store.uiFlags.isFetching).toBe(false);
    expect(apiMocks.get).not.toHaveBeenCalled();
  });

  it('stores quick-search results and clears loading after success or failure', async () => {
    const store = useConversationSearchStore();
    apiMocks.get.mockResolvedValueOnce({ data: { payload: [{ id: 1 }] } });

    await store.get({ q: 'value' });

    expect(apiMocks.get).toHaveBeenCalledWith({
      q: 'value',
      signal: expect.any(AbortSignal),
    });
    expect(store.records).toEqual([{ id: 1 }]);
    expect(store.uiFlags.isFetching).toBe(false);

    apiMocks.get.mockRejectedValueOnce(new Error('failed'));
    await store.get({ q: 'other' });

    expect(store.records).toEqual([]);
    expect(store.uiFlags.isFetching).toBe(false);
  });

  it('aborts the previous quick search and ignores its stale response', async () => {
    const store = useConversationSearchStore();
    const previous = deferred();
    const current = deferred();
    apiMocks.get
      .mockReturnValueOnce(previous.promise)
      .mockReturnValueOnce(current.promise);

    const previousSearch = store.get({ q: 'previous' });
    const currentSearch = store.get({ q: 'current' });

    const previousSignal = apiMocks.get.mock.calls[0][0].signal;
    expect(previousSignal.aborted).toBe(true);

    current.resolve({ data: { payload: [{ id: 'current' }] } });
    await currentSearch;
    previous.resolve({ data: { payload: [{ id: 'previous' }] } });
    await previousSearch;

    expect(store.records).toEqual([{ id: 'current' }]);
    expect(store.uiFlags.isFetching).toBe(false);
  });

  it('does not call full-search endpoints for an empty payload', async () => {
    const store = useConversationSearchStore();

    await store.fullSearch({ q: '' });

    expect(apiMocks.contacts).not.toHaveBeenCalled();
    expect(apiMocks.conversations).not.toHaveBeenCalled();
    expect(apiMocks.messages).not.toHaveBeenCalled();
    expect(apiMocks.articles).not.toHaveBeenCalled();
  });

  it('passes filters and one abort signal to every full-search endpoint', async () => {
    const store = useConversationSearchStore();
    mockEmptyFullSearch();
    const payload = { q: 'test', since: 1700000000, until: 1732000000 };

    await store.fullSearch(payload);

    const calls = [
      apiMocks.contacts,
      apiMocks.conversations,
      apiMocks.messages,
      apiMocks.articles,
    ].map(mock => mock.mock.calls[0][0]);
    const signals = calls.map(call => call.signal);

    calls.forEach(call => {
      expect(call).toMatchObject({ ...payload, page: 1 });
    });
    expect(signals.every(signal => signal instanceof AbortSignal)).toBe(true);
    expect(new Set(signals)).toHaveLength(1);
    expect(store.uiFlags.isFetching).toBe(false);
    expect(store.uiFlags.isSearchCompleted).toBe(true);
  });

  it('aborts the previous full search and only stores current results', async () => {
    const store = useConversationSearchStore();
    const requests = [];

    Object.keys(emptyResponses).forEach(method => {
      apiMocks[method].mockImplementation(params => {
        const request = deferred();
        requests.push({ ...request, method, signal: params.signal });
        params.signal.addEventListener('abort', () =>
          request.reject(new Error('aborted'))
        );
        return request.promise;
      });
    });

    const previousSearch = store.fullSearch({ q: 'previous' });
    const currentSearch = store.fullSearch({ q: 'current' });

    expect(requests.slice(0, 4).every(request => request.signal.aborted)).toBe(
      true
    );
    requests.slice(4).forEach(request => {
      request.resolve({
        data: {
          payload: {
            [request.method]: [{ id: `current-${request.method}` }],
          },
        },
      });
    });
    await Promise.all([previousSearch, currentSearch]);

    expect(store.contactRecords).toEqual([{ id: 'current-contacts' }]);
    expect(store.conversationRecords).toEqual([
      { id: 'current-conversations' },
    ]);
    expect(store.messageRecords).toEqual([{ id: 'current-messages' }]);
    expect(store.articleRecords).toEqual([{ id: 'current-articles' }]);
    expect(store.uiFlags.isSearchCompleted).toBe(true);
  });

  it('keeps active request controllers isolated between store instances', async () => {
    const firstStore = useConversationSearchStore(createPinia());
    const secondStore = useConversationSearchStore(createPinia());
    const firstRequests = [];
    const abortSpy = vi.spyOn(AbortController.prototype, 'abort');

    Object.keys(emptyResponses).forEach(method => {
      apiMocks[method].mockImplementation(params => {
        if (params.q === 'first') {
          const request = deferred();
          firstRequests.push({ ...request, method });
          return request.promise;
        }
        return Promise.resolve({
          data: { payload: emptyResponses[method] },
        });
      });
    });

    const firstSearch = firstStore.fullSearch({ q: 'first' });
    await secondStore.fullSearch({ q: 'second' });

    expect(abortSpy).not.toHaveBeenCalled();
    firstRequests.forEach(request => {
      request.resolve({ data: { payload: emptyResponses[request.method] } });
    });
    await firstSearch;
    abortSpy.mockRestore();
  });

  it.each([
    ['contactSearch', 'contacts', 'contactRecords', 'contact'],
    [
      'conversationSearch',
      'conversations',
      'conversationRecords',
      'conversation',
    ],
    ['messageSearch', 'messages', 'messageRecords', 'message'],
    ['articleSearch', 'articles', 'articleRecords', 'article'],
  ])(
    'appends paginated results for %s and restores its loading flag',
    async (action, apiMethod, recordsKey, flagKey) => {
      const store = useConversationSearchStore();
      store[recordsKey] = [{ id: 1 }];
      apiMocks[apiMethod].mockResolvedValue({
        data: { payload: { [apiMethod]: [{ id: 2 }] } },
      });

      await store[action]({ q: 'test', page: 2 });

      expect(apiMocks[apiMethod]).toHaveBeenCalledWith({
        q: 'test',
        page: 2,
        signal: undefined,
      });
      expect(store[recordsKey]).toEqual([{ id: 1 }, { id: 2 }]);
      expect(store.uiFlags[flagKey].isFetching).toBe(false);
    }
  );

  it.each([
    ['contactSearch', 'contacts', 'contactRecords', 'contact'],
    [
      'conversationSearch',
      'conversations',
      'conversationRecords',
      'conversation',
    ],
    ['messageSearch', 'messages', 'messageRecords', 'message'],
    ['articleSearch', 'articles', 'articleRecords', 'article'],
  ])(
    'keeps existing %s results and restores loading after an API failure',
    async (action, apiMethod, recordsKey, flagKey) => {
      const store = useConversationSearchStore();
      store[recordsKey] = [{ id: 1 }];
      apiMocks[apiMethod].mockRejectedValue(new Error('failed'));

      await store[action]({ q: 'test' });

      expect(store[recordsKey]).toEqual([{ id: 1 }]);
      expect(store.uiFlags[flagKey].isFetching).toBe(false);
    }
  );

  it('invalidates an in-flight load-more response when results are cleared', async () => {
    const store = useConversationSearchStore();
    const previous = deferred();
    const current = deferred();
    apiMocks.conversations
      .mockReturnValueOnce(previous.promise)
      .mockReturnValueOnce(current.promise);

    const previousSearch = store.conversationSearch({ q: 'previous' });
    store.clearSearchResults();
    const currentSearch = store.conversationSearch({ q: 'current' });

    current.resolve({
      data: { payload: { conversations: [{ id: 'current' }] } },
    });
    await currentSearch;
    previous.resolve({
      data: { payload: { conversations: [{ id: 'previous' }] } },
    });
    await previousSearch;

    expect(store.conversationRecords).toEqual([{ id: 'current' }]);
    expect(store.uiFlags.conversation.isFetching).toBe(false);
  });

  it('clears full-search records and UI flags while preserving quick results', () => {
    const store = useConversationSearchStore();
    store.$patch({
      records: [{ id: 'quick' }],
      contactRecords: [{ id: 1 }],
      conversationRecords: [{ id: 2 }],
      messageRecords: [{ id: 3 }],
      articleRecords: [{ id: 4 }],
      uiFlags: {
        isFetching: true,
        isSearchCompleted: true,
        contact: { isFetching: true },
        conversation: { isFetching: true },
        message: { isFetching: true },
        article: { isFetching: true },
      },
    });

    store.clearSearchResults();

    expect(store.records).toEqual([{ id: 'quick' }]);
    expect(store.contactRecords).toEqual([]);
    expect(store.conversationRecords).toEqual([]);
    expect(store.messageRecords).toEqual([]);
    expect(store.articleRecords).toEqual([]);
    expectIdleUIFlags(store);
  });
});
