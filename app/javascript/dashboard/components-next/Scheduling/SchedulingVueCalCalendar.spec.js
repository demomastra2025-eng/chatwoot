import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { VueCal } from 'vue-cal';
import { useAlert } from 'dashboard/composables';

import SchedulingVueCalCalendar from './SchedulingVueCalCalendar.vue';

vi.mock('vue-i18n');
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const baseProps = {
  anchorDate: '2026-03-09T00:00:00.000Z',
  appointments: [],
  breakRules: [],
  customFieldDefinitions: [],
  holidays: [],
  resources: [
    {
      id: 12,
      name: 'Dr. Sam',
      color: '#0f766e',
      slotDurationMin: 30,
    },
  ],
  slots: [],
  timeOffs: [],
  view: 'week',
  workRules: [],
  workdayOverrides: [],
};

let mountedWrappers = [];
const originalScrollTo = HTMLElement.prototype.scrollTo;

const mountCalendar = (props, options = {}) => {
  const wrapper = mount(SchedulingVueCalCalendar, {
    props: {
      ...baseProps,
      ...props,
    },
    attachTo: document.body,
    ...options,
  });

  mountedWrappers.push(wrapper);
  return wrapper;
};

describe('SchedulingVueCalCalendar', () => {
  beforeEach(() => {
    HTMLElement.prototype.scrollTo = vi.fn();
    useI18n.mockReturnValue({
      locale: { value: 'en' },
      t: vi.fn((key, params = {}) => {
        const labels = {
          'CHOICE_TOGGLE.NO': 'No',
          'CHOICE_TOGGLE.YES': 'Yes',
          'SCHEDULING.CALENDAR.ALL_RESOURCES_UNAVAILABLE':
            'All specialists unavailable',
          'SCHEDULING.CALENDAR.RESOURCES_UNAVAILABLE': `Unavailable: ${params.names}`,
          'SCHEDULING.CALENDAR.UNAVAILABLE': 'Unavailable',
          'SCHEDULING.CALENDAR.UNAVAILABLE_TIME_RANGE': `${params.label} · ${params.start}–${params.end}`,
        };

        return labels[key] || key;
      }),
    });
  });

  afterEach(() => {
    mountedWrappers.forEach(wrapper => wrapper.unmount());
    mountedWrappers = [];
    document.body.innerHTML = '';
    HTMLElement.prototype.scrollTo = originalScrollTo;
    vi.useRealTimers();
  });

  it('renders unavailable time as background events in timeline views', async () => {
    const wrapper = mountCalendar({
      workRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 540,
          endMinute: 600,
          weekday: 1,
        },
      ],
    });

    await nextTick();

    expect(
      wrapper.findAll('.scheduling-vue-cal__background-fill--unavailable')
        .length
    ).toBeGreaterThan(0);
  }, 30000);

  it('renders the same unavailable background for closed days', async () => {
    const wrapper = mountCalendar({
      workRules: [],
    });

    await nextTick();
    await nextTick();

    expect(
      wrapper.findAll('.scheduling-vue-cal__background-fill--unavailable')
        .length
    ).toBeGreaterThan(0);
  });

  it('renders breaks as background events in timeline views', async () => {
    const wrapper = mountCalendar({
      breakRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 720,
          endMinute: 780,
          title: 'Lunch',
          weekday: 1,
        },
      ],
    });

    await nextTick();

    expect(wrapper.text()).toContain('Lunch');
  });

  it('renders a leading status icon inside appointment event cards', async () => {
    const wrapper = mountCalendar({
      appointments: [
        {
          id: 44,
          clientName: 'Alex Doe',
          durationMin: 30,
          endsAt: '2026-03-09T10:30:00.000Z',
          resourceId: 12,
          serviceNameSnapshot: 'Consultation',
          startsAt: '2026-03-09T10:00:00.000Z',
          status: 'confirmed',
        },
      ],
    });

    await nextTick();
    await nextTick();

    expect(
      wrapper.find('.scheduling-vue-cal__event-status-icon').exists()
    ).toBe(true);
    expect(
      wrapper
        .find('.scheduling-vue-cal__event-status-icon .i-lucide-badge-check')
        .exists()
    ).toBe(true);
  }, 30000);

  it('opens an appointment from the keyboard-focusable event card', async () => {
    const appointment = {
      id: 48,
      clientName: 'Keyboard customer',
      endsAt: '2026-03-09T10:30:00.000Z',
      resourceId: 12,
      startsAt: '2026-03-09T10:00:00.000Z',
      status: 'scheduled',
    };
    const wrapper = mountCalendar({ appointments: [appointment] });

    await nextTick();
    await nextTick();

    const eventCard = wrapper.find('.scheduling-vue-cal__event-card');
    expect(eventCard.attributes('role')).toBe('button');
    expect(eventCard.attributes('tabindex')).toBe('0');

    await eventCard.trigger('keydown', { key: 'Enter' });

    expect(wrapper.emitted('selectAppointment')).toEqual([[appointment]]);
  });

  it('renders time and client name in a single event summary row', async () => {
    const wrapper = mountCalendar({
      appointments: [
        {
          id: 45,
          clientName: 'Alexandria Very Long Name',
          durationMin: 30,
          endsAt: '2026-03-09T11:30:00.000Z',
          resourceId: 12,
          resourceName: 'Dr. Sam',
          serviceNameSnapshot: 'Consultation',
          startsAt: '2026-03-09T11:00:00.000Z',
          status: 'scheduled',
        },
      ],
    });

    await nextTick();
    await nextTick();

    const summary = wrapper.find('.scheduling-vue-cal__event-summary');

    expect(summary.exists()).toBe(true);
    expect(summary.text()).toMatch(/\d{2}:\d{2}\s*-\s*\d{2}:\d{2}/);
    expect(summary.text()).toContain('Alexandria Very Long Name');

    const subtitle = wrapper.find('.scheduling-vue-cal__event-subtitle');
    expect(subtitle.text()).toContain('Dr. Sam');
  });

  it('omits synthetic times from all-day event text and accessible names', async () => {
    const wrapper = mountCalendar({
      allDayEvents: true,
      appointments: [
        {
          allDay: true,
          id: 49,
          clientName: 'All-day follow-up',
          endsAt: '2026-03-09T23:59:59.999Z',
          startsAt: '2026-03-09T00:00:00.000Z',
          status: 'scheduled',
        },
      ],
    });

    await nextTick();
    await nextTick();

    const eventCard = wrapper.find('.scheduling-vue-cal__event-card');
    expect(eventCard.text()).toContain('All-day follow-up');
    expect(eventCard.find('.scheduling-vue-cal__event-time').exists()).toBe(
      false
    );
    expect(eventCard.attributes('aria-label')).toContain('All-day follow-up');
    expect(eventCard.attributes('aria-label')).not.toMatch(/\d{2}:\d{2}/);
  });

  it('renders appointment times in the Workspace timezone', async () => {
    const appointment = {
      id: 81,
      clientName: 'Almaty client',
      endsAt: '2026-03-09T05:30:00.000Z',
      resourceId: 12,
      startsAt: '2026-03-09T05:00:00.000Z',
      status: 'scheduled',
    };
    const zoned = mountCalendar({
      appointments: [appointment],
      workspaceTimezone: 'Asia/Almaty',
    });
    const browserLocal = mountCalendar({ appointments: [appointment] });

    await nextTick();
    await nextTick();

    expect(zoned.find('.scheduling-vue-cal__event-time').text()).toBe(
      '10:00-10:30'
    );
    // Browser-local times, whatever the process timezone is.
    const localTime = value => {
      const date = new Date(value);
      return `${String(date.getHours()).padStart(2, '0')}:${String(
        date.getMinutes()
      ).padStart(2, '0')}`;
    };
    expect(browserLocal.find('.scheduling-vue-cal__event-time').text()).toBe(
      `${localTime(appointment.startsAt)}-${localTime(appointment.endsAt)}`
    );
  });

  it('keeps an appointment that crosses Workspace midnight on its calendar days', async () => {
    const wrapper = mountCalendar({
      appointments: [
        {
          id: 82,
          clientName: 'Late client',
          // 23:30-00:30 in Almaty (UTC+5).
          endsAt: '2026-03-09T19:30:00.000Z',
          resourceId: 12,
          startsAt: '2026-03-09T18:30:00.000Z',
          status: 'scheduled',
        },
      ],
      workspaceTimezone: 'Asia/Almaty',
    });

    await nextTick();

    const event = wrapper
      .findComponent(VueCal)
      .props('events')
      .find(item => item.id === '82');

    expect([
      event.start.getDate(),
      event.start.getHours(),
      event.start.getMinutes(),
    ]).toEqual([9, 23, 30]);
    expect([
      event.end.getDate(),
      event.end.getHours(),
      event.end.getMinutes(),
    ]).toEqual([10, 0, 30]);
  });

  it('emits UTC times for drag and resize in the Workspace timezone', async () => {
    const appointment = {
      id: 83,
      clientName: 'Moved client',
      endsAt: '2026-03-09T05:30:00.000Z',
      resourceId: 12,
      startsAt: '2026-03-09T05:00:00.000Z',
      status: 'scheduled',
    };
    const wrapper = mountCalendar({
      appointments: [appointment],
      workRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 540,
          endMinute: 1020,
          weekday: 1,
        },
      ],
      workspaceTimezone: 'Asia/Almaty',
    });

    await nextTick();

    const vueCal = wrapper.findComponent(VueCal);
    // vue-cal reports wall-clock dates: 11:05-11:35 on the Workspace calendar.
    vueCal.vm.$emit('eventDrop', {
      event: {
        appointment,
        end: new Date(2026, 2, 9, 11, 35),
        schedule: null,
        start: new Date(2026, 2, 9, 11, 5),
      },
    });
    vueCal.vm.$emit('eventResizeEnd', {
      event: {
        appointment,
        end: new Date(2026, 2, 9, 10, 45),
        start: new Date(2026, 2, 9, 10, 0),
      },
    });

    expect(wrapper.emitted('moveAppointment')).toEqual([
      [
        {
          appointment,
          endsAt: '2026-03-09T06:35:00.000Z',
          resourceId: 12,
          startsAt: '2026-03-09T06:05:00.000Z',
        },
      ],
    ]);
    expect(wrapper.emitted('resizeAppointment')).toEqual([
      [
        {
          appointment,
          endsAt: '2026-03-09T05:45:00.000Z',
          startsAt: '2026-03-09T05:00:00.000Z',
        },
      ],
    ]);
  });

  it('rejects a drop outside Workspace working hours', async () => {
    const appointment = {
      id: 84,
      clientName: 'Early client',
      endsAt: '2026-03-09T05:30:00.000Z',
      resourceId: 12,
      startsAt: '2026-03-09T05:00:00.000Z',
      status: 'scheduled',
    };
    const wrapper = mountCalendar({
      appointments: [appointment],
      workRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 540,
          endMinute: 1020,
          weekday: 1,
        },
      ],
      workspaceTimezone: 'Asia/Almaty',
    });

    await nextTick();

    // 08:00 on the Workspace calendar is before the 09:00 work rule even
    // though it is 03:00 UTC.
    wrapper.findComponent(VueCal).vm.$emit('eventDrop', {
      event: {
        appointment,
        end: new Date(2026, 2, 9, 8, 30),
        schedule: null,
        start: new Date(2026, 2, 9, 8, 0),
      },
    });

    expect(wrapper.emitted('moveAppointment')).toBeUndefined();
  });

  it('labels breaks and Workspace time off for a single specialist week', async () => {
    const wrapper = mountCalendar({
      breakRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 780,
          endMinute: 840,
          title: 'Lunch',
          weekday: 1,
        },
      ],
      timeOffs: [
        {
          id: 3,
          // 16:00-17:00 in Almaty.
          endsAt: '2026-03-09T12:00:00.000Z',
          resourceId: 12,
          startsAt: '2026-03-09T11:00:00.000Z',
          title: 'Training',
        },
      ],
      workRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 540,
          endMinute: 1080,
          weekday: 1,
        },
      ],
      workspaceTimezone: 'Asia/Almaty',
    });

    await nextTick();
    await nextTick();

    const labels = wrapper
      .findComponent(VueCal)
      .props('events')
      .filter(event => ['break', 'time-off'].includes(event.backgroundKind))
      .map(event => event.backgroundLabel);

    expect(labels).toEqual(
      expect.arrayContaining(['Lunch · 13:00–14:00', 'Training · 16:00–17:00'])
    );
    expect(wrapper.text()).toContain('Lunch · 13:00–14:00');
  });

  it('marks holidays as full-day backgrounds', async () => {
    const wrapper = mountCalendar({
      holidays: [{ id: 5, date: '2026-03-09', title: 'Nauryz' }],
    });

    await nextTick();

    const holidayEvent = wrapper
      .findComponent(VueCal)
      .props('events')
      .find(event => event.backgroundKind === 'holiday');

    expect(holidayEvent.backgroundLabel).toBe('Nauryz');
  });

  it('uses provider slots for calendar creation despite local holiday, break and time off', async () => {
    const wrapper = mountCalendar({
      view: 'day',
      workspaceTimezone: 'Asia/Almaty',
      resources: [
        {
          ...baseProps.resources[0],
          customAttributes: { medelement_specialist_code: 'doctor-1' },
        },
      ],
      holidays: [{ id: 5, date: '2026-03-09', title: 'Nauryz' }],
      breakRules: [
        {
          id: 6,
          active: true,
          resourceId: 12,
          weekday: 1,
          startMinute: 600,
          endMinute: 660,
          title: 'Lunch',
        },
      ],
      timeOffs: [
        {
          resourceId: 12,
          startsAt: '2026-03-09T05:00:00.000Z',
          endsAt: '2026-03-09T06:00:00.000Z',
        },
      ],
      slots: [
        {
          resourceId: 12,
          startsAt: '2026-03-09T05:00:00.000Z',
          endsAt: '2026-03-09T05:30:00.000Z',
        },
      ],
    });
    await nextTick();

    const backgrounds = wrapper.findComponent(VueCal).props('events');
    expect(backgrounds.some(event => event.backgroundKind === 'holiday')).toBe(
      false
    );
    expect(backgrounds.some(event => event.backgroundKind === 'break')).toBe(
      false
    );
    expect(backgrounds.some(event => event.backgroundKind === 'time-off')).toBe(
      false
    );

    wrapper.findComponent(VueCal).vm.$emit('cellClick', {
      cell: { start: new Date(2026, 2, 9), schedule: 12 },
      cursor: { date: new Date(2026, 2, 9, 10) },
      e: {},
    });

    expect(wrapper.emitted('createAppointment')?.[0]?.[0]).toEqual({
      resourceId: 12,
      startsAt: '2026-03-09T05:00:00.000Z',
      endsAt: '2026-03-09T05:30:00.000Z',
    });

    wrapper.findComponent(VueCal).vm.$emit('cellClick', {
      cell: { start: new Date(2026, 2, 9), schedule: 12 },
      cursor: { date: new Date(2026, 2, 9, 10, 30) },
      e: {},
    });
    expect(wrapper.emitted('createAppointment')).toHaveLength(1);
  });

  it('does not invent a month appointment for an integrated resource without slots', async () => {
    const wrapper = mountCalendar({
      view: 'month',
      resources: [
        {
          ...baseProps.resources[0],
          customAttributes: { medelement_specialist_code: 'doctor-1' },
        },
      ],
    });
    await nextTick();

    wrapper.findComponent(VueCal).vm.$emit('cellClick', {
      cell: { start: new Date(2026, 2, 9) },
      e: {},
    });

    expect(wrapper.emitted('createAppointment')).toBeUndefined();
  });

  it('keeps month fallback on a local resource in a mixed calendar', async () => {
    const wrapper = mountCalendar({
      view: 'month',
      resources: [
        {
          ...baseProps.resources[0],
          customAttributes: { medelement_specialist_code: 'doctor-1' },
        },
        { id: 13, name: 'Local doctor', slotDurationMin: 30 },
      ],
    });
    await nextTick();

    wrapper.findComponent(VueCal).vm.$emit('cellClick', {
      cell: { start: new Date(2026, 2, 9) },
      e: {},
    });

    expect(wrapper.emitted('createAppointment')?.[0]?.[0]?.resourceId).toBe(13);
  });

  it('includes managed custom field summary in appointment tooltips', async () => {
    const wrapper = mountCalendar({
      appointments: [
        {
          clientName: 'Alex Doe',
          customAttributes: {
            needs_lab: true,
            visit_reason: 'follow_up',
          },
          durationMin: 30,
          endsAt: '2026-03-09T11:30:00.000Z',
          id: 46,
          resourceId: 12,
          serviceNameSnapshot: 'Consultation',
          startsAt: '2026-03-09T11:00:00.000Z',
          status: 'scheduled',
        },
      ],
      customFieldDefinitions: [
        {
          fieldType: 'select',
          key: 'visit_reason',
          label: 'Visit Reason',
          options: [{ label: 'Follow-up', value: 'follow_up' }],
        },
        {
          fieldType: 'checkbox',
          key: 'needs_lab',
          label: 'Needs Lab',
        },
      ],
    });

    await nextTick();
    await nextTick();

    const eventCard = wrapper.find('.scheduling-vue-cal__event-card');

    expect(eventCard.attributes('title')).toContain('Visit Reason: Follow-up');
    expect(eventCard.attributes('title')).toContain('Needs Lab: Yes');
  });

  it('marks hour and half-hour cells in the time column', async () => {
    const wrapper = mountCalendar({ view: 'day' });

    await nextTick();
    await nextTick();

    expect(wrapper.find('.vuecal__time-cell--hour').exists()).toBe(true);
    expect(wrapper.find('.vuecal__time-cell--half-hour').exists()).toBe(true);
  });

  it('renders a clean 30-minute timeline while keeping five-minute snapping', async () => {
    const wrapper = mountCalendar({ view: 'day' });

    await nextTick();
    await nextTick();

    const vueCal = wrapper.findComponent(VueCal);

    expect(vueCal.props('timeStep')).toBe(30);
    expect(vueCal.props('snapToInterval')).toBe(5);
    // 40px per half hour so a 30-minute visit shows two full text lines.
    expect(vueCal.props('timeCellHeight')).toBe(40);
    expect(vueCal.props('timeFrom')).toBe(0);
    expect(vueCal.props('timeTo')).toBe(24 * 60);
    expect(wrapper.findAll('.vuecal__time-cell')).toHaveLength(48);
    expect(wrapper.find('.vuecal__time-column').text()).not.toContain('00:05');
    expect(wrapper.find('.vuecal__time-column').text()).not.toContain('00:30');
  });

  it('starts a click-created appointment at the clicked five-minute mark', async () => {
    const wrapper = mountCalendar({
      resources: [{ ...baseProps.resources[0], slotDurationMin: 15 }],
      view: 'day',
      workRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 540,
          endMinute: 1020,
          weekday: 1,
        },
      ],
      workspaceTimezone: 'Asia/Almaty',
    });

    await nextTick();

    const vueCal = wrapper.findComponent(VueCal);
    // vue-cal reports the exact wall-clock minute under the cursor. Both
    // clicks are in the lower half of a 30-minute cell; 16:45 is the last
    // 15-minute slot before the 17:00 end of the working day.
    [
      [10, 20],
      [16, 45],
    ].forEach(([hours, minutes]) => {
      vueCal.vm.$emit('cellClick', {
        cell: {
          end: new Date(2026, 2, 9, 23, 59),
          schedule: 12,
          start: new Date(2026, 2, 9),
        },
        cursor: { date: new Date(2026, 2, 9, hours, minutes) },
        e: {},
      });
    });

    expect(wrapper.emitted('createAppointment')).toEqual([
      [
        {
          endsAt: '2026-03-09T05:35:00.000Z',
          resourceId: 12,
          startsAt: '2026-03-09T05:20:00.000Z',
        },
      ],
      [
        {
          endsAt: '2026-03-09T12:00:00.000Z',
          resourceId: 12,
          startsAt: '2026-03-09T11:45:00.000Z',
        },
      ],
    ]);
  });

  it.each([false, true])(
    'marks a drag-created range as authored (unscheduled: %s)',
    async unscheduled => {
      const wrapper = mountCalendar({
        allowCreateWithoutResources: unscheduled,
        resources: unscheduled ? [] : baseProps.resources,
        view: 'day',
        workRules: [
          {
            id: 1,
            active: true,
            resourceId: 12,
            startMinute: 540,
            endMinute: 1020,
            weekday: 1,
          },
        ],
      });
      await nextTick();
      const resolve = vi.fn();
      wrapper.findComponent(VueCal).vm.$emit('eventCreate', {
        event: {
          start: new Date(2026, 2, 9, 10, 0),
          end: new Date(2026, 2, 9, 10, 45),
          schedule: 12,
        },
        resolve,
      });

      const [[payload]] = wrapper.emitted('createAppointment');
      expect(payload.durationEdited).toBe(true);
      expect(new Date(payload.endsAt) - new Date(payload.startsAt)).toBe(
        45 * 60000
      );
      expect(resolve).toHaveBeenCalledWith(false);
    }
  );

  it('starts a click-created unscheduled item at the clicked five-minute mark', async () => {
    const wrapper = mountCalendar({
      allowCreateWithoutResources: true,
      resources: [],
      view: 'day',
    });

    await nextTick();

    wrapper.findComponent(VueCal).vm.$emit('cellClick', {
      cell: {
        end: new Date(2026, 2, 9, 23, 59),
        start: new Date(2026, 2, 9),
      },
      cursor: { date: new Date(2026, 2, 9, 10, 20) },
      e: {},
    });

    const [[payload]] = wrapper.emitted('createAppointment');
    expect(new Date(payload.startsAt)).toEqual(new Date(2026, 2, 9, 10, 20));
    expect(new Date(payload.endsAt)).toEqual(new Date(2026, 2, 9, 11, 20));
  });

  it('scrolls its timeline to the workspace evening and preserves manual scroll across data updates', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-03-09T18:30:00Z'));
    HTMLElement.prototype.scrollTo = vi.fn(function scrollTo({ top }) {
      this.scrollTop = top;
    });
    const wrapper = mountCalendar({
      view: 'day',
      workspaceTimezone: 'Asia/Almaty',
    });
    await nextTick();
    await nextTick();
    await nextTick();
    const scrollable = wrapper.find('.vuecal__scrollable').element;
    expect(scrollable.scrollTop).toBe(22.5 * 80);
    const vueCal = wrapper.findComponent(VueCal);
    const scrollToTime = vi.spyOn(vueCal.vm.view, 'scrollToTime');
    scrollable.scrollTop = 417;
    await wrapper.setProps({
      appointments: [],
      resources: [...baseProps.resources],
      workRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 540,
          endMinute: 1020,
          weekday: 1,
        },
      ],
    });
    await nextTick();
    expect(scrollToTime).not.toHaveBeenCalled();
    expect(scrollable.scrollTop).toBe(417);
    await wrapper.setProps({ view: 'week' });
    await nextTick();
    await nextTick();
    await nextTick();
    expect(wrapper.findComponent(VueCal).vm).not.toBe(vueCal.vm);
    expect(
      wrapper.get('.vuecal__scrollable--week-view').element.scrollTop
    ).toBe(22.5 * 80);
  });

  it.each([
    ['day', 'week'],
    ['week', 'day'],
    ['month', 'week'],
  ])(
    'scrolls the entering %s → %s timeline after the native view transition',
    async (from, to) => {
      vi.useFakeTimers({
        toFake: [
          'Date',
          'setTimeout',
          'clearTimeout',
          'requestAnimationFrame',
          'cancelAnimationFrame',
        ],
      });
      vi.setSystemTime(new Date('2026-03-09T14:30:00Z'));
      HTMLElement.prototype.scrollTo = vi.fn(function scrollTo({ top }) {
        this.scrollTop = top;
      });
      const style = document.createElement('style');
      style.textContent =
        '.vuecal__scrollable { transition-property: opacity; transition-duration: 0.2s; transition-delay: 0s; }';
      document.head.appendChild(style);
      try {
        const wrapper = mountCalendar(
          { view: from, workspaceTimezone: 'Asia/Almaty' },
          { global: { stubs: { transition: false } } }
        );
        await nextTick();
        await nextTick();
        await vi.advanceTimersByTimeAsync(250);
        await wrapper.setProps({ view: to });
        await nextTick();
        await nextTick();
        await vi.advanceTimersByTimeAsync(250);
        const enteringTimeline = wrapper.get(
          `.vuecal__scrollable--${to}-view`
        ).element;
        expect(enteringTimeline.scrollTop).toBeGreaterThan(0);
        expect(enteringTimeline.scrollTop).toBe(18.5 * 80);
      } finally {
        style.remove();
      }
    }
  );

  it('starts no earlier than 08:00 at workspace midnight and does not scroll month', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-03-08T19:05:00Z'));
    const wrapper = mountCalendar({
      view: 'day',
      workspaceTimezone: 'Asia/Almaty',
    });
    await nextTick();
    await nextTick();
    await nextTick();
    expect(HTMLElement.prototype.scrollTo).toHaveBeenCalledWith(
      expect.objectContaining({ top: 8 * 80 })
    );
    HTMLElement.prototype.scrollTo.mockClear();
    await wrapper.setProps({ view: 'month' });
    await nextTick();
    await nextTick();
    expect(HTMLElement.prototype.scrollTo).not.toHaveBeenCalled();
  });

  it('keeps long specialist names inside their day columns', async () => {
    const longName = 'Dr. Alexandra Very Long Specialist Name';
    const wrapper = mountCalendar({
      view: 'day',
      resources: [{ ...baseProps.resources[0], name: longName }],
    });

    await nextTick();
    await nextTick();

    const heading = wrapper.find('.scheduling-vue-cal__schedule-heading');

    expect(heading.attributes('title')).toBe(longName);
    expect(heading.attributes('aria-label')).toBe(longName);
    expect(heading.find('.scheduling-vue-cal__schedule-label').text()).toBe(
      longName
    );
  });

  it('shows the selected resource count in weekly header labels', async () => {
    const wrapper = mountCalendar({
      resources: [
        {
          id: 12,
          name: 'Dr. Sam',
          color: '#0f766e',
          slotDurationMin: 30,
        },
        {
          id: 18,
          name: 'Dr. Lee',
          color: '#2563eb',
          slotDurationMin: 30,
        },
      ],
      slots: [
        {
          resourceId: 12,
          startsAt: '2026-03-09T09:00:00.000Z',
          endsAt: '2026-03-09T09:30:00.000Z',
        },
      ],
    });

    await nextTick();
    await nextTick();

    expect(wrapper.text()).toContain('2 specialists');
    expect(wrapper.text()).not.toContain('1 specialist');
  });

  it('shows unavailable time and affected specialists in a shared week', async () => {
    const wrapper = mountCalendar({
      resources: [
        { ...baseProps.resources[0], name: 'Dr. Sam' },
        {
          id: 18,
          name: 'Dr. Lee',
          color: '#2563eb',
          slotDurationMin: 30,
        },
      ],
      workRules: [
        {
          id: 1,
          active: true,
          resourceId: 12,
          startMinute: 540,
          endMinute: 1020,
          weekday: 1,
        },
        {
          id: 2,
          active: true,
          resourceId: 18,
          startMinute: 600,
          endMinute: 1020,
          weekday: 1,
        },
      ],
    });

    await nextTick();
    await nextTick();

    const unavailableEvents = wrapper
      .findComponent(VueCal)
      .props('events')
      .filter(event => event.backgroundKind === 'unavailable');

    expect(unavailableEvents.map(event => event.backgroundLabel)).toEqual(
      expect.arrayContaining([
        'Unavailable: Dr. Lee · 09:00–10:00',
        'All specialists unavailable · 00:00–09:00',
      ])
    );
    expect(wrapper.text()).not.toContain('Unavailable: Dr. Lee');
    expect(wrapper.text()).not.toContain('All specialists unavailable');
    expect(
      wrapper
        .findAll('.scheduling-vue-cal__background-fill')
        .map(node => node.attributes('title'))
    ).toContain('Unavailable: Dr. Lee · 09:00–10:00');
  });

  it('lays overlapping appointments side by side instead of stacking them', async () => {
    const appointment = {
      clientName: 'Alex Doe',
      durationMin: 60,
      endsAt: '2026-03-09T11:00:00.000Z',
      resourceId: 12,
      serviceNameSnapshot: 'Consultation',
      startsAt: '2026-03-09T10:00:00.000Z',
      status: 'scheduled',
    };
    const wrapper = mountCalendar({
      appointments: [
        { ...appointment, id: 71 },
        { ...appointment, id: 72, clientName: 'Blair Doe' },
      ],
    });

    await nextTick();
    await nextTick();

    const eventCards = wrapper.findAll('.scheduling-vue-cal__event-card');
    const overlapClasses = eventCards.map(
      card => card.element.closest('.vuecal__event')?.className || ''
    );

    expect(wrapper.findComponent(VueCal).props('stackEvents')).toBe(false);
    expect(eventCards).toHaveLength(2);
    expect(overlapClasses).toEqual(
      expect.arrayContaining([
        expect.stringContaining('vuecal__event--stack-1-2'),
        expect.stringContaining('vuecal__event--stack-2-2'),
      ])
    );
    const widths = eventCards.map(
      card => card.element.closest('.vuecal__event').style.width
    );
    expect(widths).toEqual(['50%', '50%']);
  });

  const visit = (id, overrides = {}) => ({
    clientName: `Client ${id}`,
    endsAt: '2026-03-09T10:30:00.000Z',
    id,
    resourceId: 12,
    serviceNameSnapshot: 'Consultation',
    startsAt: '2026-03-09T10:00:00.000Z',
    status: 'scheduled',
    ...overrides,
  });

  it.each(['day', 'week'])(
    'keeps appointments for all 32 selected specialists in the %s view',
    async view => {
      const resources = Array.from({ length: 32 }, (_, index) => ({
        ...baseProps.resources[0],
        id: index + 1,
        name: `Doctor ${index + 1}`,
      }));
      const appointments = resources.map(resource =>
        visit(resource.id, {
          resourceId: resource.id,
          clientName: `Patient for doctor ${resource.id}`,
          status: resource.id === 32 ? 'completed' : 'scheduled',
        })
      );
      const wrapper = mountCalendar({ resources, appointments, view });
      await nextTick();
      await nextTick();

      const events = wrapper.findComponent(VueCal).props('events');
      expect(
        events.filter(event => !event.background).map(event => event.id)
      ).toEqual(
        expect.arrayContaining(
          appointments.map(appointment => String(appointment.id))
        )
      );
      const cards = wrapper.findAll('.scheduling-vue-cal__event-card');
      expect(cards).toHaveLength(32);
      appointments.forEach(appointment => {
        expect(
          cards.some(card =>
            card.attributes('title')?.includes(appointment.clientName)
          )
        ).toBe(true);
      });
      cards.forEach(card => {
        const width = card.element.closest('.vuecal__event').style.width;
        expect(width === '' || Number.parseFloat(width) > 0).toBe(true);
      });
    },
    30000
  );

  const cardFor = (wrapper, name) =>
    wrapper
      .findAll('.scheduling-vue-cal__event-card')
      .find(card => card.text().includes(name));

  it('colours cards by status: confirmed green, scheduled blue, completed muted', async () => {
    const wrapper = mountCalendar({
      appointments: [
        visit(1, { clientName: 'Confirmed client', status: 'confirmed' }),
        visit(2, {
          clientName: 'Scheduled client',
          endsAt: '2026-03-09T11:30:00.000Z',
          startsAt: '2026-03-09T11:00:00.000Z',
        }),
        visit(3, {
          clientName: 'Completed client',
          endsAt: '2026-03-09T12:30:00.000Z',
          startsAt: '2026-03-09T12:00:00.000Z',
          status: 'completed',
        }),
      ],
    });

    await nextTick();
    await nextTick();

    const confirmed = cardFor(wrapper, 'Confirmed client');
    const scheduled = cardFor(wrapper, 'Scheduled client');
    const completed = cardFor(wrapper, 'Completed client');

    expect(confirmed.classes()).toContain(
      'scheduling-vue-cal__event-card--solid'
    );
    expect(
      confirmed.element.style.getPropertyValue('--appointment-accent')
    ).toBe('#12A594');
    expect(
      scheduled.element.style.getPropertyValue('--appointment-accent')
    ).toBe('#2563EB');
    expect(completed.classes()).toEqual(
      expect.arrayContaining([
        'scheduling-vue-cal__event-card--muted',
        'scheduling-vue-cal__event-card--regular',
      ])
    );
  });

  it('keeps cancelled visits visible in a narrow outlined lane beside live ones', async () => {
    const wrapper = mountCalendar({
      appointments: [
        visit(1, { clientName: 'Cancelled A', status: 'cancelled' }),
        visit(2, { clientName: 'Cancelled B', status: 'cancelled' }),
        visit(3, { clientName: 'Live visit', status: 'confirmed' }),
      ],
    });

    await nextTick();
    await nextTick();

    const eventBox = name =>
      cardFor(wrapper, name).element.closest('.vuecal__event').style;

    expect(eventBox('Live visit').left).toBe('0%');
    expect(eventBox('Live visit').width).toBe('72%');
    expect(eventBox('Cancelled A').left).toBe('72%');
    expect(eventBox('Cancelled A').width).toBe('14%');
    expect(eventBox('Cancelled B').left).toBe('86%');
    expect(cardFor(wrapper, 'Cancelled A').classes()).toEqual(
      expect.arrayContaining(['scheduling-vue-cal__event-card--ghost'])
    );
  });

  it('uses a single line for short visits and keeps the details in the tooltip', async () => {
    const wrapper = mountCalendar({
      appointments: [
        visit(1, {
          clientName: 'Quick visit',
          endsAt: '2026-03-09T10:15:00.000Z',
          resourceName: 'Dr. Sam',
        }),
      ],
    });

    await nextTick();
    await nextTick();

    const card = cardFor(wrapper, 'Quick visit');

    expect(card.classes()).toContain('scheduling-vue-cal__event-card--compact');
    expect(
      card
        .find('.scheduling-vue-cal__event-summary')
        .find('.scheduling-vue-cal__event-subtitle--inline')
        .text()
    ).toBe('Consultation · Dr. Sam');
    expect(card.attributes('title')).toContain('Quick visit');
    expect(card.attributes('title')).toContain('Consultation · Dr. Sam');
  });

  it('keeps resource colours when the calendar is coloured by resource', async () => {
    const wrapper = mountCalendar({
      colorBy: 'resource',
      appointments: [
        visit(1, { clientName: 'Task', resourceColor: '#f97316' }),
      ],
    });

    await nextTick();
    await nextTick();

    expect(
      cardFor(wrapper, 'Task').element.style.getPropertyValue(
        '--appointment-accent'
      )
    ).toBe('#f97316');
  });

  it('includes MedElement reception code and sync status on regular cards and tooltips', async () => {
    const wrapper = mountCalendar({
      resources: [
        {
          id: 12,
          name: 'Dr. Sam',
          color: '#0f766e',
          slotDurationMin: 30,
          customAttributes: { medelement_specialist_code: 'spec-12' },
        },
      ],
      appointments: [
        visit(1, {
          clientName: 'MedElement patient',
          customAttributes: { medelement_reception_code: 'me-777' },
          providerConfirmationStatus: 'succeeded',
        }),
        visit(2, {
          clientName: 'Unsynced MedElement patient',
          startsAt: '2026-03-09T11:00:00.000Z',
          endsAt: '2026-03-09T11:30:00.000Z',
          source: 'manual',
          status: 'scheduled',
        }),
      ],
    });

    await nextTick();
    await nextTick();

    const card = cardFor(wrapper, 'MedElement patient');
    expect(card.attributes('title')).toContain('me-777');
    expect(
      card.find('.scheduling-vue-cal__event-medelement-meta').exists()
    ).toBe(false);

    const unsyncedCard = cardFor(wrapper, 'Unsynced MedElement patient');
    expect(unsyncedCard.attributes('title')).toContain(
      'SCHEDULING.MEDELEMENT.SYNC_STATUS.NOT_SYNCED'
    );
    expect(
      unsyncedCard.find('.scheduling-vue-cal__event-medelement-meta').exists()
    ).toBe(false);
  });

  describe('changing a time with the mouse', () => {
    const rules = [
      {
        id: 1,
        active: true,
        resourceId: 12,
        startMinute: 540,
        endMinute: 1020,
        weekday: 1,
      },
    ];
    // 10:00-10:30 on the Workspace calendar (Asia/Almaty is UTC+5).
    const morningVisit = (id, overrides = {}) =>
      visit(id, {
        endsAt: '2026-03-09T05:30:00.000Z',
        startsAt: '2026-03-09T05:00:00.000Z',
        ...overrides,
      });
    let rejections;
    let savedRejectionListeners;

    const mouse = (target, type, clientY, init = {}) =>
      target.dispatchEvent(
        new MouseEvent(type, {
          bubbles: true,
          cancelable: true,
          clientX: 50,
          clientY,
          ...init,
        })
      );
    const press = (target, clientY) =>
      mouse(target, 'mousedown', clientY, { button: 0, buttons: 1 });
    const move = (clientY, buttons = 1) =>
      mouse(document, 'mousemove', clientY, { buttons });
    const release = (target, clientY) =>
      mouse(target, 'mouseup', clientY, { button: 0, buttons: 0 });

    // The mocked cell is 1000px tall for the visible window: the y of a time on the calendar.
    const yOf = (wrapper, hours, minutes = 0) => {
      const { timeFrom, timeTo } = wrapper.findComponent(VueCal).props();
      return ((hours * 60 + minutes - timeFrom) * 1000) / (timeTo - timeFrom);
    };
    const mountDay = async appointments => {
      const wrapper = mountCalendar({
        appointments,
        view: 'day',
        workRules: rules,
        workspaceTimezone: 'Asia/Almaty',
      });
      await nextTick();
      await nextTick();
      return wrapper;
    };
    const settle = () =>
      new Promise(resolve => {
        setTimeout(resolve, 10);
      });
    const isResizing = wrapper =>
      wrapper.find('.vuecal').classes().includes('vuecal--resizing-event');
    // The calendar event element that holds the card of a visit (background events come first).
    const eventOf = (wrapper, name) =>
      cardFor(wrapper, name).element.closest('.vuecal__event');

    beforeEach(() => {
      vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(
        () => ({
          top: 0,
          left: 0,
          width: 300,
          height: 1000,
          right: 300,
          bottom: 1000,
          x: 0,
          y: 0,
        })
      );
      // Capture unhandled promise rejections here instead of failing the whole run.
      rejections = [];
      savedRejectionListeners = process.listeners('unhandledRejection');
      process.removeAllListeners('unhandledRejection');
      process.on('unhandledRejection', reason => rejections.push(reason));
    });

    afterEach(async () => {
      await settle();
      process.removeAllListeners('unhandledRejection');
      savedRejectionListeners.forEach(listener =>
        process.on('unhandledRejection', listener)
      );
      vi.restoreAllMocks();
    });

    it('leaves a card that does not fit its slot untouched when its bottom border is only clicked', async () => {
      // Two visits of the same specialist overlap, so neither range is accepted as a new booking.
      const wrapper = await mountDay([
        morningVisit(1),
        morningVisit(2, {
          endsAt: '2026-03-09T05:45:00.000Z',
          startsAt: '2026-03-09T05:15:00.000Z',
        }),
      ]);
      const card = eventOf(wrapper, 'Client 1');
      const style = card.getAttribute('style');
      const resizer = card.querySelector('.vuecal__event-resizer');
      const bottom = yOf(wrapper, 10, 28);

      press(resizer, bottom);
      release(resizer, bottom);
      await nextTick();
      await settle();

      expect(useAlert).not.toHaveBeenCalled();
      expect(wrapper.emitted('resizeAppointment')).toBeUndefined();
      expect(isResizing(wrapper)).toBe(false);
      expect(rejections).toEqual([]);

      // The mouse then moves around with no button held: the card stays where it is.
      move(yOf(wrapper, 14), 0);
      move(yOf(wrapper, 9), 0);
      await nextTick();
      expect(card.getAttribute('style')).toBe(style);
    });

    it('resizes a card only while its bottom border is held and commits once on release', async () => {
      const wrapper = await mountDay([morningVisit(1)]);
      const card = eventOf(wrapper, 'Client 1');
      const style = card.getAttribute('style');
      const resizer = card.querySelector('.vuecal__event-resizer');
      const bottom = yOf(wrapper, 10, 28);

      press(resizer, bottom);
      move(bottom + 3);
      await nextTick();
      // Not dragged far enough yet: still a click.
      expect(card.getAttribute('style')).toBe(style);

      move(yOf(wrapper, 11));
      await nextTick();
      expect(card.getAttribute('style')).not.toBe(style);
      expect(wrapper.emitted('resizeAppointment')).toBeUndefined();

      release(resizer, yOf(wrapper, 11));
      await nextTick();
      await settle();

      expect(wrapper.emitted('resizeAppointment')).toEqual([
        [
          {
            appointment: expect.objectContaining({ id: 1 }),
            endsAt: '2026-03-09T06:00:00.000Z',
            startsAt: '2026-03-09T05:00:00.000Z',
          },
        ],
      ]);
      expect(isResizing(wrapper)).toBe(false);
    });

    it('puts the card back and warns once when a held resize is refused', async () => {
      const wrapper = await mountDay([
        morningVisit(1),
        morningVisit(2, {
          endsAt: '2026-03-09T05:45:00.000Z',
          startsAt: '2026-03-09T05:15:00.000Z',
        }),
      ]);
      const card = eventOf(wrapper, 'Client 1');
      const style = card.getAttribute('style');
      const resizer = card.querySelector('.vuecal__event-resizer');

      press(resizer, yOf(wrapper, 10, 28));
      move(yOf(wrapper, 11));
      await nextTick();
      expect(card.getAttribute('style')).not.toBe(style);

      release(resizer, yOf(wrapper, 11));
      await nextTick();
      await settle();

      expect(useAlert).toHaveBeenCalledTimes(1);
      expect(wrapper.emitted('resizeAppointment')).toBeUndefined();
      expect(card.getAttribute('style')).toBe(style);
      expect(isResizing(wrapper)).toBe(false);
      expect(rejections).toEqual([]);

      move(yOf(wrapper, 13), 0);
      await nextTick();
      expect(card.getAttribute('style')).toBe(style);
    });

    it('puts the card back when the release is lost and the mouse moves on without the button', async () => {
      const wrapper = await mountDay([morningVisit(1)]);
      const card = eventOf(wrapper, 'Client 1');
      const style = card.getAttribute('style');
      const resizer = card.querySelector('.vuecal__event-resizer');

      press(resizer, yOf(wrapper, 10, 28));
      move(yOf(wrapper, 11));
      await nextTick();
      expect(card.getAttribute('style')).not.toBe(style);

      move(yOf(wrapper, 13), 0);
      await nextTick();

      expect(card.getAttribute('style')).toBe(style);
      expect(isResizing(wrapper)).toBe(false);
      expect(wrapper.emitted('resizeAppointment')).toBeUndefined();
      expect(useAlert).not.toHaveBeenCalled();
    });

    describe('the click that ends a press on the bottom border', () => {
      const click = (target, clientY) =>
        mouse(target, 'click', clientY, { button: 0, buttons: 0 });

      beforeEach(() => {
        // The cell reads its own height to turn a click into a time.
        vi.spyOn(Element.prototype, 'clientHeight', 'get').mockReturnValue(
          1000
        );
      });

      it('control: a plain click on the empty cell still opens a new appointment', async () => {
        const wrapper = await mountDay([morningVisit(1)]);
        const schedule = eventOf(wrapper, 'Client 1').closest(
          '.vuecal__schedule'
        );
        const y = yOf(wrapper, 14);

        press(schedule, y);
        release(schedule, y);
        click(schedule, y);
        await nextTick();

        expect(wrapper.emitted('createAppointment')).toHaveLength(1);
      });

      it('does not open a new appointment when a few pixels of drift take the pointer off the border onto the cell below', async () => {
        const wrapper = await mountDay([morningVisit(1)]);
        const card = eventOf(wrapper, 'Client 1');
        const resizer = card.querySelector('.vuecal__event-resizer');
        const schedule = card.closest('.vuecal__schedule');
        const y = yOf(wrapper, 10, 29);

        press(resizer, y);
        move(y + 3);
        // The release is on the cell below the card: the click goes to their common ancestor.
        release(schedule, y + 3);
        click(schedule, y + 3);
        await nextTick();
        await settle();

        expect(wrapper.emitted('createAppointment')).toBeUndefined();
        expect(wrapper.emitted('resizeAppointment')).toBeUndefined();
      });
    });
  });
});
