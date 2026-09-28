import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { VueCal } from 'vue-cal';

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

const mountCalendar = props => {
  const wrapper = mount(SchedulingVueCalCalendar, {
    props: {
      ...baseProps,
      ...props,
    },
    attachTo: document.body,
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
  }, 20_000);

  it('counts and creates from the workspace month day when the browser is behind', async () => {
    const slot = {
      resourceId: 12,
      startsAt: '2026-09-27T19:00:00.000Z',
      endsAt: '2026-09-27T19:30:00.000Z',
    };
    const wrapper = mountCalendar({
      anchorDate: '2026-09-28T00:00:00.000Z',
      appointments: [],
      slots: [slot],
      view: 'month',
      workspaceTimezone: 'Asia/Almaty',
    });
    await nextTick();
    await nextTick();

    const { formatMonthSlotMeta } = wrapper.vm.$.setupState;
    expect(formatMonthSlotMeta(new Date(2026, 8, 28))).toBe(
      'SCHEDULING.CALENDAR.AVAILABLE_SLOTS'
    );
    expect(formatMonthSlotMeta(new Date(2026, 8, 27))).toBe('');

    wrapper.vm.$.setupState.handleCellClick({
      cell: { start: new Date(2026, 8, 28) },
    });
    expect(wrapper.emitted('createAppointment')).toEqual([[slot]]);
  });

  it.each(['day', 'week'])(
    'renders workspace 02:30 through browser DST gap in %s and writes the right instant',
    async view => {
      const appointment = {
        id: 77,
        clientName: 'Gap consultation',
        startsAt: '2026-03-07T21:30:00.000Z',
        endsAt: '2026-03-07T22:00:00.000Z',
      };
      const wrapper = mountCalendar({
        allowCreateWithoutResources: true,
        anchorDate: '2026-03-07T19:00:00.000Z',
        appointments: [appointment],
        resources: [],
        view,
        workspaceTimezone: 'Asia/Almaty',
      });
      await nextTick();
      await nextTick();
      const calendar = wrapper.findComponent(VueCal);
      const event = calendar
        .props('events')
        .find(item => item.appointment?.id === 77);
      expect([
        event.start.getDate(),
        event.start.getHours(),
        event.start.getMinutes(),
      ]).toEqual([calendar.props('viewDate').getDate(), 2, 30]);
      expect(
        wrapper.find('.scheduling-vue-cal__event-summary').text()
      ).toContain('02:30');
      const movedStart = new Date(event.start);
      movedStart.setHours(3, 0, 0, 0);
      const movedEnd = new Date(movedStart);
      movedEnd.setMinutes(30);
      wrapper.vm.$.setupState.handleEventDrop({
        event: { ...event, start: movedStart, end: movedEnd },
      });
      expect(wrapper.emitted('moveAppointment')?.[0]?.[0]).toMatchObject({
        startsAt: '2026-03-07T22:00:00.000Z',
        endsAt: '2026-03-07T22:30:00.000Z',
      });
    }
  );

  it('keeps the workspace 02:30 time in month summaries', async () => {
    const wrapper = mountCalendar({
      anchorDate: '2026-03-07T19:00:00.000Z',
      appointments: [
        {
          id: 77,
          clientName: 'Gap consultation',
          startsAt: '2026-03-07T21:30:00.000Z',
          endsAt: '2026-03-07T22:00:00.000Z',
        },
      ],
      view: 'month',
      workspaceTimezone: 'Asia/Almaty',
    });
    await nextTick();
    await nextTick();
    expect(wrapper.find('.scheduling-vue-cal__month-event').text()).toContain(
      '02:30'
    );
  });

  it('preserves the real workspace 02:30 when moving a month event through a browser gap', async () => {
    const wrapper = mountCalendar({
      allowCreateWithoutResources: true,
      resources: [],
      anchorDate: '2026-03-07T19:00:00.000Z',
      appointments: [
        {
          id: 77,
          startsAt: '2026-03-07T21:30:00.000Z',
          endsAt: '2026-03-07T22:00:00.000Z',
        },
      ],
      view: 'month',
      workspaceTimezone: 'Asia/Almaty',
    });
    await nextTick();
    const event = wrapper
      .findComponent(VueCal)
      .props('events')
      .find(item => item.appointment?.id === 77);
    const start = new Date(event.start);
    const end = new Date(event.end);
    start.setDate(start.getDate() + 1);
    end.setDate(end.getDate() + 1);
    wrapper.vm.$.setupState.handleEventDrop({
      event: { ...event, start, end },
    });

    expect(wrapper.emitted('moveAppointment')?.[0]?.[0]).toMatchObject({
      startsAt: '2026-03-08T21:30:00.000Z',
      endsAt: '2026-03-08T22:00:00.000Z',
    });
  });

  it('does not invent a nonexistent Workspace time while projecting the browser gap', async () => {
    const wrapper = mountCalendar({
      anchorDate: '2026-03-08T09:30:00.000Z',
      allowCreateWithoutResources: true,
      view: 'day',
      workspaceTimezone: 'America/Los_Angeles',
    });
    await nextTick();
    const projectedDay = wrapper.findComponent(VueCal).props('viewDate');
    const slot = new Date(projectedDay);
    slot.setHours(2, 30, 0, 0);
    const { handleCellClick } = wrapper.vm.$.setupState;
    handleCellClick({ cell: { start: projectedDay }, cursor: { date: slot } });

    expect(wrapper.emitted('createAppointment')).toBeUndefined();
  });

  it('projects a repeated browser hour away from the fall-back timeline', async () => {
    const wrapper = mountCalendar({
      anchorDate: '2026-11-01T06:30:00.000Z',
      appointments: [
        {
          id: 78,
          clientName: 'Autumn consultation',
          startsAt: '2026-11-01T06:30:00.000Z',
          endsAt: '2026-11-01T07:00:00.000Z',
        },
      ],
      view: 'day',
      workspaceTimezone: 'Asia/Almaty',
    });
    await nextTick();
    const calendar = wrapper.findComponent(VueCal);
    const event = calendar
      .props('events')
      .find(item => item.appointment?.id === 78);
    const browserFallsBack =
      new Date(2026, 10, 1).getTimezoneOffset() !==
      new Date(2026, 10, 2).getTimezoneOffset();
    expect(calendar.props('viewDate').getDate()).toBe(
      browserFallsBack ? 25 : 1
    );
    expect(event.start.getHours()).toBe(11);
    expect(event.start.getDate()).toBe(browserFallsBack ? 25 : 1);
  });

  it('shows both workspace fall-back folds and refuses ambiguous calendar writes', async () => {
    const wrapper = mountCalendar({
      allowCreateWithoutResources: true,
      anchorDate: '2026-11-01T08:30:00.000Z',
      appointments: [
        {
          id: 79,
          clientName: 'Crossing the fold',
          startsAt: '2026-11-01T08:45:00.000Z',
          endsAt: '2026-11-01T09:15:00.000Z',
        },
        {
          id: 80,
          clientName: 'Second 01:30',
          startsAt: '2026-11-01T09:30:00.000Z',
          endsAt: '2026-11-01T09:45:00.000Z',
        },
      ],
      resources: [],
      view: 'day',
      workspaceTimezone: 'America/Los_Angeles',
    });
    await nextTick();
    await nextTick();

    const calendar = wrapper.findComponent(VueCal);
    const events = calendar.props('events').filter(event => event.appointment);
    expect(events).toHaveLength(2);
    expect(events.map(event => event.draggable)).toEqual([false, false]);
    expect(wrapper.text()).toContain('Crossing the fold');
    expect(wrapper.text()).toContain('Second 01:30');
    expect(wrapper.text()).toContain(
      'SCHEDULING.CALENDAR.TIME_CHANGE_READ_ONLY'
    );
    expect(wrapper.text()).toMatch(/GMT-0?7.*GMT-0?8/);

    const second = events[1];
    const movedStart = new Date(second.start);
    movedStart.setMinutes(45);
    expect(
      wrapper.vm.$.setupState.handleEventDrop({
        event: { ...second, start: movedStart },
      })
    ).toBe(false);
    expect(wrapper.emitted('moveAppointment')).toBeUndefined();
    expect(
      wrapper.vm.$.setupState.handleEventResizeEnd({ event: second })
    ).toBe(false);
    expect(wrapper.emitted('resizeAppointment')).toBeUndefined();

    wrapper.vm.$.setupState.handleCellClick({
      cell: { start: calendar.props('viewDate') },
      cursor: { date: movedStart },
    });
    expect(wrapper.emitted('createAppointment')).toBeUndefined();

    const resolve = vi.fn();
    wrapper.vm.$.setupState.handleEventCreate({
      event: { start: movedStart, end: second.end },
      resolve,
    });
    expect(resolve).toHaveBeenCalledWith(false);
    expect(wrapper.emitted('createAppointment')).toBeUndefined();
  });

  it('refuses dragging a normal appointment into a Workspace clock-change day', async () => {
    const wrapper = mountCalendar({
      allowEdit: true,
      allowCreateWithoutResources: true,
      anchorDate: '2026-10-31T20:00:00.000Z',
      appointments: [
        {
          id: 91,
          startsAt: '2026-10-31T17:00:00.000Z',
          endsAt: '2026-10-31T17:30:00.000Z',
        },
      ],
      resources: [],
      view: 'month',
      workspaceTimezone: 'America/Los_Angeles',
    });
    await nextTick();
    const event = wrapper
      .findComponent(VueCal)
      .props('events')
      .find(item => item.appointment);
    expect(event.draggable).toBe(true);
    const start = new Date(event.start);
    start.setDate(start.getDate() + 1);
    const end = new Date(event.end);
    end.setDate(end.getDate() + 1);
    expect(
      wrapper.vm.$.setupState.handleEventDrop({
        event: { ...event, start, end },
      })
    ).toBe(false);
    expect(wrapper.emitted('moveAppointment')).toBeUndefined();
  });

  it('disables click and drag creation for edit-only grants while preserving record drag', async () => {
    const wrapper = mountCalendar({
      allowCreate: false,
      allowEdit: true,
      allowCreateWithoutResources: true,
      appointments: [
        {
          id: 1,
          startsAt: '2026-03-09T10:00:00.000Z',
          endsAt: '2026-03-09T11:00:00.000Z',
        },
        {
          id: 2,
          startsAt: '2026-03-09T11:00:00.000Z',
          endsAt: '2026-03-09T12:00:00.000Z',
          readOnly: true,
        },
      ],
    });
    await nextTick();
    const calendar = wrapper.findComponent(VueCal);
    expect(calendar.props('editableEvents')).toMatchObject({
      create: false,
      drag: true,
      resize: true,
    });
    wrapper.vm.$.setupState.handleCellClick({
      cell: { start: new Date(2026, 2, 9) },
    });
    const resolve = vi.fn();
    wrapper.vm.$.setupState.handleEventCreate({
      event: { start: new Date(), end: new Date() },
      resolve,
    });
    expect(wrapper.emitted('createAppointment')).toBeUndefined();
    expect(resolve).toHaveBeenCalledWith(false);
    const events = calendar.props('events').filter(event => event.appointment);
    expect(events.map(event => event.draggable)).toEqual([true, false]);
  });

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
  });

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

  it('uses an optional appointment title while retaining the client in the subtitle', async () => {
    const wrapper = mountCalendar({
      appointments: [
        {
          id: 46,
          clientName: 'Alex Doe',
          durationMin: 30,
          endsAt: '2026-03-09T12:30:00.000Z',
          resourceId: 12,
          serviceNameSnapshot: 'Consultation',
          startsAt: '2026-03-09T12:00:00.000Z',
          status: 'scheduled',
          title: 'Contract review',
        },
      ],
    });

    await nextTick();
    await nextTick();

    expect(wrapper.find('.scheduling-vue-cal__event-summary').text()).toContain(
      'Contract review'
    );
    expect(
      wrapper.find('.scheduling-vue-cal__event-subtitle').text()
    ).toContain('Alex Doe');
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
    expect(vueCal.props('timeCellHeight')).toBe(24);
    expect(vueCal.props('timeFrom')).toBe(0);
    expect(vueCal.props('timeTo')).toBe(24 * 60);
    expect(wrapper.findAll('.vuecal__time-cell')).toHaveLength(48);
    expect(wrapper.find('.vuecal__time-column').text()).not.toContain('00:05');
    expect(wrapper.find('.vuecal__time-column').text()).not.toContain('00:30');
  });

  it('scrolls to 08:00 without a schedule and to the configured working-day start', async () => {
    const wrapper = mountCalendar({ view: 'day' });
    await nextTick();
    await nextTick();
    const vueCal = wrapper.findComponent(VueCal);
    const scrollToTime = vi.spyOn(vueCal.vm.view, 'scrollToTime');

    await wrapper.setProps({ view: 'week' });
    await nextTick();
    expect(scrollToTime).toHaveBeenLastCalledWith(8 * 60);

    await wrapper.setProps({
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
    expect(scrollToTime).toHaveBeenLastCalledWith(9 * 60);
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
  });
});
