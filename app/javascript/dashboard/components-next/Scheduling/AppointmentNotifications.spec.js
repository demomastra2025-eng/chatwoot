import { describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import AppointmentNotifications from './AppointmentNotifications.vue';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';

vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key, locale: { value: 'ru' } }),
}));

vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: { notifications: vi.fn() },
}));

describe('AppointmentNotifications', () => {
  it('shows planned, sent, skipped and failed states with staff-facing reasons', async () => {
    SchedulingAppointmentsAPI.notifications.mockResolvedValue({
      data: {
        payload: [
          { id: 1, status: 'pending', scheduled_at: '2026-11-01T10:00:00Z' },
          { id: 2, status: 'completed', scheduled_at: '2026-11-01T11:00:00Z' },
          { id: 3, status: 'cancelled', reason: 'appointment_started' },
          { id: 4, status: 'failed', reason: 'provider_timeout' },
        ],
      },
    });
    const wrapper = mount(AppointmentNotifications, {
      props: { appointmentId: 17 },
      global: { mocks: { $t: key => key }, stubs: { RouterLink: true } },
    });
    await flushPromises();

    expect(SchedulingAppointmentsAPI.notifications).toHaveBeenCalledWith(17);
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.PATIENT_TITLE');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.PLANNED');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.SENT');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.SKIPPED');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.NOT_DELIVERED');
    expect(wrapper.text()).toContain(
      'SCHEDULING.NOTIFICATIONS.REASONS.APPOINTMENT_STARTED'
    );
    expect(wrapper.text()).not.toContain('provider_timeout');
  });

  it('shows the rule, delivery state and a link to the existing message', async () => {
    SchedulingAppointmentsAPI.notifications.mockResolvedValue({
      data: {
        payload: [
          {
            id: 5,
            rule_name: 'Напоминание',
            status: 'pending',
            delivery_stage: 'materialized',
            message_status: 'read',
            message_id: 21,
            conversation_id: 12,
          },
          {
            id: 6,
            rule_name: 'Приём',
            status: 'completed',
            delivery_stage: 'materialized',
            message_status: 'delivered',
          },
        ],
      },
    });
    const wrapper = mount(AppointmentNotifications, {
      props: { appointmentId: 17 },
      global: {
        mocks: { $t: key => key, $route: { params: { accountId: 1 } } },
        stubs: {
          RouterLink: {
            name: 'RouterLink',
            props: ['to'],
            template: '<a><slot /></a>',
          },
        },
      },
    });
    await flushPromises();

    expect(wrapper.text()).toContain('Напоминание');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.READ');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.DELIVERED');
    expect(wrapper.findComponent({ name: 'RouterLink' }).props('to')).toEqual({
      name: 'inbox_conversation',
      params: { accountId: 1, conversation_id: 12 },
      query: { messageId: 21 },
    });
  });
});
