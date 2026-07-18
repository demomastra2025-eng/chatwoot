import { describe, expect, it } from 'vitest';
import { extractSingleStatusFilter } from './conversationStatusFilter';

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
