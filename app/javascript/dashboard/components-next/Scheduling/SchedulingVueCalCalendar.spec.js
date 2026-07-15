import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { useI18n } from 'vue-i18n';

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
      t: vi.fn(key => {
        const labels = {
          'CHOICE_TOGGLE.NO': 'No',
          'CHOICE_TOGGLE.YES': 'Yes',
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
          paymentStatus: 'awaiting_payment',
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
});
