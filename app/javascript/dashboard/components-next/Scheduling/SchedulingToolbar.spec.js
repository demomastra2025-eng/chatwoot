import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import SchedulingToolbar from './SchedulingToolbar.vue';

const global = {
  stubs: {
    Button: {
      props: ['icon'],
      template: '<button :data-role="icon" />',
    },
    DateTimePicker: {
      template: '<button data-role="date" />',
    },
    SchedulingViewSwitcher: {
      template: '<div data-role="calendar-range" />',
    },
  },
};

const defaultProps = {
  anchorDate: '2026-09-03',
  currentLabel: '3 сентября 2026',
  modelValue: 'day',
  showToday: false,
  views: [{ label: 'День', value: 'day' }],
};

describe('SchedulingToolbar', () => {
  it('orders presentation, range, and date controls from left to right', () => {
    const wrapper = mount(SchedulingToolbar, {
      global,
      props: defaultProps,
      slots: {
        actions: '<div data-role="actions" />',
        leading: '<div data-role="presentation" />',
      },
    });

    expect(
      wrapper.findAll('[data-role]').map(node => node.attributes('data-role'))
    ).toEqual([
      'presentation',
      'calendar-range',
      'i-lucide-chevron-left',
      'date',
      'i-lucide-chevron-right',
      'actions',
    ]);
  });
});
