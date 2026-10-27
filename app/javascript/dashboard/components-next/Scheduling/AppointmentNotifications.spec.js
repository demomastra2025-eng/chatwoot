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
      global: { mocks: { $t: key => key } },
    });
    await flushPromises();

    expect(SchedulingAppointmentsAPI.notifications).toHaveBeenCalledWith(17);
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.PLANNED');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.SENT');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.SKIPPED');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.NOT_DELIVERED');
    expect(wrapper.text()).toContain(
      'SCHEDULING.NOTIFICATIONS.REASONS.APPOINTMENT_STARTED'
    );
    expect(wrapper.text()).not.toContain('provider_timeout');
  });
});
