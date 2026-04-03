import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { useI18n } from 'vue-i18n';

import SchedulingKanbanBoard from './SchedulingKanbanBoard.vue';

vi.mock('vue-i18n');

const DraggableStub = defineComponent({
  name: 'DraggableStub',
  props: {
    list: {
      type: Array,
      default: () => [],
    },
  },
  setup(props, { slots }) {
    return () =>
      h('div', [
        ...(props.list || []).flatMap(
          element => slots.item?.({ element }) || []
        ),
        slots.footer?.(),
      ]);
  },
});

const mountBoard = props =>
  mount(SchedulingKanbanBoard, {
    props: {
      appointments: [],
      customFieldDefinitions: [],
      resources: [{ id: 12, name: 'Dr. Sam' }],
      ...props,
    },
    global: {
      stubs: {
        Draggable: DraggableStub,
        SchedulingStatusMenu: {
          template: '<div class="status-menu-stub" />',
        },
      },
    },
  });

describe('SchedulingKanbanBoard', () => {
  beforeEach(() => {
    useI18n.mockReturnValue({
      locale: { value: 'en' },
      t: vi.fn(key => {
        const labels = {
          'CHOICE_TOGGLE.NO': 'No',
          'CHOICE_TOGGLE.YES': 'Yes',
          'SCHEDULING.APPOINTMENT_STATUS.cancelled': 'Cancelled',
          'SCHEDULING.APPOINTMENT_STATUS.completed': 'Completed',
          'SCHEDULING.APPOINTMENT_STATUS.confirmed': 'Confirmed',
          'SCHEDULING.APPOINTMENT_STATUS.no_show': 'No show',
          'SCHEDULING.APPOINTMENT_STATUS.scheduled': 'Scheduled',
          'SCHEDULING.CALENDAR.NO_APPOINTMENTS_STATUS': 'No appointments',
        };

        return labels[key] || key;
      }),
    });
  });

  it('renders appointment custom field summaries inside cards', () => {
    const wrapper = mountBoard({
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
          serviceNameSnapshot: 'Consultation',
          startsAt: '2026-03-29T10:00:00.000Z',
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

    expect(wrapper.text()).toContain('Visit Reason:');
    expect(wrapper.text()).toContain('Follow-up');
    expect(wrapper.text()).toContain('Needs Lab:');
    expect(wrapper.text()).toContain('Yes');
  });
});
