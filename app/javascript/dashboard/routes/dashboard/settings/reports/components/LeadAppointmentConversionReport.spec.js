import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import LeadAppointmentConversionReport from './LeadAppointmentConversionReport.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: ref('en') }),
}));

describe('lead appointment conversion report', () => {
  it('keeps lead and appointment units separate and labels unknown attendance without inflating conversion', () => {
    const wrapper = mount(LeadAppointmentConversionReport, {
      props: {
        report: {
          leads_count: 1,
          booked_leads_count: 1,
          attended_leads_count: 0,
          appointments_count: 2,
          booking_conversion_percent: 100,
          attendance_conversion_percent: 0,
          unknown_attendance_appointments_count: 1,
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
    expect(wrapper.text()).toContain('CRM.LEAD_CONVERSION.UNKNOWN_ATTENDANCE');
    expect(wrapper.text()).toContain('Original inbox');
    expect(wrapper.text()).toContain('instagram');
    expect(wrapper.find('tbody tr').text()).toContain('2');
  });
});
