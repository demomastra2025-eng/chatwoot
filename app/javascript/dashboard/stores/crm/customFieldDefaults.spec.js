import { describe, expect, it } from 'vitest';

import {
  buildDefaultCustomAttributes,
  mergeMissingDefaultCustomAttributes,
} from './customFieldDefaults';

describe('customFieldDefaults', () => {
  it('builds default custom attributes with cloned array values', () => {
    const definitions = [
      {
        defaultValue: ['initial', 'follow_up'],
        key: 'visit_tags',
      },
    ];

    const attributes = buildDefaultCustomAttributes(definitions);
    attributes.visit_tags.push('extra');

    expect(attributes).toEqual({
      visit_tags: ['initial', 'follow_up', 'extra'],
    });
    expect(definitions[0].defaultValue).toEqual(['initial', 'follow_up']);
  });

  it('merges only missing defaults without overriding existing values', () => {
    const attributes = mergeMissingDefaultCustomAttributes(
      { visit_reason: 'custom', source_mode: 'imported' },
      [
        { defaultValue: 'initial consult', key: 'visit_reason' },
        { defaultValue: ['vip'], key: 'visit_tags' },
      ]
    );

    expect(attributes).toEqual({
      visit_reason: 'custom',
      source_mode: 'imported',
      visit_tags: ['vip'],
    });
  });
});
