import { describe, expect, it } from 'vitest';

import {
  buildCustomFieldSummary,
  formatCustomFieldValue,
  resolveCustomFieldEntries,
} from './customFieldFormatter';

describe('customFieldFormatter', () => {
  const locale = 'en';

  it('formats typed values and skips empty entries', () => {
    const definitions = [
      {
        fieldType: 'select',
        key: 'visit_reason',
        label: 'Visit Reason',
        options: [{ label: 'Follow-up', value: 'follow_up' }],
      },
      {
        fieldType: 'checkbox',
        key: 'requires_follow_up',
        label: 'Requires Follow-up',
      },
      {
        fieldType: 'multiselect',
        key: 'visit_tags',
        label: 'Tags',
        options: ['VIP', 'Urgent'],
      },
      {
        fieldType: 'percent',
        key: 'discount',
        label: 'Discount',
      },
      {
        active: false,
        fieldType: 'text',
        key: 'inactive_field',
        label: 'Inactive',
      },
    ];

    const entries = resolveCustomFieldEntries(
      definitions,
      {
        discount: 15,
        inactive_field: 'hidden',
        requires_follow_up: true,
        visit_reason: 'follow_up',
        visit_tags: ['VIP', 'Urgent'],
      },
      { locale, yesLabel: 'Yes' }
    );

    expect(entries).toEqual([
      {
        displayValue: 'Follow-up',
        key: 'visit_reason',
        label: 'Visit Reason',
      },
      {
        displayValue: 'Yes',
        key: 'requires_follow_up',
        label: 'Requires Follow-up',
      },
      {
        displayValue: 'VIP, Urgent',
        key: 'visit_tags',
        label: 'Tags',
      },
      {
        displayValue: '15%',
        key: 'discount',
        label: 'Discount',
      },
    ]);
  });

  it('truncates summaries to the requested limit', () => {
    const summary = buildCustomFieldSummary(
      [
        { fieldType: 'text', key: 'one', label: 'One' },
        { fieldType: 'text', key: 'two', label: 'Two' },
      ],
      { one: 'A', two: 'B' },
      { locale, maxItems: 1 }
    );

    expect(summary).toEqual([
      {
        displayValue: 'A',
        key: 'one',
        label: 'One',
      },
    ]);
  });

  it('returns null for unchecked checkboxes and formats datetime values', () => {
    expect(
      formatCustomFieldValue({ fieldType: 'checkbox', key: 'notify' }, false, {
        locale,
        noLabel: 'No',
        yesLabel: 'Yes',
      })
    ).toBeNull();

    expect(
      formatCustomFieldValue(
        { fieldType: 'datetime', key: 'visit_at' },
        '2026-03-29T08:30:00.000Z',
        { locale }
      )
    ).toContain('2026');
  });

  it('formats date-only values without shifting the calendar day', () => {
    expect(
      formatCustomFieldValue(
        { fieldType: 'date', key: 'follow_up_on' },
        '2026-03-10',
        { locale }
      )
    ).toContain('10');
  });
});
