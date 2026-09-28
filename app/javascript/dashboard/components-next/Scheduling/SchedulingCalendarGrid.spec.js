import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { useI18n } from 'vue-i18n';

import CrmCustomFieldsSummary from 'dashboard/components-next/CRM/CrmCustomFieldsSummary.vue';
import SchedulingCalendarGrid from './SchedulingCalendarGrid.vue';

vi.mock('vue-i18n');

const baseProps = {
  anchorDate: '2026-03-29T00:00:00.000Z',
  appointments: [],
  breakRules: [],
  customFieldDefinitions: [],
  holidays: [],
  presentation: 'list',
  resources: [{ id: 12, name: 'Dr. Sam' }],
  slots: [],
  timeOffs: [],
  view: 'week',
  workRules: [],
  workdayOverrides: [],
};

const mountGrid = props =>
  mount(SchedulingCalendarGrid, {
    props: {
      ...baseProps,
      ...props,
    },
    global: {
      stubs: {
        SchedulingVueCalCalendar: {
          name: 'SchedulingVueCalCalendar',
          props: {
            allowOutsideWorkingHours: Boolean,
            allowOverlappingAppointments: Boolean,
          },
          template: '<div class="calendar-stub" />',
        },
        SchedulingStatusMenu: {
          template: '<div class="status-menu-stub" />',
        },
      },
    },
  });

describe('SchedulingCalendarGrid', () => {
  beforeEach(() => {
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

  it('forwards account availability policies to the interactive calendar', () => {
    const wrapper = mountGrid({
      allowOutsideWorkingHours: true,
      allowOverlappingAppointments: true,
      presentation: 'calendar',
    });
    const calendar = wrapper.findComponent({
      name: 'SchedulingVueCalCalendar',
    });

    expect(calendar.props('allowOutsideWorkingHours')).toBe(true);
    expect(calendar.props('allowOverlappingAppointments')).toBe(true);
  });

  it('renders appointment custom field summaries in list view', () => {
    const wrapper = mountGrid({
      appointments: [
        {
          clientName: 'Alex Doe',
          customAttributes: {
            needs_lab: true,
            visit_reason: 'follow_up',
          },
          endsAt: '2026-03-29T10:30:00.000Z',
          id: 41,
          resourceId: 12,
          resourceName: 'Dr. Sam',
          serviceNameSnapshot: 'Consultation',
          startsAt: '2026-03-29T10:00:00.000Z',
          status: 'confirmed',
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

    expect(wrapper.text()).toContain('Dr. Sam');
    expect(wrapper.text()).toContain('Visit Reason:');
    expect(wrapper.text()).toContain('Follow-up');
    expect(wrapper.text()).toContain('Needs Lab:');
    expect(wrapper.text()).toContain('Yes');
    expect(
      wrapper.findComponent(CrmCustomFieldsSummary).props('truncate')
    ).toBe(false);
  });

  it('hides empty days in list view', () => {
    const wrapper = mountGrid({
      appointments: [
        {
          clientName: 'Alex Doe',
          endsAt: '2026-03-29T10:30:00.000Z',
          id: 41,
          resourceId: 12,
          serviceNameSnapshot: 'Consultation',
          startsAt: '2026-03-29T10:00:00.000Z',
          status: 'confirmed',
        },
      ],
    });

    expect(wrapper.findAll('section')).toHaveLength(1);
    expect(wrapper.text()).not.toContain('No appointments for this day');
  });

  it('groups a near-midnight UTC appointment under its Workspace day', () => {
    const wrapper = mountGrid({
      anchorDate: '2026-03-29T21:00:00.000Z',
      view: 'day',
      workspaceTimezone: 'Asia/Almaty',
      appointments: [
        {
          clientName: 'Alex Doe',
          endsAt: '2026-03-29T20:00:00.000Z',
          id: 41,
          resourceId: 12,
          startsAt: '2026-03-29T19:30:00.000Z',
          status: 'confirmed',
        },
      ],
    });

    expect(wrapper.findAll('section')).toHaveLength(1);
    expect(wrapper.text()).toContain('Alex Doe');
    expect(wrapper.text()).toContain('12:30 AM');
  });

  it('lists the real Workspace 02:30 during the browser spring gap', () => {
    const wrapper = mountGrid({
      anchorDate: '2026-03-07T21:30:00.000Z',
      view: 'day',
      workspaceTimezone: 'Asia/Almaty',
      appointments: [
        {
          id: 77,
          clientName: 'Gap consultation',
          resourceId: 12,
          startsAt: '2026-03-07T21:30:00.000Z',
          endsAt: '2026-03-07T22:00:00.000Z',
        },
      ],
    });

    expect(wrapper.findAll('section')).toHaveLength(1);
    expect(wrapper.find('section').text()).toContain('Gap consultation');
    expect(wrapper.find('section').text()).toContain('02:30');
  });

  it('uses actual Workspace midnight and DST boundaries in list grouping', () => {
    const wrapper = mountGrid({
      anchorDate: '2026-03-08T09:30:00.000Z',
      view: 'day',
      workspaceTimezone: 'America/Los_Angeles',
      appointments: [
        {
          clientName: 'DST visit',
          endsAt: '2026-03-08T10:30:00.000Z',
          id: 42,
          resourceId: 12,
          startsAt: '2026-03-08T09:30:00.000Z',
          status: 'confirmed',
        },
      ],
    });

    expect(wrapper.findAll('section')).toHaveLength(1);
    expect(wrapper.text()).toContain('DST visit');
    expect(wrapper.text()).toContain('01:30');
    expect(wrapper.text()).toContain('03:30');
  });
});
