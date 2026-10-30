import { describe, it, expect, vi, beforeEach } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import OwnerFinancePage from '../pages/OwnerFinancePage.vue';
import OwnerFinanceAPI from 'dashboard/api/ownerFinance';

vi.mock('dashboard/api/ownerFinance', () => ({
  default: {
    getDashboard: vi.fn(),
    completeDeadline: vi.fn(),
    updateTransaction: vi.fn(),
    hidePersonalTransaction: vi.fn(),
    createDeadline: vi.fn(),
    runDeadlineReminders: vi.fn(),
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const sampleDashboard = {
  period: { year: 2026, month: 10, reference_date: '2026-10-30' },
  kpis: {
    total_balance_kzt: 4200000,
    committed_outflow_30d_kzt: 185000,
    free_cash_kzt: 4015000,
    expected_inflow_30d_kzt: 1194000,
    live_contracts_mrr_kzt: 1187500,
    month_revenue_kzt: 1450000,
    month_expenses_kzt: 310000,
    month_net_profit_kzt: 1140000,
    urgent_deadlines_count: 2,
    rebill_soon_count: 1,
    rebill_soon_kzt: 6500,
    needs_review_count: 1,
    hidden_personal_count: 14,
  },
  accounts: [
    {
      id: 1,
      name: 'ИП Veritas Consult (Kaspi Pay)',
      account_kind: 'business_bank',
      currency: 'KZT',
      current_balance: 4200000,
      balance_kzt: 4200000,
      scope: 'business',
    },
  ],
  deadlines: [
    {
      id: 10,
      title: 'Продление домена kuanov.kz',
      category: 'client_domain',
      payer_mode: 'rebill_client',
      related_domain: 'kuanov.kz',
      client_name: 'Kuanov Clinic',
      due_on: '2026-11-02',
      days_left: 3,
      urgency: 'critical',
      amount: 6500,
      currency: 'KZT',
      amount_kzt: 6500,
      recurrence: 'yearly',
      status: 'active',
      remind_days: [7, 3, 2, 1, 0],
    },
  ],
  contracts: [
    {
      id: 5,
      client_name: 'Клиника Сезім',
      contract_number: 'OL-07',
      title: 'Подписка OneLink',
      status: 'active',
      tariff_code: 'ai_agent_rop_199k',
      monthly_amount: 199000,
      monthly_amount_kzt: 199000,
      one_time_amount: 0,
      currency: 'KZT',
      ends_on: '2027-10-01',
      medelement_commission_enabled: true,
      medelement_monthly_commission_kzt: 59700,
    },
  ],
  needs_review_transactions: [
    {
      id: 77,
      occurred_on: '2026-10-29',
      direction: 'expense',
      pnl_treatment: 'non_pnl',
      official_status: 'management',
      review_status: 'needs_review',
      amount: 5400,
      currency: 'KZT',
      amount_kzt: 5400,
      category: 'unclassified_card',
      category_label: 'Ожидает разметки с карты',
      merchant: 'Magnum Almaty',
      description: 'Покупка с карты',
    },
  ],
  transactions: [],
  obligations: [],
  expense_breakdown: [
    {
      category: 'servers_and_cloud',
      label: 'Серверы, ЦОД и домены',
      amount_kzt: 130480,
    },
  ],
  monthly_series: [
    {
      month: 10,
      revenue_kzt: 1450000,
      expenses_kzt: 310000,
      net_profit_kzt: 1140000,
    },
  ],
  category_options: [
    { code: 'servers_and_cloud', label: 'Серверы, ЦОД и домены' },
    { code: 'office_and_ops', label: 'Операционные расходы' },
  ],
  sync_states: {},
};

describe('OwnerFinancePage', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    OwnerFinanceAPI.getDashboard.mockResolvedValue({ data: sampleDashboard });
    OwnerFinanceAPI.completeDeadline.mockResolvedValue({ data: {} });
    OwnerFinanceAPI.hidePersonalTransaction.mockResolvedValue({
      data: { hidden_count: 1, hide_merchant_always: false },
    });
  });

  const mountPage = () =>
    mount(OwnerFinancePage, {
      global: {
        stubs: {
          Button: {
            props: ['label'],
            template:
              '<button type="button" @click="$emit(\'click\')">{{ label }}</button>',
          },
          Spinner: { template: '<div class="spinner" />' },
        },
      },
    });

  it('renders KPI strip, accounts, and upcoming deadlines and completes a deadline', async () => {
    const wrapper = mountPage();
    await flushPromises();

    expect(wrapper.text()).toContain('Финансы и сроки');
    expect(wrapper.text()).toContain('ИП Veritas Consult (Kaspi Pay)');
    expect(wrapper.text()).toContain('Продление домена kuanov.kz');
    expect(wrapper.text()).toContain('Перевыставить клиенту');

    const completeBtn = wrapper
      .findAll('button')
      .find(b => b.text().includes('Продлить / Закрыть'));
    expect(completeBtn).toBeTruthy();
    await completeBtn.trigger('click');
    await flushPromises();

    expect(OwnerFinanceAPI.completeDeadline).toHaveBeenCalledWith(10);
  });

  it('switches to transactions tab and hides personal card purchase into tombstone', async () => {
    const wrapper = mountPage();
    await flushPromises();

    await wrapper.find('[data-test="tab-transactions"]').trigger('click');
    expect(wrapper.text()).toContain('Magnum Almaty');

    const hideBtn = wrapper.findAll('button').find(b => b.text() === 'Личное');
    expect(hideBtn).toBeTruthy();
    await hideBtn.trigger('click');
    await flushPromises();

    expect(OwnerFinanceAPI.hidePersonalTransaction).toHaveBeenCalledWith(77, {
      hideMerchantAlways: false,
    });
  });
});
