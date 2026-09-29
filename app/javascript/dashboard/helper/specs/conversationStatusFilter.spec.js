import { describe, expect, it } from 'vitest';
import {
  extractSingleStatusFilter,
  mergeRouteStatusFilter,
  removeRouteStatusFilter,
} from '../conversationStatusFilter';

const STATUSES = ['pending', 'open', 'snoozed', 'resolved'];

const statusFilter = (value, queryOperator = 'and') => ({
  attribute_key: 'status',
  filter_operator: 'equal_to',
  values: [{ id: value, name: value }],
  query_operator: queryOperator,
});

const labelFilter = (queryOperator = 'and') => ({
  attribute_key: 'labels',
  filter_operator: 'equal_to',
  values: [{ id: 'vip', name: 'vip' }],
  query_operator: queryOperator,
});

describe('conversationStatusFilter', () => {
  it('extracts a single simple status condition', () => {
    expect(
      extractSingleStatusFilter([labelFilter(), statusFilter('open')], STATUSES)
    ).toBe('open');
    expect(
      extractSingleStatusFilter([statusFilter('all')], STATUSES)
    ).toBeNull();
  });

  it('replaces the simple status condition with the page status', () => {
    expect(
      mergeRouteStatusFilter(
        [labelFilter(), statusFilter('open')],
        'resolved',
        STATUSES
      )[1].values
    ).toEqual(['resolved']);
  });

  describe('#removeRouteStatusFilter', () => {
    it('drops the simple status condition for all statuses', () => {
      expect(
        removeRouteStatusFilter([labelFilter(), statusFilter('open')], STATUSES)
      ).toEqual([labelFilter()]);
    });

    it('returns an empty list when status was the only condition', () => {
      expect(removeRouteStatusFilter([statusFilter('open')], STATUSES)).toEqual(
        []
      );
    });

    it('keeps complex status expressions untouched', () => {
      const orFilters = [statusFilter('open', 'or'), statusFilter('pending')];
      const twoStatuses = [statusFilter('open'), statusFilter('pending')];

      expect(removeRouteStatusFilter(orFilters, STATUSES)).toBe(orFilters);
      expect(removeRouteStatusFilter(twoStatuses, STATUSES)).toBe(twoStatuses);
    });

    it('keeps filters without a status condition untouched', () => {
      const filters = [labelFilter()];

      expect(removeRouteStatusFilter(filters, STATUSES)).toBe(filters);
      expect(removeRouteStatusFilter(undefined, STATUSES)).toBeUndefined();
    });
  });
});
