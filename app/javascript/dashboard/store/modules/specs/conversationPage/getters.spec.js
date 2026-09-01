import { getters } from '../../conversationPage';

describe('#getters', () => {
  it('getCurrentPage', () => {
    const state = {
      currentPage: {
        me: 1,
        unassigned: 2,
        all: 3,
      },
    };
    expect(getters.getCurrentPage(state)).toHaveProperty('me');
    expect(getters.getCurrentPage(state)).toHaveProperty('unassigned');
    expect(getters.getCurrentPage(state)).toHaveProperty('all');
  });

  it('getCurrentPageFilter', () => {
    const state = {
      currentPage: {
        me: 1,
        unassigned: 2,
        all: 3,
      },
    };
    expect(getters.getCurrentPageFilter(state)('me')).toEqual(1);
    expect(getters.getCurrentPageFilter(state)('unassigned')).toEqual(2);
    expect(getters.getCurrentPageFilter(state)('all')).toEqual(3);
  });

  it('defaults a new dynamic scope to the first page', () => {
    const state = { currentPage: {} };

    expect(
      getters.getCurrentPageFilter(state)(
        'scope:{"crmPipelineId":"2","crmStageId":"3"}'
      )
    ).toEqual(0);
  });

  it('getHasEndReached', () => {
    const state = {
      hasEndReached: {
        me: false,
        unassigned: true,
        all: false,
      },
    };
    expect(getters.getHasEndReached(state)('me')).toEqual(false);
    expect(getters.getHasEndReached(state)('unassigned')).toEqual(true);
    expect(getters.getHasEndReached(state)('all')).toEqual(false);
  });

  it('defaults a new dynamic scope to not having reached the end', () => {
    const state = { hasEndReached: {} };

    expect(getters.getHasEndReached(state)('scope:new')).toEqual(false);
  });

  it('getTotalCount', () => {
    const state = { totalCount: { all: 42, appliedFilters: 7 } };
    expect(getters.getTotalCount(state)('all')).toEqual(42);
    expect(getters.getTotalCount(state)('appliedFilters')).toEqual(7);
  });
});
