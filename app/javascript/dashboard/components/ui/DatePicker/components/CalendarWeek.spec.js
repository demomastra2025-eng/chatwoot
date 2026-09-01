import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import CalendarWeek from './CalendarWeek.vue';

const march = new Date(2026, 2, 1);

const mountCalendar = () =>
  mount(CalendarWeek, {
    props: {
      calendarType: 'start',
      currentDate: march,
      endCurrentDate: new Date(2026, 3, 1),
      selectedEndDate: new Date(2026, 2, 10),
      selectedStartDate: new Date(2026, 2, 1),
      startCurrentDate: march,
    },
    global: {
      stubs: {
        CalendarAction: true,
        CalendarWeekLabel: true,
      },
    },
  });

describe('CalendarWeek', () => {
  it('allows selecting a visible day from an adjacent month', async () => {
    const wrapper = mountCalendar();
    const firstVisibleDay = wrapper.findAll('.cursor-pointer')[0];

    expect(firstVisibleDay.text()).toBe('23');
    expect(firstVisibleDay.classes()).not.toContain('pointer-events-none');

    await firstVisibleDay.trigger('click');

    const selectedDate = wrapper.emitted('selectDate')[0][0];
    expect(selectedDate.getFullYear()).toBe(2026);
    expect(selectedDate.getMonth()).toBe(1);
    expect(selectedDate.getDate()).toBe(23);
  });
});
