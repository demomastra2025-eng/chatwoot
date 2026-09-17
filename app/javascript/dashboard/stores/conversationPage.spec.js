import { createPinia, setActivePinia } from 'pinia';

import { useConversationPageStore } from './conversationPage';

describe('useConversationPageStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('tracks pages and totals for built-in and dynamic scopes', () => {
    const store = useConversationPageStore();
    const dynamicScope = 'scope:{"crmPipelineId":"2","crmStageId":"3"}';

    expect(store.getCurrentPageFilter(dynamicScope)).toBe(0);
    expect(store.getTotalCount(dynamicScope)).toBe(0);

    store.setCurrentPage({ filter: 'me', page: 2 });
    store.setCurrentPage({ filter: dynamicScope, page: 3 });
    store.setTotalCount({ filter: 'all', count: '42' });
    store.setTotalCount({ filter: dynamicScope, count: 7 });

    expect(store.getCurrentPageFilter('me')).toBe(2);
    expect(store.getCurrentPageFilter(dynamicScope)).toBe(3);
    expect(store.getTotalCount('all')).toBe(42);
    expect(store.getTotalCount(dynamicScope)).toBe(7);
  });

  it('marks one scope as complete without changing the others', () => {
    const store = useConversationPageStore();

    store.setEndReached({ filter: 'me' });

    expect(store.getHasEndReached('me')).toBe(true);
    expect(store.getHasEndReached('unassigned')).toBe(false);
    expect(store.getHasEndReached('all')).toBe(false);
    expect(store.getHasEndReached('scope:new')).toBe(false);
  });

  it('marks the aggregate and assignee scopes complete together', () => {
    const store = useConversationPageStore();

    store.setEndReached({ filter: 'all' });

    expect(store.getHasEndReached('me')).toBe(true);
    expect(store.getHasEndReached('unassigned')).toBe(true);
    expect(store.getHasEndReached('all')).toBe(true);
  });

  it('resets built-in and dynamic scope state', () => {
    const store = useConversationPageStore();
    const dynamicScope = 'scope:label:vip';
    store.setCurrentPage({ filter: dynamicScope, page: 4 });
    store.setEndReached({ filter: dynamicScope });
    store.setTotalCount({ filter: dynamicScope, count: 9 });

    store.reset();

    expect(store.currentPage).toEqual({
      me: 0,
      unassigned: 0,
      all: 0,
      appliedFilters: 0,
    });
    expect(store.hasEndReached).toEqual({
      me: false,
      unassigned: false,
      all: false,
      appliedFilters: false,
    });
    expect(store.totalCount).toEqual({
      me: 0,
      unassigned: 0,
      all: 0,
      appliedFilters: 0,
    });
    expect(store.getCurrentPageFilter(dynamicScope)).toBe(0);
    expect(store.getHasEndReached(dynamicScope)).toBe(false);
    expect(store.getTotalCount(dynamicScope)).toBe(0);
  });
});
