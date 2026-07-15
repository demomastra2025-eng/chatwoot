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
});
