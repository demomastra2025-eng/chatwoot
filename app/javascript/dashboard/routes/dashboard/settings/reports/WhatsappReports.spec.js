import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import WhatsappReports from './WhatsappReports.vue';

const mocks = vi.hoisted(() => ({
  accountId: '74',
  getMonthlyUsage: null,
}));

vi.mock('vue-router', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    useRoute: () => ({
      params: { accountId: mocks.accountId },
    }),
  };
});

vi.mock('dashboard/api/whatsappUsage', () => ({
  default: {
    getMonthlyUsage: (...args) => mocks.getMonthlyUsage(...args),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: ref('ru'),
    t: (key, values = {}) =>
      Object.entries(values).reduce(
        (msg, [name, val]) => msg.replace(`{${name}}`, val),
        key
      ),
  }),
}));

const sampleUsage = {
  month: '2026-10',
  currency: 'KZT',
  eligible: true,
  official_cloud_phone_count: 1,
  delivered_count: 5831,
  service_delivered_count: 5539,
  template_delivered_count: 292,
  chargeable_message_count: 5210,
  free_service_quota_count: 621,
  free_service_quota_limit: 1000,
  free_service_quota_limit_per_phone: 1000,
  vat_rate_percent: 12,
  estimated_amount_usd: '164.51',
  estimated_amount_kzt: '72528.13',
  estimated_amount_with_vat_kzt: '81231.51',
  exchange_rate: {
    available: true,
    rate_per_usd: '440.86',
  },
  consecutive_summary: {
    window_seconds: 300,
    consecutive_service_count: 1559,
    chargeable_consecutive_count: 1404,
    consecutive_ratio_percent: 28.5,
    estimated_overpayment_kzt: '11141.41',
    estimated_overpayment_with_vat_kzt: '12478.38',
  },
  managers: [
    {
      user_id: 10,
      name: 'Айғаным',
      delivered_count: 3538,
      service_delivered_count: 3349,
      chargeable_count: 3198,
      free_count: 340,
      consecutive_count: 1003,
      chargeable_consecutive_count: 905,
      consecutive_ratio_percent: 30.0,
      estimated_amount_kzt: '25377.7',
      estimated_amount_with_vat_kzt: '28423.02',
      consecutive_overpayment_kzt: '7181.61',
      consecutive_overpayment_with_vat_kzt: '8043.4',
    },
    {
      user_id: 11,
      name: 'Жасмин',
      delivered_count: 1166,
      service_delivered_count: 1068,
      chargeable_count: 963,
      free_count: 203,
      consecutive_count: 302,
      chargeable_consecutive_count: 262,
      consecutive_ratio_percent: 28.3,
      estimated_amount_kzt: '7641.87',
      estimated_amount_with_vat_kzt: '8558.89',
      consecutive_overpayment_kzt: '2079.09',
      consecutive_overpayment_with_vat_kzt: '2328.58',
    },
  ],
  category_breakdown: [
    {
      category: 'service',
      delivered_count: 5539,
      chargeable_count: 4918,
      free_count: 621,
      unknown_billable_count: 0,
    },
    {
      category: 'utility',
      delivered_count: 3,
      chargeable_count: 3,
      free_count: 0,
      unknown_billable_count: 0,
    },
    {
      category: 'marketing',
      delivered_count: 289,
      chargeable_count: 289,
      free_count: 0,
      unknown_billable_count: 0,
    },
  ],
  phones: [
    {
      phone_number: '+77712281332',
      connected: true,
      delivered_count: 5831,
      free_service_quota_count: 621,
      free_service_quota_limit: 1000,
      estimated_amount_kzt: '72528.13',
      estimated_amount_with_vat_kzt: '81231.51',
    },
  ],
};

describe('WhatsappReports.vue', () => {
  beforeEach(() => {
    mocks.getMonthlyUsage = vi.fn().mockResolvedValue({
      data: { whatsapp_usage: sampleUsage },
    });
  });

  it('renders KPI cards, formula explanation, managers table with consecutive double messages, and categories', async () => {
    const wrapper = mount(WhatsappReports, {
      global: {
        stubs: {
          ReportHeader: {
            props: ['headerTitle', 'headerDescription'],
            template: '<div><h1>{{ headerTitle }}</h1><slot /></div>',
          },
          Button: {
            props: ['label'],
            template: '<button>{{ label }}</button>',
          },
          Spinner: { template: '<div />' },
        },
      },
    });
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledWith(74);
    expect(wrapper.get('[data-testid="whatsapp-report-kpis"]').exists()).toBe(
      true
    );
    expect(
      wrapper.get('[data-testid="whatsapp-report-consecutive-kpi"]').text()
    ).toContain('28.5%');

    const managerRows = wrapper.findAll(
      '[data-testid="whatsapp-report-manager-row"]'
    );
    expect(managerRows).toHaveLength(2);
    expect(managerRows[0].text()).toContain('Айғаным');
    expect(managerRows[0].text()).toContain('30%');
    expect(managerRows[1].text()).toContain('Жасмин');
  });
});
