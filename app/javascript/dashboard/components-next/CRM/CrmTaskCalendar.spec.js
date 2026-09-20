import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { useI18n } from 'vue-i18n';

import SchedulingVueCalCalendar from 'dashboard/components-next/Scheduling/SchedulingVueCalCalendar.vue';
import CrmTaskCalendar from './CrmTaskCalendar.vue';

vi.mock('vue-i18n');

describe('CrmTaskCalendar', () => {
  beforeEach(() => {
    useI18n.mockReturnValue({
      t: vi.fn(key => key),
    });
  });

  it('forwards managed field definitions and task custom attributes to the scheduling calendar', () => {
    const fieldDefinitions = [
      {
        fieldType: 'select',
        key: 'task_type',
        label: 'Task type',
        options: [{ label: 'Call', value: 'call' }],
      },
    ];

    const wrapper = shallowMount(CrmTaskCalendar, {
      props: {
        anchorDate: '2026-04-01T00:00:00.000Z',
        assigneeNames: { 14: 'Aruzhan' },
        canManage: true,
        dealNames: { 22: 'Enterprise Renewal' },
        fieldDefinitions,
        statusNames: { 7: 'To do' },
        tasks: [
          {
            id: 41,
            assigneeId: 14,
            customAttributes: { task_type: 'call' },
            dealId: 22,
            dueAt: '2026-04-01T11:00:00.000Z',
            priority: 'high',
            startAt: '2026-04-01T10:00:00.000Z',
            statusId: 7,
            title: 'Confirm proposal',
          },
        ],
        view: 'week',
      },
    });

    const calendar = wrapper.findComponent(SchedulingVueCalCalendar);
    const appointments = calendar.props('appointments');

    expect(calendar.props('customFieldDefinitions')).toEqual(fieldDefinitions);
    expect(appointments).toHaveLength(1);
    expect(appointments[0].customAttributes).toEqual({ task_type: 'call' });
  });

  it('places an all-day task in the workspace date strip', () => {
    const wrapper = shallowMount(CrmTaskCalendar, {
      props: {
        anchorDate: '2026-09-04T00:00:00.000Z',
        tasks: [
          {
            allDay: true,
            dueOn: '2026-09-04',
            id: 42,
            title: 'Tomorrow report',
          },
        ],
        view: 'week',
        workspaceTimezone: 'Asia/Almaty',
      },
    });

    const calendar = wrapper.findComponent(SchedulingVueCalCalendar);
    const [appointment] = calendar.props('appointments');

    expect(calendar.props('allDayEvents')).toBe(true);
    expect(calendar.props('workspaceTimezone')).toBe('Asia/Almaty');
    expect(appointment.allDay).toBe(true);
    expect(appointment.startsAt).toBe('2026-09-03T19:00:00.000Z');
    expect(appointment.endsAt).toBe('2026-09-04T18:59:59.999Z');
  });

  it('uses workspace-local day boundaries across a DST fallback', () => {
    const wrapper = shallowMount(CrmTaskCalendar, {
      props: {
        anchorDate: '2026-10-25T00:00:00.000Z',
        tasks: [
          {
            allDay: true,
            dueOn: '2026-10-25',
            id: 46,
            title: 'DST follow-up',
          },
        ],
        view: 'week',
        workspaceTimezone: 'Europe/Berlin',
      },
    });

    const calendar = wrapper.findComponent(SchedulingVueCalCalendar);
    const [appointment] = calendar.props('appointments');

    expect(appointment.startsAt).toBe('2026-10-24T22:00:00.000Z');
    expect(appointment.endsAt).toBe('2026-10-25T22:59:59.999Z');
  });

  it('does not render cancelled tasks as calendar appointments', () => {
    const wrapper = shallowMount(CrmTaskCalendar, {
      props: {
        anchorDate: '2026-09-04T00:00:00.000Z',
        tasks: [
          {
            cancelledAt: '2026-09-04T09:00:00.000Z',
            dueAt: '2026-09-04T11:00:00.000Z',
            id: 43,
            title: 'Cancelled call',
          },
        ],
        view: 'week',
      },
    });

    const calendar = wrapper.findComponent(SchedulingVueCalCalendar);
    expect(calendar.props('appointments')).toEqual([]);
  });

  it('does not mark terminal tasks overdue when terminal tasks are visible', () => {
    const wrapper = shallowMount(CrmTaskCalendar, {
      props: {
        anchorDate: '2000-01-01T00:00:00.000Z',
        taskState: 'all',
        tasks: [
          {
            cancelledAt: '2000-01-02T00:00:00.000Z',
            dueAt: '2000-01-01T11:00:00.000Z',
            id: 47,
            title: 'Cancelled call',
          },
          {
            completedAt: '2000-01-02T00:00:00.000Z',
            dueAt: '2000-01-01T12:00:00.000Z',
            id: 48,
            title: 'Completed call',
          },
        ],
        view: 'week',
      },
    });

    const appointments = wrapper
      .findComponent(SchedulingVueCalCalendar)
      .props('appointments');

    expect(appointments).toHaveLength(2);
    expect(appointments.every(appointment => appointment.hideStatus)).toBe(
      true
    );
  });

  it.each([
    ['completed', { completedAt: '2026-09-04T09:00:00.000Z' }],
    ['cancelled', { cancelledAt: '2026-09-04T09:00:00.000Z' }],
  ])('renders %s tasks when that state is selected', (taskState, state) => {
    const wrapper = shallowMount(CrmTaskCalendar, {
      props: {
        anchorDate: '2026-09-04T00:00:00.000Z',
        tasks: [
          {
            ...state,
            dueAt: '2026-09-04T11:00:00.000Z',
            id: 44,
            title: 'Terminal task',
          },
        ],
        taskState,
        view: 'week',
      },
    });

    const calendar = wrapper.findComponent(SchedulingVueCalCalendar);
    expect(calendar.props('appointments')).toHaveLength(1);
  });

  it('renders archived tasks when the archived filter is selected', () => {
    const wrapper = shallowMount(CrmTaskCalendar, {
      props: {
        anchorDate: '2026-09-04T00:00:00.000Z',
        archived: true,
        tasks: [
          {
            archivedAt: '2026-09-04T09:00:00.000Z',
            dueAt: '2026-09-04T11:00:00.000Z',
            id: 45,
            title: 'Archived task',
          },
        ],
        view: 'week',
      },
    });

    const calendar = wrapper.findComponent(SchedulingVueCalCalendar);
    expect(calendar.props('appointments')).toHaveLength(1);
  });
});
