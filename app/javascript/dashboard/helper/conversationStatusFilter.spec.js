import { describe, expect, it } from 'vitest';
import {
  extractSingleStatusFilter,
  mergeRouteStatusFilter,
} from './conversationStatusFilter';

const statuses = ['open', 'pending', 'snoozed', 'resolved'];

describe('extractSingleStatusFilter', () => {
  it('extracts a single snake-case status filter', () => {
    expect(
      extractSingleStatusFilter(
        [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['open'],
          },
        ],
        statuses
      )
    ).toBe('open');
  });

  it('supports the camel-case filter shape used by the filter modal', () => {
    expect(
      extractSingleStatusFilter(
        [
          {
            attributeKey: 'status',
            filterOperator: 'equal_to',
            values: [{ id: 'resolved' }],
          },
        ],
        statuses
      )
    ).toBe('resolved');
  });

  it('does not collapse multi-status or OR filters into the route status', () => {
    expect(
      extractSingleStatusFilter(
        [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['open', 'pending'],
          },
        ],
        statuses
      )
    ).toBeNull();

    expect(
      extractSingleStatusFilter(
        [
          {
            attribute_key: 'assignee_id',
            filter_operator: 'equal_to',
            query_operator: 'or',
            values: ['7'],
          },
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['open'],
          },
        ],
        statuses
      )
    ).toBeNull();
  });

  it('does not collapse unsupported status operators', () => {
    expect(
      extractSingleStatusFilter(
        [
          {
            attribute_key: 'status',
            filter_operator: 'not_equal_to',
            values: ['resolved'],
          },
        ],
        statuses
      )
    ).toBeNull();
  });
});

describe('mergeRouteStatusFilter', () => {
  it('adds the route status when advanced filters have no status filter', () => {
    const filters = [
      {
        attribute_key: 'labels',
        filter_operator: 'equal_to',
        values: ['vip'],
        query_operator: 'and',
      },
    ];

    expect(mergeRouteStatusFilter(filters, 'pending', statuses)).toEqual([
      ...filters,
      {
        attribute_key: 'status',
        filter_operator: 'equal_to',
        values: ['pending'],
        query_operator: 'and',
      },
    ]);
  });

  it('replaces a singleton status while preserving the other filters', () => {
    const filters = [
      {
        attributeKey: 'status',
        filterOperator: 'equal_to',
        values: [{ id: 'open', name: 'Open' }],
      },
      {
        attributeKey: 'labels',
        filterOperator: 'equal_to',
        values: [{ id: 'vip' }],
      },
    ];

    expect(mergeRouteStatusFilter(filters, 'resolved', statuses)).toEqual([
      { ...filters[0], values: ['resolved'] },
      filters[1],
    ]);
  });

  it('does not alter complex status filters', () => {
    const filters = [
      {
        attribute_key: 'status',
        filter_operator: 'equal_to',
        values: ['open', 'pending'],
        query_operator: 'and',
      },
    ];

    expect(mergeRouteStatusFilter(filters, 'resolved', statuses)).toBe(filters);
  });

  it('does not append status to OR expressions', () => {
    const filters = [
      {
        attribute_key: 'assignee_id',
        filter_operator: 'equal_to',
        values: ['7'],
        query_operator: 'or',
      },
      {
        attribute_key: 'labels',
        filter_operator: 'equal_to',
        values: ['vip'],
        query_operator: 'and',
      },
    ];

    expect(mergeRouteStatusFilter(filters, 'pending', statuses)).toBe(filters);
  });
});
