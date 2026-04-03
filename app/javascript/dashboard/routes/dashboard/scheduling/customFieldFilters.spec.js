import { describe, expect, it } from 'vitest';

import {
  appointmentMatchesCustomFieldFilters,
  buildSchedulingAdvancedCustomFieldOperatorOptions,
  buildSchedulingCustomFieldFilterOptions,
  buildSchedulingCustomFieldFilterSummary,
  normalizeSchedulingCustomFieldFilters,
} from './customFieldFilters';

describe('customFieldFilters', () => {
  const definitions = [
    {
      fieldType: 'select',
      key: 'visit_reason',
      label: 'Visit Reason',
      options: [{ label: 'Follow-up', value: 'follow_up' }],
    },
    {
      fieldType: 'multiselect',
      key: 'visit_tags',
      label: 'Tags',
      options: ['VIP', 'Urgent'],
    },
    {
      fieldType: 'checkbox',
      key: 'needs_lab',
      label: 'Needs Lab',
    },
    {
      fieldType: 'text',
      key: 'notes',
      label: 'Notes',
    },
    {
      fieldType: 'number',
      key: 'visit_score',
      label: 'Visit score',
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

  it('builds filter options for supported field types', () => {
    expect(
      buildSchedulingCustomFieldFilterOptions(definitions[0], {
        noLabel: 'No',
        yesLabel: 'Yes',
      })
    ).toEqual([{ label: 'Follow-up', value: 'follow_up' }]);

    expect(
      buildSchedulingCustomFieldFilterOptions(definitions[2], {
        noLabel: 'No',
        yesLabel: 'Yes',
      })
    ).toEqual([
      { label: 'Yes', value: true },
      { label: 'No', value: false },
    ]);
  });

  it('matches appointments against select, multiselect, and checkbox filters', () => {
    const appointment = {
      customAttributes: {
        needs_lab: true,
        visit_reason: 'follow_up',
        visit_tags: ['VIP'],
      },
    };

    expect(
      appointmentMatchesCustomFieldFilters(appointment, definitions, {
        needs_lab: [true],
        visit_reason: ['follow_up'],
        visit_tags: ['VIP'],
      })
    ).toBe(true);

    expect(
      appointmentMatchesCustomFieldFilters(appointment, definitions, {
        needs_lab: [false],
      })
    ).toBe(false);
  });

  it('builds advanced operator options and summaries for advanced field types', () => {
    const labels = {
      operators: {
        contains: 'Contains',
        equals: 'Equals',
        is_present: 'Is filled',
      },
    };

    expect(
      buildSchedulingAdvancedCustomFieldOperatorOptions(definitions[3], labels)
    ).toEqual([
      { label: 'Contains', value: 'contains' },
      { label: 'Equals', value: 'equals' },
      { label: 'Is filled', value: 'is_present' },
      { label: 'is_not_present', value: 'is_not_present' },
    ]);
    expect(
      buildSchedulingCustomFieldFilterSummary(
        definitions[3],
        {
          operator: 'contains',
          value: 'follow-up',
        },
        labels
      )
    ).toBe('Contains: follow-up');
  });

  it('matches appointments against text, number, date, and datetime filters', () => {
    const appointment = {
      customAttributes: {
        follow_up_on: '2026-03-10',
        notes: 'Needs urgent follow-up',
        triage_at: '2026-03-09T10:15:00+05:00',
        visit_score: 9,
      },
    };

    expect(
      appointmentMatchesCustomFieldFilters(appointment, definitions, {
        notes: { operator: 'contains', value: 'follow-up' },
        visit_score: { operator: 'greater_than', value: 5 },
        follow_up_on: { operator: 'before', value: '2026-03-11' },
        triage_at: {
          operator: 'after',
          value: '2026-03-09T05:00:00.000Z',
        },
      })
    ).toBe(true);

    expect(
      appointmentMatchesCustomFieldFilters(appointment, definitions, {
        notes: { operator: 'is_not_present' },
      })
    ).toBe(false);
  });

  it('prunes stale or unsupported filters when definitions change', () => {
    expect(
      normalizeSchedulingCustomFieldFilters(
        definitions,
        {
          needs_lab: [true, 'unexpected'],
          notes: { operator: 'contains', value: 'free_text' },
          triage_at: {
            operator: 'after',
            value: '2026-03-09T09:00:00.000Z',
          },
          visit_reason: ['follow_up', 'unknown'],
        },
        {
          noLabel: 'No',
          operators: {
            after: 'After',
            contains: 'Contains',
          },
          yesLabel: 'Yes',
        }
      )
    ).toEqual({
      needs_lab: [true],
      notes: {
        operator: 'contains',
        value: 'free_text',
      },
      triage_at: {
        operator: 'after',
        value: '2026-03-09T09:00:00.000Z',
      },
      visit_reason: ['follow_up'],
    });
  });

  it('rejects impossible date and datetime filter values during normalization', () => {
    expect(
      normalizeSchedulingCustomFieldFilters(definitions, {
        follow_up_on: { operator: 'before', value: '2026-02-30' },
        triage_at: { operator: 'after', value: '2026-02-30T10:00' },
      })
    ).toEqual({});
  });
});
