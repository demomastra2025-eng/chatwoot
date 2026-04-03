import { describe, expect, it } from 'vitest';

import {
  buildAdvancedCustomFieldOperatorOptions,
  buildCustomFieldFilterOptions,
  buildCustomFieldFilterSummary,
  normalizeCustomFieldFilters,
  recordMatchesCustomFieldFilters,
} from './customFieldFilters';

describe('crm customFieldFilters', () => {
  const definitions = [
    {
      fieldType: 'select',
      key: 'deal_size_band',
      label: 'Deal size',
      options: [{ label: 'Enterprise', value: 'enterprise' }],
    },
    {
      fieldType: 'multiselect',
      key: 'task_tags',
      label: 'Task tags',
      options: ['VIP', 'Docs'],
    },
    {
      fieldType: 'checkbox',
      key: 'needs_follow_up',
      label: 'Needs follow-up',
    },
    {
      fieldType: 'text',
      key: 'resolution_note',
      label: 'Resolution note',
    },
    {
      fieldType: 'number',
      key: 'budget_score',
      label: 'Budget score',
    },
    {
      fieldType: 'date',
      key: 'follow_up_on',
      label: 'Follow up on',
    },
    {
      fieldType: 'datetime',
      key: 'triage_at',
      label: 'Triage at',
    },
  ];

  it('builds filter options for supported discrete field types', () => {
    expect(
      buildCustomFieldFilterOptions(definitions[0], {
        noLabel: 'No',
        yesLabel: 'Yes',
      })
    ).toEqual([{ label: 'Enterprise', value: 'enterprise' }]);

    expect(
      buildCustomFieldFilterOptions(definitions[2], {
        noLabel: 'No',
        yesLabel: 'Yes',
      })
    ).toEqual([
      { label: 'Yes', value: true },
      { label: 'No', value: false },
    ]);
  });

  it('matches generic CRM records against discrete and advanced filters', () => {
    const record = {
      customAttributes: {
        budget_score: 92,
        deal_size_band: 'enterprise',
        follow_up_on: '2026-04-05',
        needs_follow_up: true,
        resolution_note: 'Needs urgent approval',
        task_tags: ['VIP'],
        triage_at: '2026-03-09T10:15:00+05:00',
      },
    };

    expect(
      recordMatchesCustomFieldFilters(record, definitions, {
        budget_score: { operator: 'greater_than', value: 50 },
        deal_size_band: ['enterprise'],
        follow_up_on: { operator: 'before', value: '2026-04-06' },
        needs_follow_up: [true],
        resolution_note: { operator: 'contains', value: 'urgent' },
        task_tags: ['VIP'],
        triage_at: {
          operator: 'after',
          value: '2026-03-09T05:00:00.000Z',
        },
      })
    ).toBe(true);
  });

  it('builds advanced operator options and summaries', () => {
    const labels = {
      operators: {
        contains: 'Contains',
        equals: 'Equals',
        is_present: 'Is filled',
      },
    };

    expect(
      buildAdvancedCustomFieldOperatorOptions(definitions[3], labels)
    ).toEqual([
      { label: 'Contains', value: 'contains' },
      { label: 'Equals', value: 'equals' },
      { label: 'Is filled', value: 'is_present' },
      { label: 'is_not_present', value: 'is_not_present' },
    ]);

    expect(
      buildCustomFieldFilterSummary(
        definitions[3],
        {
          operator: 'contains',
          value: 'urgent',
        },
        labels
      )
    ).toBe('Contains: urgent');
  });

  it('prunes stale or unsupported filters when definitions change', () => {
    expect(
      normalizeCustomFieldFilters(
        definitions,
        {
          budget_score: { operator: 'greater_than', value: 70 },
          deal_size_band: ['enterprise', 'unknown'],
          needs_follow_up: [true, 'unexpected'],
          unknown_key: ['value'],
        },
        {
          noLabel: 'No',
          operators: {
            greater_than: 'Greater than',
          },
          yesLabel: 'Yes',
        }
      )
    ).toEqual({
      budget_score: {
        operator: 'greater_than',
        value: 70,
      },
      deal_size_band: ['enterprise'],
      needs_follow_up: [true],
    });
  });

  it('rejects impossible date and datetime filter values during normalization', () => {
    expect(
      normalizeCustomFieldFilters(definitions, {
        follow_up_on: { operator: 'before', value: '2026-02-30' },
        triage_at: { operator: 'after', value: '2026-02-30T10:00' },
      })
    ).toEqual({});
  });
});
