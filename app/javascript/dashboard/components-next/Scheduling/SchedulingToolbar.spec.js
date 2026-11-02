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
  it('uses two mobile rows and exposes all navigation events with accessible names', async () => {
    const wrapper = mount(SchedulingToolbar, {
      global,
      props: { ...defaultProps, mobile: true },
      slots: {
        'mobile-create': '<div data-role="create" />',
        'mobile-view': '<div data-role="view-menu" />',
        'mobile-filters': '<div data-role="resources-filters" />',
      },
    });
    expect(
      wrapper.findAll('[data-role]').map(node => node.attributes('data-role'))
    ).toEqual([
      'i-lucide-chevron-left',
      'date',
      'i-lucide-chevron-right',
      'create',
      'view-menu',
      'resources-filters',
    ]);
    expect(
      wrapper
        .find('[data-role="i-lucide-chevron-left"]')
        .attributes('aria-label')
    ).toBeTruthy();
    expect(
      wrapper
        .find('[data-role="i-lucide-chevron-right"]')
        .attributes('aria-label')
    ).toBeTruthy();
    await wrapper.find('[data-role="i-lucide-chevron-left"]').trigger('click');
    await wrapper.find('[data-role="i-lucide-chevron-right"]').trigger('click');
    expect(wrapper.emitted('previous')).toHaveLength(1);
    expect(wrapper.emitted('next')).toHaveLength(1);
    expect(wrapper.find('[data-role="calendar-range"]').exists()).toBe(false);
  });
});
