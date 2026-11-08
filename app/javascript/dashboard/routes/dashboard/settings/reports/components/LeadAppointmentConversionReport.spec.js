import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import LeadAppointmentConversionReport from './LeadAppointmentConversionReport.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: ref('en') }),
}));

describe('lead appointment conversion report', () => {
  it('keeps lead and appointment units separate, renders 4-status schedule finance, full funnel, and WhatsApp touches', () => {
    const wrapper = mount(LeadAppointmentConversionReport, {
      props: {
        report: {
          leads_count: 1,
          booked_leads_count: 1,
          attended_leads_count: 0,
          appointments_count: 2,
          rescheduled_appointments_count: 1,
          early_cancelled_appointments_count: 0,
          true_no_show_appointments_count: 1,
          booking_conversion_percent: 100,
          attendance_conversion_percent: 0,
          net_attendance_rate_percent: 50,
          unknown_attendance_appointments_count: 1,
          all_contacts_funnel: {
            contacts_count: 3,
            booked_contacts_count: 2,
            attended_contacts_count: 1,
            booking_conversion_percent: 66.7,
            attendance_conversion_percent: 33.3,
            primary_contacts_count: 1,
            repeat_contacts_count: 2,
          },
          schedule_breakdown: {
            completed_revenue_kzt: 15000,
            rescheduled_saved_revenue_kzt: 12000,
            true_no_show_lost_revenue_kzt: 8000,
            net_attendance_rate_percent: 90,
          },
          whatsapp_touches: {
            total_sent_count: 10,
            reminder_1d_sent_count: 4,
            reminder_1d_confirmation_rate_percent: 75,
            reminder_2h_sent_count: 4,
            review_request_sent_count: 2,
          },
          attribution_breakdown: [
            {
              inbox_id: 3,
              inbox_name: 'Original inbox',
              source: 'instagram',
              leads_count: 1,
              booked_leads_count: 1,
              attended_leads_count: 0,
              appointments_count: 2,
            },
          ],
        },
      },
      global: { mocks: { $t: key => key }, stubs: { ReportMetricCard: true } },
    });
    const cards = wrapper.findAllComponents({ name: 'ReportMetricCard' });
    expect(
      cards
        .find(card => card.props('label') === 'CRM.LEAD_CONVERSION.LEADS')
        .props('value')
    ).toBe('1');
    expect(
      cards
        .find(
          card =>
            card.props('label') === 'CRM.LEAD_CONVERSION.ATTENDANCE_CONVERSION'
        )
        .props('value')
    ).toBe('0%');
    expect(
      cards
        .find(
          card =>
            card.props('label') === 'CRM.LEAD_CONVERSION.NET_ATTENDANCE_RATE'
        )
        .props('value')
    ).toBe('90%');
    expect(wrapper.find('[data-testid="all-contacts-funnel"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="schedule-finance-breakdown"]').text()).toContain('15,000 ₸');
    expect(wrapper.find('[data-testid="whatsapp-touches-summary"]').text()).toContain('75%');
    expect(wrapper.text()).toContain('CRM.LEAD_CONVERSION.UNKNOWN_ATTENDANCE');
    expect(wrapper.text()).toContain('Original inbox');
    expect(wrapper.text()).toContain('instagram');
    expect(wrapper.find('tbody tr').text()).toContain('2');
  });
});
