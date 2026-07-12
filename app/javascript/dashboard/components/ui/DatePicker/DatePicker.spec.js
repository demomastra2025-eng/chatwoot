import { mount } from '@vue/test-utils';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';

import DatePicker from './DatePicker.vue';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const DatePickerButtonStub = {
  emits: ['open', 'navigateMonth'],
  template: `
    <button
      data-testid="date-picker-trigger"
      @click="$emit('open')"
    />
  `,
};

const CalendarDateRangeStub = {
  emits: ['setRange'],
  template: `
    <button
      data-testid="date-range-preset"
      @click="$emit('setRange', { value: 'today' })"
    />
  `,
};

const mountDatePicker = (props = {}) =>
  mount(DatePicker, {
    attachTo: document.body,
    props,
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        CalendarDateInput: true,
        CalendarDateRange: CalendarDateRangeStub,
        CalendarFooter: true,
        CalendarMonth: true,
        CalendarWeek: true,
        CalendarYear: true,
        DatePickerButton: DatePickerButtonStub,
      },
    },
  });

describe('DatePicker outside interaction', () => {
  let wrapper;

  afterEach(() => {
    wrapper?.unmount();
    document.body.innerHTML = '';
  });

  it('closes the date range popover without changing an inactive filter', async () => {
    wrapper = mountDatePicker({ active: false });

    await wrapper.get('[data-testid="date-picker-trigger"]').trigger('click');
    expect(wrapper.find('.w-\\[880px\\]').exists()).toBe(true);

    await new Promise(resolve => {
      setTimeout(resolve, 0);
    });
    document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await nextTick();

    expect(wrapper.find('.w-\\[880px\\]').exists()).toBe(false);
    expect(wrapper.emitted('dateRangeChanged')).toBeUndefined();
  });

  it('emits a range on outside click after the user changes the selection', async () => {
    wrapper = mountDatePicker({ active: false });

    await wrapper.get('[data-testid="date-picker-trigger"]').trigger('click');
    await wrapper.get('[data-testid="date-range-preset"]').trigger('click');

    await new Promise(resolve => {
      setTimeout(resolve, 0);
    });
    document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await nextTick();

    expect(wrapper.find('.w-\\[880px\\]').exists()).toBe(false);
    expect(wrapper.emitted('dateRangeChanged')).toHaveLength(1);
  });
});
