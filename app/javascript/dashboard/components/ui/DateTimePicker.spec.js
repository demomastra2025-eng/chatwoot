import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import DateTimePicker from './DateTimePicker.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'en' },
    t: key => key,
  }),
}));

const passthroughStub = {
  template: '<div><slot /></div>',
};

const calendarStub = {
  template: '<div><slot :week-days="[]" :grid="[]" /></div>',
};

const stubs = {
  DatePickerRoot: passthroughStub,
  DatePickerTrigger: passthroughStub,
  DatePickerContent: { template: '<div><slot /></div>' },
  DatePickerCalendar: calendarStub,
  DatePickerHeader: passthroughStub,
  DatePickerPrev: passthroughStub,
  DatePickerNext: passthroughStub,
  DatePickerGrid: passthroughStub,
  DatePickerGridHead: passthroughStub,
  DatePickerGridBody: passthroughStub,
  DatePickerGridRow: passthroughStub,
  DatePickerHeadCell: passthroughStub,
  DatePickerCell: passthroughStub,
  DatePickerCellTrigger: passthroughStub,
  MonthPickerRoot: calendarStub,
  MonthPickerHeader: passthroughStub,
  MonthPickerPrev: passthroughStub,
  MonthPickerNext: passthroughStub,
  MonthPickerHeading: passthroughStub,
  MonthPickerGrid: passthroughStub,
  MonthPickerGridBody: passthroughStub,
  MonthPickerGridRow: passthroughStub,
  MonthPickerCell: passthroughStub,
  MonthPickerCellTrigger: passthroughStub,
  YearPickerRoot: calendarStub,
  YearPickerHeader: passthroughStub,
  YearPickerPrev: passthroughStub,
  YearPickerNext: passthroughStub,
  YearPickerHeading: passthroughStub,
  YearPickerGrid: passthroughStub,
  YearPickerGridBody: passthroughStub,
  YearPickerGridRow: passthroughStub,
  YearPickerCell: passthroughStub,
  YearPickerCellTrigger: passthroughStub,
  TimeWheelPicker: { template: '<div class="time-wheel-picker-stub" />' },
  TimeFieldRoot: passthroughStub,
  TimeFieldInput: passthroughStub,
  PopoverRoot: passthroughStub,
  PopoverTrigger: passthroughStub,
  PopoverPortal: passthroughStub,
  PopoverContent: passthroughStub,
};

describe('DateTimePicker', () => {
  it('vertically centers the time wheel panel in datetime picker popup', () => {
    const wrapper = mount(DateTimePicker, {
      props: {
        type: 'datetime',
        value: new Date('2026-04-24T12:30:00'),
        timePickerVariant: 'wheel',
      },
      global: { stubs },
    });

    const timeWheel = wrapper.find('.time-wheel-picker-stub');
    expect(timeWheel.exists()).toBe(true);

    const timePanelClasses = Array.from(
      timeWheel.element.parentElement.classList
    );
    expect(timePanelClasses).toContain('self-center');
    expect(timePanelClasses).not.toContain('self-start');
  });
});
