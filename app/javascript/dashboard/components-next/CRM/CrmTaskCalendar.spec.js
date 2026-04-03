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
});
