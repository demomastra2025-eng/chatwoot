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

const CalendarWeekStub = {
  emits: ['selectDate'],
  template: '<div data-testid="calendar-month" />',
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
        CalendarWeek: CalendarWeekStub,
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

  it('opens the compact calendar-only range picker immediately', async () => {
    wrapper = mountDatePicker({
      autoOpen: true,
      calendarOnly: true,
      compact: true,
      hideTrigger: true,
      rangeType: 'custom',
    });
    await nextTick();
    await nextTick();

    expect(wrapper.find('[data-testid="date-picker-trigger"]').exists()).toBe(
      false
    );
    expect(wrapper.find('.w-\\[340px\\]').exists()).toBe(true);
    expect(wrapper.find('.scale-\\[0\\.8\\]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="date-range-preset"]').exists()).toBe(
      false
    );

    const calendars = wrapper.findAllComponents(CalendarWeekStub);
    expect(calendars).toHaveLength(1);
    calendars[0].vm.$emit('selectDate', new Date(2026, 0, 10, 12));
    await nextTick();
    calendars[0].vm.$emit('selectDate', new Date(2026, 0, 20, 12));
    await nextTick();

    const [[start, end]] = wrapper.emitted('dateRangeChanged')[0];
    expect(start.getHours()).toBe(0);
    expect(end.getHours()).toBe(23);
    expect(end.getMinutes()).toBe(59);
    expect(wrapper.find('.w-\\[340px\\]').exists()).toBe(false);
  });

  it('can center a compact calendar under its trigger', async () => {
    wrapper = mountDatePicker({
      calendarOnly: true,
      compact: true,
      popoverAlign: 'center',
    });

    await wrapper.get('[data-testid="date-picker-trigger"]').trigger('click');

    const popover = wrapper.get('.w-\\[340px\\]');
    expect(popover.classes()).toContain('left-1/2');
    expect(popover.classes()).toContain('-translate-x-1/2');
    expect(popover.classes()).toContain('scale-[0.8]');
  });

  it('keeps presets beside a compact single calendar', async () => {
    wrapper = mountDatePicker({
      compact: true,
      compactScale: 'medium',
      singleCalendar: true,
    });

    await wrapper.get('[data-testid="date-picker-trigger"]').trigger('click');

    expect(wrapper.find('.w-\\[540px\\]').exists()).toBe(true);
    expect(wrapper.find('.scale-\\[0\\.9\\]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="date-range-preset"]').exists()).toBe(
      true
    );
    expect(wrapper.findAllComponents(CalendarWeekStub)).toHaveLength(1);
  });

  it('opens only after the Select click that mounted it has propagated', async () => {
    document.body.addEventListener(
      'click',
      () => {
        wrapper = mountDatePicker({
          autoOpen: true,
          calendarOnly: true,
          hideTrigger: true,
          rangeType: 'custom',
        });
      },
      { once: true }
    );

    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(wrapper.find('.w-\\[340px\\]').exists()).toBe(false);

    await nextTick();
    await nextTick();

    expect(wrapper.find('.w-\\[340px\\]').exists()).toBe(true);
  });

  it('keeps a force-open calendar visible during outside interaction', async () => {
    wrapper = mountDatePicker({
      calendarOnly: true,
      forceOpen: true,
      hideTrigger: true,
      rangeType: 'custom',
    });

    document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await nextTick();

    expect(wrapper.find('.w-\\[340px\\]').exists()).toBe(true);
  });
});
