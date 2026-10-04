import { describe, expect, it } from 'vitest';

import {
  buildCustomFieldSummary,
  buildLocalizedDateSearchAliases,
  buildLocalizedNumberSearchAlias,
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

  it('reverses locale-formatted date and datetime search values', () => {
    const rawDate = '2026-09-18';
    ['en', 'ru', 'kk'].forEach(searchLocale => {
      const displayedDate = formatCustomFieldValue(
        { fieldType: 'date' },
        rawDate,
        { locale: searchLocale }
      );
      expect(
        buildLocalizedDateSearchAliases(displayedDate, searchLocale)
      ).toEqual({
        dateAlias: rawDate,
        datetimeAlias: '',
      });
    });

    const rawDatetime = '2026-09-18T08:30:00.000Z';
    const displayedDatetime = formatCustomFieldValue(
      { fieldType: 'datetime' },
      rawDatetime,
      { locale: 'en' }
    );
    expect(buildLocalizedDateSearchAliases(displayedDatetime, 'en')).toEqual({
      dateAlias: '2026-09-18',
      datetimeAlias: '2026-09-18T08:30Z',
    });

    const offsetDatetime = '2026-09-18T20:30:00-05:00';
    const displayedOffsetDatetime = formatCustomFieldValue(
      { fieldType: 'datetime' },
      offsetDatetime,
      { locale: 'en' }
    );
    expect(
      buildLocalizedDateSearchAliases(displayedOffsetDatetime, 'en')
        .datetimeAlias
    ).toBe(`${new Date(offsetDatetime).toISOString().slice(0, 16)}Z`);
  });

  it('rejects broad, invalid and trailing localized date aliases', () => {
    expect(buildLocalizedDateSearchAliases('market 1 2026', 'en')).toEqual({
      dateAlias: '',
      datetimeAlias: '',
    });
    expect(
      buildLocalizedDateSearchAliases('Sep 18, 2026, 25:99', 'en')
    ).toEqual({ dateAlias: '', datetimeAlias: '' });

    const displayedDate = formatCustomFieldValue(
      { fieldType: 'date' },
      '2026-09-18',
      { locale: 'en' }
    );
    expect(
      buildLocalizedDateSearchAliases(`${displayedDate} trailing`, 'en')
    ).toEqual({ dateAlias: '', datetimeAlias: '' });
  });

  it('reverses exact locale-formatted numbers with grouping separators', () => {
    expect(buildLocalizedNumberSearchAlias('1,000', 'en')).toBe('1000');
    expect(buildLocalizedNumberSearchAlias('1 000', 'ru')).toBe('1000');
    expect(buildLocalizedNumberSearchAlias('1,000 trailing', 'en')).toBe('');
    expect(buildLocalizedNumberSearchAlias('15%', 'en')).toBe('');
  });
});
