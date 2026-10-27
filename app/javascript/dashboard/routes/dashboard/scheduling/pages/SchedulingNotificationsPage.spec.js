import { describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import SchedulingNotificationsPage from './SchedulingNotificationsPage.vue';
import ResourcesAPI from 'dashboard/api/scheduling/resources';
import ServicesAPI from 'dashboard/api/scheduling/services';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn().mockResolvedValue(undefined),
  rules: [
    {
      id: 1,
      name: 'Visit reminder',
      event_name: 'appointment_created',
      active: true,
      calendar_managed: true,
      conditions: [],
      actions: [
        {
          action_name: 'create_touch',
          action_params: [
            {
              body: 'Your visit',
              relative_anchor: 'appointment.starts_at',
              relative_offset_seconds: -3600,
            },
          ],
        },
      ],
    },
    {
      id: 2,
      name: 'Existing notice',
      event_name: 'appointment_updated',
      active: true,
      calendar_managed: false,
      conditions: [],
      actions: [
        {
          action_name: 'create_touch',
          action_params: [
            {
              body: 'Updated',
              relative_anchor: 'touch.created_at',
              relative_offset_seconds: 0,
            },
          ],
        },
      ],
    },
    {
      id: 3,
      name: 'Visit status automation',
      event_name: 'appointment_updated',
      active: true,
      calendar_managed: false,
      conditions: [],
      actions: [{ action_name: 'send_webhook_event', action_params: [] }],
    },
  ],
}));
vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key }),
}));
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => ({ query: {} }),
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key =>
    ref(
      key === 'automations/getAutomations'
        ? mocks.rules
        : [{ id: 3, name: 'Test inbox', message_templates: [] }]
    ),
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: {
      value: { workspace_working_hours_timezone: 'Asia/Almaty' },
    },
  }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/scheduling/resources', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/api/scheduling/services', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));

describe('SchedulingNotificationsPage', () => {
  it('shows appointment rules in one list and keeps unadopted rules read-only', async () => {
    ResourcesAPI.get.mockResolvedValue({ data: { payload: [] } });
    ServicesAPI.get.mockResolvedValue({ data: { payload: [] } });
    const wrapper = shallowMount(SchedulingNotificationsPage);
    await flushPromises();

    expect(wrapper.text()).toContain('Visit reminder');
    expect(wrapper.text()).toContain('Existing notice');
    expect(wrapper.text()).toContain('Visit status automation');
    expect(wrapper.text()).toContain(
      'SCHEDULING.NOTIFICATIONS.MANAGE_IN_AUTOMATIONS'
    );
    expect(wrapper.text()).toContain(
      'SCHEDULING.NOTIFICATIONS.ADOPTION_REQUIRED'
    );
    expect(
      wrapper
        .findAll('button')
        .filter(button => button.text() === 'SCHEDULING.NOTIFICATIONS.EDIT')
    ).toHaveLength(1);
    expect(wrapper.text()).toContain(
      'SCHEDULING.REMINDERS.PRESETS.appointment_day_before.TITLE'
    );
  });
});
