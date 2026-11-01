import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import OwnerFinancePage from '../pages/OwnerFinancePage.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import { useAlert } from 'dashboard/composables';
import { UI } from '../constants';
import OwnerFinanceAPI from 'dashboard/api/ownerFinance';

vi.mock('dashboard/api/ownerFinance', () => ({
  default: {
    getDashboard: vi.fn(),
    completeDeadline: vi.fn(),
    updateTransaction: vi.fn(),
    hidePersonalTransaction: vi.fn(),
    createDeadline: vi.fn(),
    createAccount: vi.fn(),
    createTransaction: vi.fn(),
    createContract: vi.fn(),
    createObligation: vi.fn(),
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
    Object.defineProperty(HTMLDialogElement.prototype, 'showModal', {
      configurable: true,
      value: vi.fn(function showModal() {
        this.open = true;
      }),
    });
    Object.defineProperty(HTMLDialogElement.prototype, 'close', {
      configurable: true,
      value: vi.fn(function close() {
        this.open = false;
        this.dispatchEvent(new Event('close'));
      }),
    });
    OwnerFinanceAPI.getDashboard.mockResolvedValue({ data: sampleDashboard });
    OwnerFinanceAPI.completeDeadline.mockResolvedValue({ data: {} });
    OwnerFinanceAPI.hidePersonalTransaction.mockResolvedValue({
      data: { hidden_count: 1, hide_merchant_always: false },
    });
  });

  afterEach(() => vi.restoreAllMocks());

  const mountPage = (options = {}) =>
    mount(OwnerFinancePage, {
      ...options,
      global: {
        stubs: {
          TeleportWithDirection: { template: '<div><slot /></div>' },
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
  const clickLabel = async (wrapper, label) => {
    const action = wrapper
      .findAll('button')
      .find(button => button.text() === label);
    expect(action).toBeTruthy();
    await action.trigger('click');
    await flushPromises();
  };

  it.each([
    ['deadline', UI.ADD_DEADLINE, null, 'title', 'createDeadline'],
    ['account', UI.ADD_ACCOUNT, null, 'name', 'createAccount'],
    [
      'transaction',
      UI.ADD_TRANSACTION,
      'transactions',
      'merchant',
      'createTransaction',
    ],
    ['contract', UI.ADD_CONTRACT, 'contracts', 'client_name', 'createContract'],
    ['obligation', UI.ADD_OBLIGATION, 'contracts', 'title', 'createObligation'],
  ])(
    'submits the %s form once, keeps failed data and closes after retry succeeds',
    async (kind, label, tab, field, method) => {
      const wrapper = mountPage();
      await flushPromises();
      if (tab) await wrapper.get(`[data-test="tab-${tab}"]`).trigger('click');
      await clickLabel(wrapper, label);
      expect(wrapper.get('dialog').element.open).toBe(true);
      expect(wrapper.findAll('form')).toHaveLength(1);
      const input = wrapper.get(
        `#finance-${kind === 'transaction' ? 'tx' : kind}Form-${field}`
      );
      await input.setValue('Synthetic fixture');
      let rejectSave;
      OwnerFinanceAPI[method].mockImplementationOnce(
        () =>
          new Promise((_resolve, reject) => {
            rejectSave = reject;
          })
      );
      const dialog = wrapper.getComponent(Dialog);
      dialog.vm.$emit('confirm');
      dialog.vm.$emit('confirm');
      await flushPromises();
      expect(OwnerFinanceAPI[method]).toHaveBeenCalledTimes(1);
      expect(dialog.props('isLoading')).toBe(true);
      expect(dialog.props('disableConfirmButton')).toBe(true);
      rejectSave(new Error('synthetic failure'));
      await flushPromises();
      expect(wrapper.get('dialog').element.open).toBe(true);
      expect(input.element.value).toBe('Synthetic fixture');
      expect(useAlert).toHaveBeenCalled();
      OwnerFinanceAPI[method].mockResolvedValueOnce({ data: {} });
      await wrapper.get('form').trigger('submit');
      await flushPromises();
      expect(OwnerFinanceAPI[method]).toHaveBeenCalledTimes(2);
      expect(wrapper.get('dialog').element.open).toBe(false);
      wrapper.unmount();
    }
  );

  it('cancels the native dialog without saving', async () => {
    const wrapper = mountPage();
    await flushPromises();
    await clickLabel(wrapper, UI.ADD_DEADLINE);
    await clickLabel(wrapper, UI.CANCEL);
    expect(wrapper.get('dialog').element.open).toBe(false);
    expect(OwnerFinanceAPI.createDeadline).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it.each([
    [
      'contract',
      UI.ADD_CONTRACT,
      'client_name',
      'monthly_amount',
      'createContract',
    ],
    [
      'obligation',
      UI.ADD_OBLIGATION,
      'title',
      'base_amount',
      'createObligation',
    ],
  ])(
    'saves decimal money through native form validation in the %s dialog',
    async (kind, label, name, amount, method) => {
      const wrapper = mountPage({ attachTo: document.body });
      await flushPromises();
      await wrapper.get('[data-test="tab-contracts"]').trigger('click');
      await clickLabel(wrapper, label);
      await wrapper
        .get(`#finance-${kind}Form-${name}`)
        .setValue('Synthetic fixture');
      await wrapper.get(`#finance-${kind}Form-${amount}`).setValue('100001.23');
      const form = wrapper.get('form').element;
      expect(form.checkValidity()).toBe(true);
      OwnerFinanceAPI[method].mockResolvedValueOnce({ data: {} });
      wrapper.get('button[type="submit"]').element.click();
      await flushPromises();
      expect(OwnerFinanceAPI[method]).toHaveBeenCalledTimes(1);
      expect(OwnerFinanceAPI[method].mock.calls[0][0][amount]).toBe(100001.23);
      expect(wrapper.get('dialog').element.open).toBe(false);
      wrapper.unmount();
    }
  );
});
