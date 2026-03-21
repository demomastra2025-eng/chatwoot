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
    useI18n.mockReturnValue({
      locale: { value: 'en' },
      t: vi.fn(key => key),
    });
  });

  afterEach(() => {
    mountedWrappers.forEach(wrapper => wrapper.unmount());
    mountedWrappers = [];
    document.body.innerHTML = '';
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

    expect(wrapper.text()).toContain('2 staff');
    expect(wrapper.text()).not.toContain('1 staff');
  });
});
