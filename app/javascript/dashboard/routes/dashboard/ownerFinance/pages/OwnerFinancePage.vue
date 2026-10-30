<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue';
import OwnerFinanceAPI from 'dashboard/api/ownerFinance';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import {
  ACCOUNT_KIND_OPTIONS,
  ACCOUNT_SCOPE_OPTIONS,
  CONTRACT_STATUS_OPTIONS,
  CONTRACT_STATUS_SHORT,
  CONTRACT_TARIFF_OPTIONS,
  CONTRACT_TARIFF_SHORT,
  CURRENCY_OPTIONS,
  DEADLINE_CATEGORY_FILTERS,
  DEADLINE_CATEGORY_LABELS,
  MONTH_OPTIONS,
  OBLIGATION_KIND_OPTIONS,
  OBLIGATION_KIND_SHORT,
  PAYER_MODE_OPTIONS,
  PAYER_MODE_SHORT,
  RECURRENCE_OPTIONS,
  RECURRENCE_SHORT,
  TX_DIRECTION_OPTIONS,
  TX_PNL_OPTIONS,
  UI,
  deadlineDaysBadge,
  formatDateRu,
  formatDateTimeRu,
  formatKzt,
  formatMoney,
} from '../constants';

function getAlmatyYearMonth() {
  try {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Almaty',
      year: 'numeric',
      month: '2-digit',
    }).formatToParts(new Date());
    const year = Number(parts.find(p => p.type === 'year')?.value);
    const month = Number(parts.find(p => p.type === 'month')?.value);
    if (year && month) return { year, month };
  } catch {
    // Fallback to local clock if Intl timeZone is unavailable
  }
  const fallback = new Date();
  return { year: fallback.getFullYear(), month: fallback.getMonth() + 1 };
}

const initialAlmaty = getAlmatyYearMonth();
const selectedYear = ref(initialAlmaty.year);
const selectedMonth = ref(initialAlmaty.month);
const activeTab = ref('overview');

const isLoading = ref(false);
const loadError = ref('');
const isSaving = ref(false);
const isUploading = ref(false);
const isRunningReminders = ref(false);
const isSyncingOnec = ref(false);

const dashboard = ref(null);
const lastImportSummary = ref(null);
const uploadAccountId = ref('');
const fileInputRef = ref(null);

// Filters
const deadlineCategoryFilter = ref('all');
const deadlineOnlyRebill = ref(false);
const deadlineShowCompleted = ref(false);
const deadlineSearch = ref('');

const txDirectionFilter = ref('all');
const txSearch = ref('');
const reviewDraftCategories = reactive({});

const obligationFilter = ref('open');

// Modals
const activeModal = ref('');

const deadlineForm = reactive({
  id: null,
  title: '',
  category: 'hosting',
  payer_mode: 'us',
  provider: '',
  related_domain: '',
  client_name: '',
  due_on: '',
  amount: 0,
  currency: 'KZT',
  recurrence: 'yearly',
  remind_days_text: '7, 3, 2, 1, 0',
  notes: '',
});

const accountForm = reactive({
  id: null,
  name: '',
  account_kind: 'business_bank',
  scope: 'business',
  bank_code: '',
  currency: 'KZT',
  current_balance: 0,
  notes: '',
});

const txForm = reactive({
  id: null,
  occurred_on: '',
  direction: 'expense',
  pnl_treatment: 'pnl',
  official_status: 'management',
  amount: 0,
  currency: 'KZT',
  category: 'servers_and_cloud',
  merchant: '',
  description: '',
  account_record_id: '',
  learn_vendor: true,
});

const contractForm = reactive({
  id: null,
  client_name: '',
  contract_number: '',
  title: 'Подписка OneLink',
  status: 'active',
  tariff_code: 'ai_agent_rop_199k',
  monthly_amount: 199000,
  one_time_amount: 0,
  currency: 'KZT',
  billing_day: 5,
  starts_on: '',
  ends_on: '',
  onelink_account_id: '',
  medelement_commission_enabled: false,
  medelement_commission_rate: 0.3,
  notes: '',
});

const obligationForm = reactive({
  id: null,
  entry_kind: 'medelement_commission',
  title: '',
  counterparty_name: 'МИС МедЭлемент',
  period_label: '',
  base_amount: 0,
  overage_excluded_amount: 0,
  amount: 0,
  paid_amount: 0,
  currency: 'KZT',
  due_on: '',
  status: 'open',
  notes: '',
});

const yearOptions = computed(() => {
  const base = initialAlmaty.year;
  const startYear = Math.min(2023, base - 2);
  const endYear = base + 1;
  return Array.from(
    { length: endYear - startYear + 1 },
    (_, idx) => startYear + idx
  );
});

const kpis = computed(() => dashboard.value?.kpis || {});
const accounts = computed(() => dashboard.value?.accounts || []);
const businessAccounts = computed(() =>
  accounts.value.filter(acc => acc.scope === 'business')
);
const personalFilterAccounts = computed(() =>
  accounts.value.filter(acc => acc.scope !== 'business')
);
const deadlines = computed(() => dashboard.value?.deadlines || []);
const contracts = computed(() => dashboard.value?.contracts || []);
const obligations = computed(() => dashboard.value?.obligations || []);
const needsReviewTransactions = computed(
  () => dashboard.value?.needs_review_transactions || []
);
const transactions = computed(() => dashboard.value?.transactions || []);
const expenseBreakdown = computed(
  () => dashboard.value?.expense_breakdown || []
);
const monthlySeries = computed(() => dashboard.value?.monthly_series || []);
const categoryOptions = computed(() => dashboard.value?.category_options || []);
const onecSyncState = computed(
  () => dashboard.value?.sync_states?.onec_fresh || null
);

const upcomingDeadlines30d = computed(() =>
  deadlines.value
    .filter(item => item.status === 'active' && Number(item.days_left) <= 30)
    .slice(0, 12)
);

const filteredDeadlines = computed(() => {
  const q = deadlineSearch.value.trim().toLowerCase();
  return deadlines.value.filter(item => {
    if (!deadlineShowCompleted.value && item.status !== 'active') return false;
    if (
      deadlineCategoryFilter.value !== 'all' &&
      item.category !== deadlineCategoryFilter.value
    ) {
      return false;
    }
    if (deadlineOnlyRebill.value && item.payer_mode !== 'rebill_client') {
      return false;
    }
    if (!q) return true;
    const haystack = [
      item.title,
      item.related_domain,
      item.client_name,
      item.provider,
      item.notes,
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();
    return haystack.includes(q);
  });
});

const filteredTransactions = computed(() => {
  const q = txSearch.value.trim().toLowerCase();
  return transactions.value.filter(item => {
    if (
      txDirectionFilter.value !== 'all' &&
      item.direction !== txDirectionFilter.value
    ) {
      return false;
    }
    if (!q) return true;
    const haystack = [item.merchant, item.description, item.category_label]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();
    return haystack.includes(q);
  });
});

const filteredObligations = computed(() => {
  return obligations.value.filter(item => {
    if (obligationFilter.value === 'paid') return item.status === 'paid';
    if (item.status !== 'open') return false;
    if (obligationFilter.value === 'open') return true;
    if (obligationFilter.value === 'medelement') {
      return item.entry_kind === 'medelement_commission';
    }
    if (obligationFilter.value === 'partner') {
      return item.entry_kind === 'partner_settlement';
    }
    if (obligationFilter.value === 'receivable') {
      return item.entry_kind === 'receivable_debt';
    }
    if (obligationFilter.value === 'payable') {
      return item.entry_kind === 'payable_debt';
    }
    return true;
  });
});

const maxExpenseCategoryKzt = computed(() => {
  if (!expenseBreakdown.value.length) return 1;
  return Math.max(
    ...expenseBreakdown.value.map(item => Number(item.amount_kzt || 0)),
    1
  );
});

const totalExpensesBreakdownKzt = computed(() =>
  expenseBreakdown.value.reduce(
    (acc, item) => acc + Number(item.amount_kzt || 0),
    0
  )
);

const monthShortName = monthNum => {
  const found = MONTH_OPTIONS.find(m => m.value === Number(monthNum));
  return found ? found.short : String(monthNum);
};

const extractErrorMessage = error =>
  error?.response?.data?.error ||
  error?.response?.data?.message ||
  error?.message ||
  'Ошибка запроса';

const fetchDashboard = async () => {
  isLoading.value = true;
  loadError.value = '';
  try {
    const { data } = await OwnerFinanceAPI.getDashboard({
      year: selectedYear.value,
      month: selectedMonth.value,
    });
    dashboard.value = data;
    (data.needs_review_transactions || []).forEach(tx => {
      if (!reviewDraftCategories[tx.id]) {
        reviewDraftCategories[tx.id] =
          tx.category && tx.category !== 'unclassified_card'
            ? tx.category
            : 'office_and_ops';
      }
    });
  } catch (error) {
    loadError.value = extractErrorMessage(error);
  } finally {
    isLoading.value = false;
  }
};

const onPeriodChange = () => {
  fetchDashboard();
};

const selectMonthFromTable = monthNum => {
  selectedMonth.value = monthNum;
  fetchDashboard();
};

const closeModal = () => {
  activeModal.value = '';
};

const onKeydown = event => {
  if (event.key === 'Escape' && activeModal.value) {
    closeModal();
  }
};

onMounted(() => {
  window.addEventListener('keydown', onKeydown);
  fetchDashboard();
});

onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown);
});

// Statement Upload
const triggerFileUpload = () => {
  fileInputRef.value?.click();
};

const onStatementFileSelected = async event => {
  const file = event.target?.files?.[0];
  if (!file) return;

  isUploading.value = true;
  try {
    const { data } = await OwnerFinanceAPI.importStatement(file, {
      accountRecordId: uploadAccountId.value || null,
    });
    lastImportSummary.value = data;
    activeTab.value = 'transactions';
    useAlert(
      `Импортировано: бизнес ${data.imported_business}, на разбор ${data.queued_for_review}, скрыто личных ${data.auto_hidden_personal}`
    );
    await fetchDashboard();
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isUploading.value = false;
    if (fileInputRef.value) {
      fileInputRef.value.value = '';
    }
  }
};

const formatImportSummary = summary => {
  if (!summary) return '';
  return `${summary.filename}: разобрано ${summary.total_parsed} · в бизнес P&L ${summary.imported_business} · на проверку ${summary.queued_for_review} · скрыто личных ${summary.auto_hidden_personal} · дубликатов ${summary.skipped_duplicates}`;
};

// Deadlines CRUD
const todayIso = () =>
  dashboard.value?.period?.reference_date ||
  new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Almaty' }).format(
    new Date()
  );

const confirmDeleteAction = label =>
  // eslint-disable-next-line no-alert
  typeof window === 'undefined' ? true : window.confirm(`Удалить: ${label}?`);

const openNewDeadline = () => {
  Object.assign(deadlineForm, {
    id: null,
    title: '',
    category: 'hosting',
    payer_mode: 'us',
    provider: '',
    related_domain: '',
    client_name: '',
    due_on: todayIso(),
    amount: 0,
    currency: 'KZT',
    recurrence: 'yearly',
    remind_days_text: '7, 3, 2, 1, 0',
    notes: '',
  });
  activeModal.value = 'deadline';
};

const openEditDeadline = dl => {
  Object.assign(deadlineForm, {
    id: dl.id,
    title: dl.title || '',
    category: dl.category || 'hosting',
    payer_mode: dl.payer_mode || 'us',
    provider: dl.provider || '',
    related_domain: dl.related_domain || '',
    client_name: dl.client_name || '',
    due_on: dl.due_on || todayIso(),
    amount: dl.amount ?? 0,
    currency: dl.currency || 'KZT',
    recurrence: dl.recurrence || 'yearly',
    remind_days_text: (dl.remind_days || [7, 3, 2, 1, 0]).join(', '),
    notes: dl.notes || '',
  });
  activeModal.value = 'deadline';
};

const saveDeadline = async () => {
  isSaving.value = true;
  try {
    const remindDays = String(deadlineForm.remind_days_text || '7,3,2,1,0')
      .split(/[,\s]+/)
      .map(v => Number.parseInt(v, 10))
      .filter(n => !Number.isNaN(n) && n >= 0 && n <= 90);

    const payload = {
      title: deadlineForm.title,
      category: deadlineForm.category,
      payer_mode: deadlineForm.payer_mode,
      provider: deadlineForm.provider,
      related_domain: deadlineForm.related_domain,
      client_name: deadlineForm.client_name,
      due_on: deadlineForm.due_on,
      amount: Number(deadlineForm.amount || 0),
      currency: deadlineForm.currency,
      recurrence: deadlineForm.recurrence,
      remind_days: remindDays.length ? remindDays : [7, 3, 2, 1, 0],
      notes: deadlineForm.notes,
    };

    if (deadlineForm.id) {
      await OwnerFinanceAPI.updateDeadline(deadlineForm.id, payload);
    } else {
      await OwnerFinanceAPI.createDeadline(payload);
    }
    closeModal();
    await fetchDashboard();
    useAlert('Срок сохранён');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isSaving.value = false;
  }
};

const completeDeadlineItem = async dl => {
  try {
    await OwnerFinanceAPI.completeDeadline(dl.id);
    await fetchDashboard();
    useAlert(
      dl.recurrence === 'once'
        ? 'Срок закрыт'
        : 'Срок продлён на следующий период'
    );
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

const removeDeadlineItem = async dl => {
  if (!confirmDeleteAction(dl.title)) return;
  try {
    await OwnerFinanceAPI.deleteDeadline(dl.id);
    await fetchDashboard();
    useAlert('Срок удалён');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

const triggerDeadlineReminders = async () => {
  isRunningReminders.value = true;
  try {
    const { data } = await OwnerFinanceAPI.runDeadlineReminders();
    useAlert(
      `Проверено: создано напоминаний в Задачах — ${data.reminded_count}`
    );
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isRunningReminders.value = false;
  }
};

// Accounts CRUD
const openNewAccount = () => {
  Object.assign(accountForm, {
    id: null,
    name: '',
    account_kind: 'business_bank',
    scope: 'business',
    bank_code: '',
    currency: 'KZT',
    current_balance: 0,
    notes: '',
  });
  activeModal.value = 'account';
};

const openEditAccount = acc => {
  Object.assign(accountForm, {
    id: acc.id,
    name: acc.name || '',
    account_kind: acc.account_kind || 'business_bank',
    scope: acc.scope || 'business',
    bank_code: acc.bank_code || '',
    currency: acc.currency || 'KZT',
    current_balance: acc.current_balance ?? 0,
    notes: acc.notes || '',
  });
  activeModal.value = 'account';
};

const onAccountKindChange = () => {
  if (accountForm.account_kind === 'personal_card_filter') {
    accountForm.scope = 'personal';
  } else {
    accountForm.scope = 'business';
  }
};

const saveAccount = async () => {
  isSaving.value = true;
  try {
    const payload = {
      name: accountForm.name,
      account_kind: accountForm.account_kind,
      scope: accountForm.scope,
      bank_code: accountForm.bank_code,
      currency: accountForm.currency,
      current_balance: Number(accountForm.current_balance || 0),
      notes: accountForm.notes,
    };
    if (accountForm.id) {
      await OwnerFinanceAPI.updateAccount(accountForm.id, payload);
    } else {
      await OwnerFinanceAPI.createAccount(payload);
    }
    closeModal();
    await fetchDashboard();
    useAlert('Счёт обновлён');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isSaving.value = false;
  }
};

// Transactions & Personal Hide
const openNewTransaction = () => {
  Object.assign(txForm, {
    id: null,
    occurred_on: todayIso(),
    direction: 'expense',
    pnl_treatment: 'pnl',
    official_status: 'management',
    amount: 0,
    currency: 'KZT',
    category: 'servers_and_cloud',
    merchant: '',
    description: '',
    account_record_id: businessAccounts.value[0]?.id || '',
    learn_vendor: true,
  });
  activeModal.value = 'transaction';
};

const openEditTransaction = tx => {
  Object.assign(txForm, {
    id: tx.id,
    occurred_on: tx.occurred_on || todayIso(),
    direction: tx.direction || 'expense',
    pnl_treatment: tx.pnl_treatment || 'pnl',
    official_status: tx.official_status || 'management',
    amount: tx.amount ?? 0,
    currency: tx.currency || 'KZT',
    category: tx.category || 'office_and_ops',
    merchant: tx.merchant || '',
    description: tx.description || '',
    account_record_id: tx.account_record_id || '',
    learn_vendor: true,
  });
  activeModal.value = 'transaction';
};

const saveTransaction = async () => {
  isSaving.value = true;
  try {
    const payload = {
      occurred_on: txForm.occurred_on,
      direction: txForm.direction,
      pnl_treatment:
        txForm.direction === 'transfer' ? 'non_pnl' : txForm.pnl_treatment,
      official_status: txForm.official_status,
      review_status: 'confirmed',
      amount: Number(txForm.amount || 0),
      currency: txForm.currency,
      category: txForm.category,
      merchant: txForm.merchant,
      description: txForm.description,
      account_record_id: txForm.account_record_id || null,
    };
    if (txForm.id) {
      await OwnerFinanceAPI.updateTransaction(txForm.id, payload, {
        learnVendor: Boolean(txForm.learn_vendor),
      });
    } else {
      await OwnerFinanceAPI.createTransaction(payload, {
        learnVendor: Boolean(txForm.learn_vendor),
      });
    }
    closeModal();
    await fetchDashboard();
    useAlert('Операция сохранена');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isSaving.value = false;
  }
};

const confirmReviewAsBusiness = async tx => {
  const chosenCategory = reviewDraftCategories[tx.id] || 'office_and_ops';
  try {
    await OwnerFinanceAPI.updateTransaction(
      tx.id,
      {
        review_status: 'confirmed',
        ...(chosenCategory === 'accountable_transfer'
          ? { direction: 'transfer' }
          : {}),
        pnl_treatment:
          chosenCategory === 'accountable_transfer' ? 'non_pnl' : 'pnl',
        category: chosenCategory,
      },
      { learnVendor: true }
    );
    await fetchDashboard();
    useAlert('Отмечено как бизнес (контрагент запомнен)');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

const hideAsPersonal = async (tx, hideMerchantAlways = false) => {
  try {
    const { data } = await OwnerFinanceAPI.hidePersonalTransaction(tx.id, {
      hideMerchantAlways,
    });
    await fetchDashboard();
    useAlert(
      hideMerchantAlways
        ? `Магазин скрыт навсегда (удалено строк: ${data.hidden_count})`
        : 'Личная операция удалена (сохранён SHA-256 отпечаток)'
    );
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

const removeTransactionItem = async tx => {
  if (!confirmDeleteAction(tx.merchant)) return;
  try {
    await OwnerFinanceAPI.deleteTransaction(tx.id);
    await fetchDashboard();
    useAlert('Операция удалена');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

// Contracts CRUD
const openNewContract = () => {
  Object.assign(contractForm, {
    id: null,
    client_name: '',
    contract_number: '',
    title: 'Подписка OneLink',
    status: 'active',
    tariff_code: 'ai_agent_rop_199k',
    monthly_amount: 199000,
    one_time_amount: 0,
    currency: 'KZT',
    billing_day: 5,
    starts_on: todayIso(),
    ends_on: '',
    onelink_account_id: '',
    medelement_commission_enabled: false,
    notes: '',
  });
  activeModal.value = 'contract';
};

const openEditContract = contract => {
  Object.assign(contractForm, {
    id: contract.id,
    client_name: contract.client_name || '',
    contract_number: contract.contract_number || '',
    title: contract.title || '',
    status: contract.status || 'active',
    tariff_code: contract.tariff_code || 'custom',
    monthly_amount: contract.monthly_amount ?? 0,
    one_time_amount: contract.one_time_amount ?? 0,
    currency: contract.currency || 'KZT',
    billing_day: contract.billing_day || 5,
    starts_on: contract.starts_on || '',
    ends_on: contract.ends_on || '',
    onelink_account_id: contract.onelink_account_id || '',
    medelement_commission_enabled: Boolean(
      contract.medelement_commission_enabled
    ),
    medelement_commission_rate: contract.medelement_commission_rate || 0.3,
    notes: contract.notes || '',
  });
  activeModal.value = 'contract';
};

const onContractTariffChange = () => {
  if (contractForm.tariff_code === 'text_voice_99k') {
    contractForm.monthly_amount = 99000;
  } else if (contractForm.tariff_code === 'ai_agent_rop_199k') {
    contractForm.monthly_amount = 199000;
  } else if (contractForm.tariff_code === 'voice_ai_399k') {
    contractForm.monthly_amount = 399000;
  }
};

const saveContract = async () => {
  isSaving.value = true;
  try {
    const payload = {
      client_name: contractForm.client_name,
      contract_number: contractForm.contract_number,
      title: contractForm.title,
      status: contractForm.status,
      tariff_code: contractForm.tariff_code,
      monthly_amount: Number(contractForm.monthly_amount || 0),
      one_time_amount: Number(contractForm.one_time_amount || 0),
      currency: contractForm.currency,
      billing_day: contractForm.billing_day
        ? Number(contractForm.billing_day)
        : null,
      starts_on: contractForm.starts_on || null,
      ends_on: contractForm.ends_on || null,
      onelink_account_id: contractForm.onelink_account_id
        ? Number(contractForm.onelink_account_id)
        : null,
      medelement_commission_enabled: Boolean(
        contractForm.medelement_commission_enabled
      ),
      medelement_commission_rate: Number(
        contractForm.medelement_commission_rate || 0.3
      ),
      notes: contractForm.notes,
    };
    if (contractForm.id) {
      await OwnerFinanceAPI.updateContract(contractForm.id, payload);
    } else {
      await OwnerFinanceAPI.createContract(payload);
    }
    closeModal();
    await fetchDashboard();
    useAlert('Договор сохранён');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isSaving.value = false;
  }
};

const removeContractItem = async contract => {
  if (!confirmDeleteAction(contract.client_name)) return;
  try {
    await OwnerFinanceAPI.deleteContract(contract.id);
    await fetchDashboard();
    useAlert('Договор удалён');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

// Obligations CRUD & 1C Sync
const openNewObligation = () => {
  Object.assign(obligationForm, {
    id: null,
    entry_kind: 'medelement_commission',
    title: '',
    counterparty_name: 'МИС МедЭлемент',
    period_label: `${selectedYear.value}-${String(selectedMonth.value || 1).padStart(2, '0')}`,
    base_amount: 0,
    overage_excluded_amount: 0,
    amount: 0,
    paid_amount: 0,
    currency: 'KZT',
    due_on: todayIso(),
    status: 'open',
    notes: '',
  });
  activeModal.value = 'obligation';
};

const openEditObligation = ob => {
  Object.assign(obligationForm, {
    id: ob.id,
    entry_kind: ob.entry_kind || 'payable_debt',
    title: ob.title || '',
    counterparty_name: ob.counterparty_name || '',
    period_label: ob.period_label || '',
    base_amount: ob.base_amount ?? 0,
    overage_excluded_amount: ob.overage_excluded_amount ?? 0,
    amount: ob.amount ?? 0,
    paid_amount: ob.paid_amount ?? 0,
    currency: ob.currency || 'KZT',
    due_on: ob.due_on || '',
    status: ob.status || 'open',
    notes: ob.notes || '',
  });
  activeModal.value = 'obligation';
};

const onObligationBaseChange = () => {
  if (obligationForm.entry_kind === 'medelement_commission') {
    obligationForm.amount = Number(
      (Number(obligationForm.base_amount || 0) * 0.3).toFixed(2)
    );
  }
};

const saveObligation = async () => {
  isSaving.value = true;
  try {
    const payload = {
      entry_kind: obligationForm.entry_kind,
      title: obligationForm.title,
      counterparty_name: obligationForm.counterparty_name,
      period_label: obligationForm.period_label,
      base_amount: Number(obligationForm.base_amount || 0),
      overage_excluded_amount: Number(
        obligationForm.overage_excluded_amount || 0
      ),
      amount: Number(obligationForm.amount || 0),
      paid_amount: Number(obligationForm.paid_amount || 0),
      currency: obligationForm.currency,
      due_on: obligationForm.due_on || null,
      status: obligationForm.status,
      notes: obligationForm.notes,
    };
    if (obligationForm.id) {
      await OwnerFinanceAPI.updateObligation(obligationForm.id, payload);
    } else {
      await OwnerFinanceAPI.createObligation(payload);
    }
    closeModal();
    await fetchDashboard();
    useAlert('Обязательство сохранено');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isSaving.value = false;
  }
};

const markObligationPaid = async ob => {
  try {
    await OwnerFinanceAPI.updateObligation(ob.id, {
      status: 'paid',
      paid_amount: ob.amount,
      paid_on: todayIso(),
    });
    await fetchDashboard();
    useAlert('Отмечено оплаченным');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

const removeObligationItem = async ob => {
  if (!confirmDeleteAction(ob.title)) return;
  try {
    await OwnerFinanceAPI.deleteObligation(ob.id);
    await fetchDashboard();
    useAlert('Обязательство удалено');
  } catch (error) {
    useAlert(extractErrorMessage(error));
  }
};

const runOnecSync = async () => {
  isSyncingOnec.value = true;
  try {
    const { data } = await OwnerFinanceAPI.syncOnecFresh({ daysBack: 45 });
    await fetchDashboard();
    if (data.status === 'not_configured') {
      useAlert(data.message || '1С:Фреш не настроен на этом сервере');
    } else {
      useAlert(
        `1С:Фреш синхронизирован: обновлено операций — ${data.transactions_upserted || 0}`
      );
    }
  } catch (error) {
    useAlert(extractErrorMessage(error));
  } finally {
    isSyncingOnec.value = false;
  }
};
</script>

<template>
  <section
    data-test="owner-finance-page"
    class="flex flex-col flex-1 min-h-0 overflow-y-auto bg-n-surface-1 text-n-slate-12"
  >
    <!-- Hidden file input for statement uploads -->
    <input
      ref="fileInputRef"
      type="file"
      accept=".pdf,.txt,.csv"
      class="hidden"
      @change="onStatementFileSelected"
    />

    <!-- Top Header -->
    <header class="border-b border-n-weak bg-n-solid-2 px-4 sm:px-6 py-3.5">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2.5">
          <h1 class="text-lg font-semibold tracking-tight text-n-slate-12">
            {{ UI.TITLE }}
          </h1>
          <span
            class="inline-flex items-center rounded-md border border-n-weak bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
          >
            {{ UI.OWNER_BADGE }}
          </span>
          <span class="hidden sm:inline text-xs text-n-slate-10">
            {{ UI.LOCAL_DB_NOTE }}
          </span>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <select
            v-model.number="selectedMonth"
            data-test="owner-finance-month-select"
            class="!mb-0 !h-8 rounded-lg border border-n-weak bg-n-surface-1 py-0 pl-2.5 pr-7 text-xs font-medium text-n-slate-12"
            @change="onPeriodChange"
          >
            <option v-for="m in MONTH_OPTIONS" :key="m.value" :value="m.value">
              {{ m.label }}
            </option>
          </select>

          <select
            v-model.number="selectedYear"
            data-test="owner-finance-year-select"
            class="!mb-0 !h-8 rounded-lg border border-n-weak bg-n-surface-1 py-0 pl-2.5 pr-7 text-xs font-medium text-n-slate-12 tabular-nums"
            @change="onPeriodChange"
          >
            <option v-for="yr in yearOptions" :key="yr" :value="yr">
              {{ yr }}
            </option>
          </select>

          <Button
            size="sm"
            variant="faded"
            color="slate"
            icon="i-lucide-upload"
            :label="isUploading ? UI.UPLOADING : UI.UPLOAD_STATEMENT"
            :is-loading="isUploading"
            @click="triggerFileUpload"
          />

          <Button
            size="sm"
            icon="i-lucide-plus"
            :label="UI.ADD_DEADLINE"
            @click="openNewDeadline"
          />
        </div>
      </div>

      <!-- Navigation Tabs -->
      <nav
        class="mt-3.5 -mb-3.5 flex items-center gap-5 overflow-x-auto border-t border-n-weak pt-2.5"
      >
        <button
          type="button"
          data-test="tab-overview"
          class="pb-2.5 text-sm font-medium whitespace-nowrap border-b-2 transition-colors"
          :class="
            activeTab === 'overview'
              ? 'border-n-brand text-n-slate-12'
              : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
          "
          @click="activeTab = 'overview'"
        >
          {{ UI.TABS.OVERVIEW }}
        </button>

        <button
          type="button"
          data-test="tab-deadlines"
          class="inline-flex items-center gap-1.5 pb-2.5 text-sm font-medium whitespace-nowrap border-b-2 transition-colors"
          :class="
            activeTab === 'deadlines'
              ? 'border-n-brand text-n-slate-12'
              : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
          "
          @click="activeTab = 'deadlines'"
        >
          <span>{{ UI.TABS.DEADLINES }}</span>
          <span
            v-if="kpis.urgent_deadlines_count > 0"
            class="rounded-full px-1.5 py-0.5 text-[11px] font-semibold tabular-nums bg-n-ruby-3 text-n-ruby-11"
          >
            {{ kpis.urgent_deadlines_count }}
          </span>
        </button>

        <button
          type="button"
          data-test="tab-transactions"
          class="inline-flex items-center gap-1.5 pb-2.5 text-sm font-medium whitespace-nowrap border-b-2 transition-colors"
          :class="
            activeTab === 'transactions'
              ? 'border-n-brand text-n-slate-12'
              : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
          "
          @click="activeTab = 'transactions'"
        >
          <span>{{ UI.TABS.TRANSACTIONS }}</span>
          <span
            v-if="kpis.needs_review_count > 0"
            class="rounded-full px-1.5 py-0.5 text-[11px] font-semibold tabular-nums bg-n-amber-3 text-n-amber-11"
          >
            {{ kpis.needs_review_count }}
          </span>
        </button>

        <button
          type="button"
          data-test="tab-contracts"
          class="pb-2.5 text-sm font-medium whitespace-nowrap border-b-2 transition-colors"
          :class="
            activeTab === 'contracts'
              ? 'border-n-brand text-n-slate-12'
              : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
          "
          @click="activeTab = 'contracts'"
        >
          {{ UI.TABS.CONTRACTS }}
        </button>
      </nav>
    </header>

    <!-- Loading & Error States -->
    <div
      v-if="isLoading && !dashboard"
      class="flex flex-1 items-center justify-center gap-2.5 py-16 text-sm text-n-slate-11"
    >
      <Spinner />
      <span>{{ UI.LOADING }}</span>
    </div>

    <div
      v-else-if="loadError && !dashboard"
      class="mx-auto my-12 max-w-md rounded-xl border border-n-weak bg-n-solid-2 p-6 text-center"
    >
      <p class="text-sm font-medium text-n-slate-12">
        {{ UI.ERROR_TITLE }}
      </p>
      <p class="mt-1 text-xs text-n-slate-11">
        {{ loadError }}
      </p>
      <div class="mt-4 flex justify-center">
        <Button size="sm" :label="UI.RETRY" @click="fetchDashboard" />
      </div>
    </div>

    <!-- Main Content -->
    <div
      v-else-if="dashboard"
      class="mx-auto w-full max-w-[1440px] px-4 sm:px-6 py-5 space-y-5"
    >
      <!-- Divided KPI Strip (anti-slop house rule: 1px borders, lead figure larger, tabular-nums, no icons/sparklines) -->
      <div
        data-test="owner-finance-kpi-strip"
        class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 rounded-xl border border-n-weak bg-n-solid-2 divide-y sm:divide-y-0 sm:divide-x divide-n-weak"
      >
        <div class="p-4">
          <div class="text-xs font-medium text-n-slate-11">
            {{ UI.KPI.FREE_CASH }}
          </div>
          <div
            class="mt-1 text-2xl font-semibold tracking-tight tabular-nums"
            :class="
              Number(kpis.free_cash_kzt || 0) < 0
                ? 'text-n-ruby-11'
                : 'text-n-slate-12'
            "
          >
            {{ formatKzt(kpis.free_cash_kzt) }}
          </div>
          <div
            class="mt-1.5 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-n-slate-10 tabular-nums"
          >
            <span>
              {{ UI.KPI.ON_ACCOUNTS }}
              <strong class="font-medium text-n-slate-11">
                {{ formatKzt(kpis.total_balance_kzt) }}
              </strong>
            </span>
            <span>
              {{ UI.KPI.COMMITTED_30D }}
              <strong class="font-medium text-n-slate-11">
                {{ formatKzt(kpis.committed_outflow_30d_kzt) }}
              </strong>
            </span>
          </div>
        </div>

        <div class="p-4">
          <div class="text-xs font-medium text-n-slate-11">
            {{ UI.KPI.EXPECTED_30D }}
          </div>
          <div
            class="mt-1 text-xl font-semibold tracking-tight text-n-slate-12 tabular-nums"
          >
            {{ formatKzt(kpis.expected_inflow_30d_kzt) }}
          </div>
          <div
            class="mt-1.5 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-n-slate-10 tabular-nums"
          >
            <span>
              {{ UI.KPI.CONTRACTS_MRR }}
              <strong class="font-medium text-n-teal-11">
                {{ formatKzt(kpis.live_contracts_mrr_kzt) }}
              </strong>
            </span>
            <span v-if="kpis.rebill_soon_count > 0">
              {{ UI.KPI.REBILL_CLIENTS }}
              <strong class="font-medium text-n-amber-11">
                {{ formatKzt(kpis.rebill_soon_kzt) }}
              </strong>
            </span>
          </div>
        </div>

        <div class="p-4">
          <div class="text-xs font-medium text-n-slate-11">
            {{ UI.KPI.PERIOD_PROFIT }}
          </div>
          <div
            class="mt-1 text-xl font-semibold tracking-tight tabular-nums"
            :class="
              Number(kpis.month_net_profit_kzt || 0) >= 0
                ? 'text-n-teal-11'
                : 'text-n-ruby-11'
            "
          >
            {{ formatKzt(kpis.month_net_profit_kzt) }}
          </div>
          <div
            class="mt-1.5 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-n-slate-10 tabular-nums"
          >
            <span>
              {{ UI.KPI.REVENUE }}
              <strong class="font-medium text-n-slate-11">
                {{ formatKzt(kpis.month_revenue_kzt) }}
              </strong>
            </span>
            <span>
              {{ UI.KPI.EXPENSES }}
              <strong class="font-medium text-n-slate-11">
                {{ formatKzt(kpis.month_expenses_kzt) }}
              </strong>
            </span>
          </div>
        </div>

        <div class="p-4">
          <div class="text-xs font-medium text-n-slate-11">
            {{ UI.KPI.RADAR_AND_CARDS }}
          </div>
          <div class="mt-1 flex items-baseline gap-3 tabular-nums">
            <button
              type="button"
              class="text-left hover:underline"
              @click="activeTab = 'deadlines'"
            >
              <span class="text-xs text-n-slate-10">
                {{ UI.KPI.URGENT_DEADLINES }}
              </span>
              <strong
                class="ml-1 text-lg font-semibold"
                :class="
                  kpis.urgent_deadlines_count > 0
                    ? 'text-n-ruby-11'
                    : 'text-n-slate-12'
                "
              >
                {{ kpis.urgent_deadlines_count || 0 }}
              </strong>
            </button>
            <button
              type="button"
              class="text-left hover:underline"
              @click="activeTab = 'transactions'"
            >
              <span class="text-xs text-n-slate-10">
                {{ UI.KPI.NEEDS_REVIEW }}
              </span>
              <strong
                class="ml-1 text-lg font-semibold"
                :class="
                  kpis.needs_review_count > 0
                    ? 'text-n-amber-11'
                    : 'text-n-slate-12'
                "
              >
                {{ kpis.needs_review_count || 0 }}
              </strong>
            </button>
          </div>
          <div class="mt-1.5 text-xs text-n-slate-10">
            {{ UI.DEADLINES.REMIND_HINT }}
          </div>
        </div>
      </div>

      <!-- TAB 1: OVERVIEW -->
      <div v-if="activeTab === 'overview'" class="space-y-5">
        <div
          v-if="kpis.needs_review_count > 0"
          class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-2 px-4 py-3"
        >
          <div class="text-sm text-n-slate-12">
            <span>{{ UI.OVERVIEW.REVIEW_BANNER_PREFIX }}</span>
            <strong class="ml-1 font-semibold text-n-amber-11 tabular-nums">
              {{ kpis.needs_review_count }}
            </strong>
          </div>
          <Button
            size="sm"
            variant="faded"
            color="amber"
            :label="UI.OVERVIEW.REVIEW_BANNER_ACTION"
            @click="activeTab = 'transactions'"
          />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-12 gap-5">
          <!-- Left: Upcoming Deadlines 30d -->
          <div class="lg:col-span-7 space-y-5">
            <div class="rounded-xl border border-n-weak bg-n-solid-2">
              <div
                class="flex items-center justify-between gap-2 border-b border-n-weak px-4 py-3"
              >
                <h2 class="text-sm font-semibold text-n-slate-12">
                  {{ UI.OVERVIEW.UPCOMING_TITLE }}
                </h2>
                <button
                  type="button"
                  class="text-xs font-medium text-n-brand hover:underline"
                  @click="activeTab = 'deadlines'"
                >
                  {{ UI.OVERVIEW.ALL_DEADLINES_LINK }}
                </button>
              </div>

              <div
                v-if="!upcomingDeadlines30d.length"
                class="px-4 py-8 text-center text-sm text-n-slate-10"
              >
                {{ UI.OVERVIEW.NO_UPCOMING }}
              </div>

              <div v-else class="divide-y divide-n-weak">
                <div
                  v-for="dl in upcomingDeadlines30d"
                  :key="dl.id"
                  class="flex flex-col sm:flex-row sm:items-center justify-between gap-2.5 px-4 py-3"
                >
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-1.5">
                      <span
                        class="inline-flex items-center rounded px-1.5 py-0.5 text-[11px] font-medium tabular-nums"
                        :class="deadlineDaysBadge(dl).classes"
                      >
                        {{ deadlineDaysBadge(dl).text }}
                      </span>
                      <span
                        class="rounded bg-n-alpha-2 px-1.5 py-0.5 text-[11px] text-n-slate-11"
                      >
                        {{
                          DEADLINE_CATEGORY_LABELS[dl.category] || dl.category
                        }}
                      </span>
                      <span
                        v-if="dl.payer_mode === 'rebill_client'"
                        class="rounded bg-n-amber-3 px-1.5 py-0.5 text-[11px] font-medium text-n-amber-11"
                      >
                        {{ UI.DEADLINES.REBILL_TAG }}
                      </span>
                    </div>
                    <div
                      class="mt-1 truncate text-sm font-medium text-n-slate-12"
                    >
                      {{ dl.title }}
                    </div>
                    <div
                      class="mt-0.5 flex flex-wrap gap-x-2.5 text-xs text-n-slate-10"
                    >
                      <span class="tabular-nums">{{
                        formatDateRu(dl.due_on)
                      }}</span>
                      <span v-if="dl.related_domain">{{
                        dl.related_domain
                      }}</span>
                      <span v-if="dl.client_name">{{ dl.client_name }}</span>
                      <span v-if="dl.provider">{{ dl.provider }}</span>
                    </div>
                  </div>

                  <div
                    class="flex items-center justify-between sm:justify-end gap-3"
                  >
                    <div class="text-right tabular-nums">
                      <div class="text-sm font-semibold text-n-slate-12">
                        {{
                          dl.amount > 0
                            ? formatMoney(dl.amount, dl.currency)
                            : '—'
                        }}
                      </div>
                      <div class="text-[11px] text-n-slate-10">
                        {{ RECURRENCE_SHORT[dl.recurrence] || dl.recurrence }}
                      </div>
                    </div>
                    <div class="flex items-center gap-1">
                      <Button
                        size="xs"
                        variant="faded"
                        color="slate"
                        :label="UI.OVERVIEW.COMPLETE_BTN"
                        @click="completeDeadlineItem(dl)"
                      />
                      <Button
                        size="xs"
                        variant="ghost"
                        color="slate"
                        icon="i-lucide-pencil"
                        @click="openEditDeadline(dl)"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <!-- 12-Month P&L Table -->
            <div class="rounded-xl border border-n-weak bg-n-solid-2">
              <div class="border-b border-n-weak px-4 py-3">
                <h2 class="text-sm font-semibold text-n-slate-12">
                  {{ UI.OVERVIEW.YEAR_PNL_TITLE }}
                </h2>
              </div>
              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs">
                  <thead>
                    <tr class="border-b border-n-weak text-n-slate-10">
                      <th class="px-4 py-2 font-medium">
                        {{ UI.OVERVIEW.COL_MONTH }}
                      </th>
                      <th class="px-4 py-2 text-right font-medium">
                        {{ UI.OVERVIEW.COL_REV }}
                      </th>
                      <th class="px-4 py-2 text-right font-medium">
                        {{ UI.OVERVIEW.COL_EXP }}
                      </th>
                      <th class="px-4 py-2 text-right font-medium">
                        {{ UI.OVERVIEW.COL_NET }}
                      </th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-n-weak tabular-nums">
                    <tr
                      v-for="row in monthlySeries"
                      :key="row.month"
                      class="cursor-pointer transition-colors hover:bg-n-alpha-1"
                      :class="
                        selectedMonth === row.month
                          ? 'bg-n-alpha-2 font-medium'
                          : ''
                      "
                      @click="selectMonthFromTable(row.month)"
                    >
                      <td class="px-4 py-2 text-n-slate-12">
                        {{ monthShortName(row.month) }}
                      </td>
                      <td class="px-4 py-2 text-right text-n-slate-12">
                        {{ formatKzt(row.revenue_kzt) }}
                      </td>
                      <td class="px-4 py-2 text-right text-n-slate-11">
                        {{ formatKzt(row.expenses_kzt) }}
                      </td>
                      <td
                        class="px-4 py-2 text-right font-medium"
                        :class="
                          row.net_profit_kzt >= 0
                            ? 'text-n-teal-11'
                            : 'text-n-ruby-11'
                        "
                      >
                        {{ formatKzt(row.net_profit_kzt) }}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <!-- Right: Business Accounts & Expense Breakdown -->
          <div class="lg:col-span-5 space-y-5">
            <div class="rounded-xl border border-n-weak bg-n-solid-2">
              <div
                class="flex items-center justify-between gap-2 border-b border-n-weak px-4 py-3"
              >
                <h2 class="text-sm font-semibold text-n-slate-12">
                  {{ UI.OVERVIEW.ACCOUNTS_TITLE }}
                </h2>
                <Button
                  size="xs"
                  variant="faded"
                  color="slate"
                  icon="i-lucide-plus"
                  :label="UI.ADD_ACCOUNT"
                  @click="openNewAccount"
                />
              </div>

              <div
                v-if="!accounts.length"
                class="px-4 py-6 text-center text-sm text-n-slate-10"
              >
                {{ UI.OVERVIEW.NO_ACCOUNTS }}
              </div>

              <div v-else class="divide-y divide-n-weak">
                <div v-if="businessAccounts.length" class="p-4 space-y-2.5">
                  <div
                    class="text-[11px] font-medium uppercase tracking-wide text-n-slate-10"
                  >
                    {{ UI.OVERVIEW.BUSINESS_ACCOUNTS_SUB }}
                  </div>
                  <div
                    v-for="acc in businessAccounts"
                    :key="acc.id"
                    class="flex items-center justify-between gap-2 text-sm"
                  >
                    <div class="min-w-0">
                      <div class="truncate font-medium text-n-slate-12">
                        {{ acc.name }}
                      </div>
                      <div class="text-xs text-n-slate-10">
                        {{ acc.currency }}
                      </div>
                    </div>
                    <div class="flex items-center gap-2">
                      <div class="text-right tabular-nums">
                        <div class="font-semibold text-n-slate-12">
                          {{ formatMoney(acc.current_balance, acc.currency) }}
                        </div>
                        <div
                          v-if="acc.currency !== 'KZT'"
                          class="text-[11px] text-n-slate-10"
                        >
                          {{ formatKzt(acc.balance_kzt) }}
                        </div>
                      </div>
                      <Button
                        size="xs"
                        variant="ghost"
                        color="slate"
                        icon="i-lucide-pencil"
                        @click="openEditAccount(acc)"
                      />
                    </div>
                  </div>
                </div>

                <div v-if="personalFilterAccounts.length" class="p-4 space-y-2">
                  <div class="text-[11px] font-medium text-n-slate-10">
                    {{ UI.OVERVIEW.PERSONAL_CARDS_SUB }}
                  </div>
                  <div
                    v-for="acc in personalFilterAccounts"
                    :key="acc.id"
                    class="flex items-center justify-between gap-2 text-xs text-n-slate-11"
                  >
                    <span class="truncate">{{ acc.name }}</span>
                    <Button
                      size="xs"
                      variant="ghost"
                      color="slate"
                      icon="i-lucide-pencil"
                      @click="openEditAccount(acc)"
                    />
                  </div>
                </div>
              </div>
            </div>

            <!-- Expense Breakdown -->
            <div class="rounded-xl border border-n-weak bg-n-solid-2">
              <div class="border-b border-n-weak px-4 py-3">
                <h2 class="text-sm font-semibold text-n-slate-12">
                  {{ UI.OVERVIEW.EXPENSE_STRUCTURE_TITLE }}
                </h2>
              </div>

              <div
                v-if="!expenseBreakdown.length"
                class="px-4 py-6 text-center text-sm text-n-slate-10"
              >
                {{ UI.OVERVIEW.NO_EXPENSES }}
              </div>

              <div v-else class="p-4 space-y-3">
                <div
                  v-for="item in expenseBreakdown"
                  :key="item.category"
                  class="space-y-1"
                >
                  <div class="flex items-center justify-between gap-2 text-xs">
                    <span class="truncate text-n-slate-12">{{
                      item.label
                    }}</span>
                    <span
                      class="shrink-0 font-medium text-n-slate-12 tabular-nums"
                    >
                      {{ formatKzt(item.amount_kzt) }}
                      <span class="ml-1 text-n-slate-10">
                        {{
                          totalExpensesBreakdownKzt > 0
                            ? `${Math.round((item.amount_kzt / totalExpensesBreakdownKzt) * 100)}%`
                            : '0%'
                        }}
                      </span>
                    </span>
                  </div>
                  <progress
                    class="block h-1.5 w-full overflow-hidden rounded bg-n-alpha-2 accent-n-brand"
                    :value="item.amount_kzt"
                    :max="maxExpenseCategoryKzt"
                  />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- TAB 2: DEADLINES RADAR -->
      <div v-else-if="activeTab === 'deadlines'" class="space-y-4">
        <div class="rounded-xl border border-n-weak bg-n-solid-2 p-4 space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="flex flex-wrap items-center gap-1.5">
              <button
                v-for="chip in DEADLINE_CATEGORY_FILTERS"
                :key="chip.code"
                type="button"
                class="rounded-lg border px-2.5 py-1 text-xs font-medium transition-colors"
                :class="
                  deadlineCategoryFilter === chip.code
                    ? 'border-n-brand bg-n-alpha-2 text-n-slate-12'
                    : 'border-n-weak bg-n-surface-1 text-n-slate-11 hover:text-n-slate-12'
                "
                @click="deadlineCategoryFilter = chip.code"
              >
                {{ chip.label }}
              </button>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <Button
                size="xs"
                variant="faded"
                color="slate"
                icon="i-lucide-bell"
                :label="UI.DEADLINES.RUN_REMINDERS_BTN"
                :is-loading="isRunningReminders"
                @click="triggerDeadlineReminders"
              />
              <Button
                size="xs"
                icon="i-lucide-plus"
                :label="UI.ADD_DEADLINE"
                @click="openNewDeadline"
              />
            </div>
          </div>

          <div class="flex flex-wrap items-center justify-between gap-3">
            <input
              v-model="deadlineSearch"
              type="search"
              :placeholder="UI.DEADLINES.SEARCH_PLACEHOLDER"
              class="!mb-0 !h-8 w-full sm:w-80 rounded-lg border border-n-weak bg-n-surface-1 px-3 text-xs text-n-slate-12"
            />
            <div
              class="flex flex-wrap items-center gap-4 text-xs text-n-slate-11"
            >
              <label class="inline-flex items-center gap-1.5 cursor-pointer">
                <input
                  v-model="deadlineOnlyRebill"
                  type="checkbox"
                  class="rounded border-n-weak"
                />
                <span>{{ UI.DEADLINES.ONLY_REBILL }}</span>
              </label>
              <label class="inline-flex items-center gap-1.5 cursor-pointer">
                <input
                  v-model="deadlineShowCompleted"
                  type="checkbox"
                  class="rounded border-n-weak"
                />
                <span>{{ UI.DEADLINES.SHOW_COMPLETED }}</span>
              </label>
            </div>
          </div>
        </div>

        <div
          class="rounded-xl border border-n-weak bg-n-solid-2 overflow-hidden"
        >
          <div
            v-if="!filteredDeadlines.length"
            class="px-4 py-10 text-center text-sm text-n-slate-10"
          >
            {{ UI.DEADLINES.EMPTY }}
          </div>

          <template v-else>
            <!-- Desktop table -->
            <div class="hidden md:block overflow-x-auto">
              <table class="w-full text-left text-sm">
                <thead>
                  <tr class="border-b border-n-weak text-xs text-n-slate-10">
                    <th class="px-4 py-2.5 font-medium">
                      {{ UI.DEADLINES.COL_DEADLINE }}
                    </th>
                    <th class="px-3 py-2.5 font-medium">
                      {{ UI.DEADLINES.COL_CATEGORY }}
                    </th>
                    <th class="px-3 py-2.5 font-medium">
                      {{ UI.DEADLINES.COL_PAYER }}
                    </th>
                    <th class="px-3 py-2.5 font-medium">
                      {{ UI.DEADLINES.COL_DUE }}
                    </th>
                    <th class="px-3 py-2.5 text-right font-medium">
                      {{ UI.DEADLINES.COL_AMOUNT }}
                    </th>
                    <th class="px-4 py-2.5 text-right font-medium">
                      {{ UI.DEADLINES.COL_ACTIONS }}
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-n-weak">
                  <tr
                    v-for="dl in filteredDeadlines"
                    :key="dl.id"
                    class="hover:bg-n-alpha-1"
                  >
                    <td class="px-4 py-3">
                      <div class="font-medium text-n-slate-12">
                        {{ dl.title }}
                      </div>
                      <div
                        class="mt-0.5 flex flex-wrap gap-x-2.5 text-xs text-n-slate-10"
                      >
                        <span v-if="dl.related_domain">{{
                          dl.related_domain
                        }}</span>
                        <span v-if="dl.client_name">{{ dl.client_name }}</span>
                        <span v-if="dl.provider">{{ dl.provider }}</span>
                      </div>
                    </td>
                    <td class="px-3 py-3 text-xs text-n-slate-11">
                      {{ DEADLINE_CATEGORY_LABELS[dl.category] || dl.category }}
                    </td>
                    <td class="px-3 py-3 text-xs">
                      <span
                        class="inline-flex rounded px-1.5 py-0.5 font-medium"
                        :class="
                          dl.payer_mode === 'rebill_client'
                            ? 'bg-n-amber-3 text-n-amber-11'
                            : 'bg-n-alpha-2 text-n-slate-11'
                        "
                      >
                        {{ PAYER_MODE_SHORT[dl.payer_mode] || dl.payer_mode }}
                      </span>
                    </td>
                    <td class="px-3 py-3 tabular-nums">
                      <div class="text-xs font-medium text-n-slate-12">
                        {{ formatDateRu(dl.due_on) }}
                      </div>
                      <span
                        class="mt-0.5 inline-flex rounded px-1.5 py-0.5 text-[11px] font-medium"
                        :class="deadlineDaysBadge(dl).classes"
                      >
                        {{ deadlineDaysBadge(dl).text }}
                      </span>
                    </td>
                    <td class="px-3 py-3 text-right tabular-nums">
                      <div class="font-semibold text-n-slate-12">
                        {{
                          dl.amount > 0
                            ? formatMoney(dl.amount, dl.currency)
                            : '—'
                        }}
                      </div>
                      <div class="text-[11px] text-n-slate-10">
                        {{ RECURRENCE_SHORT[dl.recurrence] || dl.recurrence }}
                      </div>
                    </td>
                    <td class="px-4 py-3 text-right">
                      <div class="inline-flex items-center gap-1">
                        <Button
                          v-if="dl.status === 'active'"
                          size="xs"
                          variant="faded"
                          color="slate"
                          :label="UI.OVERVIEW.COMPLETE_BTN"
                          @click="completeDeadlineItem(dl)"
                        />
                        <Button
                          size="xs"
                          variant="ghost"
                          color="slate"
                          icon="i-lucide-pencil"
                          @click="openEditDeadline(dl)"
                        />
                        <Button
                          size="xs"
                          variant="ghost"
                          color="ruby"
                          icon="i-lucide-trash-2"
                          @click="removeDeadlineItem(dl)"
                        />
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <!-- Mobile cards (<768px) -->
            <div class="md:hidden divide-y divide-n-weak">
              <div
                v-for="dl in filteredDeadlines"
                :key="dl.id"
                class="p-4 space-y-2"
              >
                <div class="flex items-start justify-between gap-2">
                  <div>
                    <span
                      class="inline-flex rounded px-1.5 py-0.5 text-[11px] font-medium tabular-nums"
                      :class="deadlineDaysBadge(dl).classes"
                    >
                      {{ deadlineDaysBadge(dl).text }}
                    </span>
                    <div class="mt-1 font-medium text-n-slate-12">
                      {{ dl.title }}
                    </div>
                  </div>
                  <div
                    class="text-right font-semibold text-n-slate-12 tabular-nums"
                  >
                    {{
                      dl.amount > 0 ? formatMoney(dl.amount, dl.currency) : '—'
                    }}
                  </div>
                </div>
                <div class="flex flex-wrap gap-2 text-xs text-n-slate-10">
                  <span>{{ formatDateRu(dl.due_on) }}</span>
                  <span>{{
                    DEADLINE_CATEGORY_LABELS[dl.category] || dl.category
                  }}</span>
                  <span>{{
                    PAYER_MODE_SHORT[dl.payer_mode] || dl.payer_mode
                  }}</span>
                  <span v-if="dl.related_domain">{{ dl.related_domain }}</span>
                </div>
                <div class="flex items-center gap-1.5 pt-1">
                  <Button
                    v-if="dl.status === 'active'"
                    size="xs"
                    variant="faded"
                    color="slate"
                    :label="UI.OVERVIEW.COMPLETE_BTN"
                    @click="completeDeadlineItem(dl)"
                  />
                  <Button
                    size="xs"
                    variant="ghost"
                    color="slate"
                    :label="UI.EDIT"
                    @click="openEditDeadline(dl)"
                  />
                  <Button
                    size="xs"
                    variant="ghost"
                    color="ruby"
                    :label="UI.DELETE"
                    @click="removeDeadlineItem(dl)"
                  />
                </div>
              </div>
            </div>
          </template>
        </div>
      </div>

      <!-- TAB 3: STATEMENTS & BUSINESS EXPENSES -->
      <div v-else-if="activeTab === 'transactions'" class="space-y-5">
        <!-- Upload & Quick Add Bar -->
        <div class="rounded-xl border border-n-weak bg-n-solid-2 p-4 space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <select
                v-model="uploadAccountId"
                class="!mb-0 !h-8 rounded-lg border border-n-weak bg-n-surface-1 py-0 pl-2.5 pr-7 text-xs text-n-slate-12"
              >
                <option value="">
                  {{ UI.TX.UPLOAD_ACCOUNT_ANY }}
                </option>
                <option v-for="acc in accounts" :key="acc.id" :value="acc.id">
                  {{ acc.name }}
                </option>
              </select>
              <Button
                size="sm"
                variant="faded"
                color="slate"
                icon="i-lucide-upload"
                :label="isUploading ? UI.UPLOADING : UI.UPLOAD_STATEMENT"
                :is-loading="isUploading"
                @click="triggerFileUpload"
              />
              <span class="text-xs text-n-slate-10">
                {{ UI.TX.UPLOAD_HINT }}
              </span>
            </div>

            <Button
              size="sm"
              icon="i-lucide-plus"
              :label="UI.ADD_TRANSACTION"
              @click="openNewTransaction"
            />
          </div>

          <div
            v-if="lastImportSummary"
            class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-xs text-n-slate-12 tabular-nums"
          >
            {{ formatImportSummary(lastImportSummary) }}
          </div>

          <div
            class="flex flex-wrap items-center justify-between gap-2 text-xs text-n-slate-10"
          >
            <span>{{ UI.TX.PRIVACY_NOTE }}</span>
            <span class="tabular-nums">
              {{ UI.TX.TOMBSTONES_COUNT }}
              <strong class="text-n-slate-11">{{
                kpis.hidden_personal_count || 0
              }}</strong>
            </span>
          </div>
        </div>

        <!-- Needs Review Queue (Business vs Personal Filter) -->
        <div
          class="rounded-xl border border-n-weak bg-n-solid-2 overflow-hidden"
        >
          <div
            class="flex items-center justify-between gap-2 border-b border-n-weak px-4 py-3"
          >
            <h2 class="text-sm font-semibold text-n-slate-12">
              {{ UI.TX.NEEDS_REVIEW_TITLE }}
            </h2>
            <span
              class="rounded-full px-2 py-0.5 text-xs font-semibold tabular-nums"
              :class="
                needsReviewTransactions.length > 0
                  ? 'bg-n-amber-3 text-n-amber-11'
                  : 'bg-n-alpha-2 text-n-slate-11'
              "
            >
              {{ needsReviewTransactions.length }}
            </span>
          </div>

          <div
            v-if="!needsReviewTransactions.length"
            class="px-4 py-6 text-center text-sm text-n-slate-10"
          >
            {{ UI.TX.NEEDS_REVIEW_EMPTY }}
          </div>

          <div v-else class="divide-y divide-n-weak">
            <div
              v-for="tx in needsReviewTransactions"
              :key="tx.id"
              class="flex flex-col lg:flex-row lg:items-center justify-between gap-3 px-4 py-3"
            >
              <div class="min-w-0 flex-1">
                <div
                  class="flex items-center gap-2 text-xs text-n-slate-10 tabular-nums"
                >
                  <span>{{ formatDateRu(tx.occurred_on) }}</span>
                  <span class="font-semibold text-sm text-n-slate-12">
                    {{ formatMoney(tx.amount, tx.currency) }}
                  </span>
                </div>
                <div class="mt-0.5 font-medium text-sm text-n-slate-12">
                  {{ tx.merchant }}
                </div>
                <div
                  v-if="tx.description && tx.description !== tx.merchant"
                  class="mt-0.5 truncate text-xs text-n-slate-10"
                >
                  {{ tx.description }}
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <select
                  v-model="reviewDraftCategories[tx.id]"
                  class="!mb-0 !h-8 rounded-lg border border-n-weak bg-n-surface-1 py-0 pl-2.5 pr-7 text-xs text-n-slate-12"
                >
                  <option
                    v-for="cat in categoryOptions"
                    :key="cat.code"
                    :value="cat.code"
                  >
                    {{ cat.label }}
                  </option>
                </select>

                <Button
                  size="xs"
                  color="blue"
                  :label="UI.TX.CONFIRM_BUSINESS_BTN"
                  @click="confirmReviewAsBusiness(tx)"
                />
                <Button
                  size="xs"
                  variant="faded"
                  color="slate"
                  :label="UI.TX.HIDE_PERSONAL_BTN"
                  @click="hideAsPersonal(tx, false)"
                />
                <Button
                  size="xs"
                  variant="ghost"
                  color="ruby"
                  :label="UI.TX.HIDE_ALWAYS_BTN"
                  @click="hideAsPersonal(tx, true)"
                />
              </div>
            </div>
          </div>
        </div>

        <!-- Confirmed Business Transactions -->
        <div
          class="rounded-xl border border-n-weak bg-n-solid-2 overflow-hidden"
        >
          <div
            class="flex flex-wrap items-center justify-between gap-3 border-b border-n-weak px-4 py-3"
          >
            <h2 class="text-sm font-semibold text-n-slate-12">
              {{ UI.TX.CONFIRMED_TITLE }}
            </h2>

            <div class="flex flex-wrap items-center gap-2">
              <div class="flex items-center gap-1">
                <button
                  type="button"
                  class="rounded-md px-2 py-1 text-xs font-medium"
                  :class="
                    txDirectionFilter === 'all'
                      ? 'bg-n-alpha-2 text-n-slate-12'
                      : 'text-n-slate-11'
                  "
                  @click="txDirectionFilter = 'all'"
                >
                  {{ UI.TX.FILTER_ALL }}
                </button>
                <button
                  type="button"
                  class="rounded-md px-2 py-1 text-xs font-medium"
                  :class="
                    txDirectionFilter === 'income'
                      ? 'bg-n-alpha-2 text-n-slate-12'
                      : 'text-n-slate-11'
                  "
                  @click="txDirectionFilter = 'income'"
                >
                  {{ UI.TX.FILTER_INCOME }}
                </button>
                <button
                  type="button"
                  class="rounded-md px-2 py-1 text-xs font-medium"
                  :class="
                    txDirectionFilter === 'expense'
                      ? 'bg-n-alpha-2 text-n-slate-12'
                      : 'text-n-slate-11'
                  "
                  @click="txDirectionFilter = 'expense'"
                >
                  {{ UI.TX.FILTER_EXPENSE }}
                </button>
                <button
                  type="button"
                  class="rounded-md px-2 py-1 text-xs font-medium"
                  :class="
                    txDirectionFilter === 'transfer'
                      ? 'bg-n-alpha-2 text-n-slate-12'
                      : 'text-n-slate-11'
                  "
                  @click="txDirectionFilter = 'transfer'"
                >
                  {{ UI.TX.FILTER_TRANSFER }}
                </button>
              </div>

              <input
                v-model="txSearch"
                type="search"
                :placeholder="UI.TX.SEARCH_PLACEHOLDER"
                class="!mb-0 !h-8 w-full sm:w-64 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-xs text-n-slate-12"
              />
            </div>
          </div>

          <div
            v-if="!filteredTransactions.length"
            class="px-4 py-8 text-center text-sm text-n-slate-10"
          >
            {{ UI.TX.EMPTY_CONFIRMED }}
          </div>

          <div v-else class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr class="border-b border-n-weak text-xs text-n-slate-10">
                  <th class="px-4 py-2.5 font-medium">
                    {{ UI.TX.COL_DATE }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.TX.COL_MERCHANT }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.TX.COL_CATEGORY }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.TX.COL_SOURCE }}
                  </th>
                  <th class="px-3 py-2.5 text-right font-medium">
                    {{ UI.TX.COL_AMOUNT }}
                  </th>
                  <th class="px-4 py-2.5 text-right font-medium">
                    {{ UI.TX.COL_ACTIONS }}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak">
                <tr
                  v-for="tx in filteredTransactions"
                  :key="tx.id"
                  class="hover:bg-n-alpha-1"
                >
                  <td
                    class="px-4 py-2.5 text-xs text-n-slate-11 whitespace-nowrap tabular-nums"
                  >
                    {{ formatDateRu(tx.occurred_on) }}
                  </td>
                  <td class="px-3 py-2.5">
                    <div class="font-medium text-n-slate-12">
                      {{ tx.merchant }}
                    </div>
                    <div
                      v-if="tx.description && tx.description !== tx.merchant"
                      class="max-w-md truncate text-xs text-n-slate-10"
                    >
                      {{ tx.description }}
                    </div>
                  </td>
                  <td class="px-3 py-2.5 text-xs text-n-slate-11">
                    {{ tx.category_label }}
                  </td>
                  <td class="px-3 py-2.5 text-xs text-n-slate-10">
                    {{
                      tx.official_status === 'official_1c'
                        ? UI.TX.SOURCE_1C
                        : UI.TX.SOURCE_MGMT
                    }}
                  </td>
                  <td
                    class="px-3 py-2.5 text-right font-semibold whitespace-nowrap tabular-nums"
                    :class="
                      tx.direction === 'income'
                        ? 'text-n-teal-11'
                        : tx.direction === 'transfer'
                          ? 'text-n-slate-10'
                          : 'text-n-slate-12'
                    "
                  >
                    {{
                      tx.direction === 'income'
                        ? '+'
                        : tx.direction === 'expense'
                          ? '−'
                          : ''
                    }}
                    {{ formatMoney(tx.amount, tx.currency) }}
                  </td>
                  <td class="px-4 py-2.5 text-right whitespace-nowrap">
                    <div class="inline-flex items-center gap-1">
                      <Button
                        size="xs"
                        variant="ghost"
                        color="slate"
                        icon="i-lucide-pencil"
                        @click="openEditTransaction(tx)"
                      />
                      <Button
                        size="xs"
                        variant="ghost"
                        color="slate"
                        :label="UI.TX.HIDE_PERSONAL_BTN"
                        @click="hideAsPersonal(tx, false)"
                      />
                      <Button
                        size="xs"
                        variant="ghost"
                        color="ruby"
                        icon="i-lucide-trash-2"
                        @click="removeTransactionItem(tx)"
                      />
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- TAB 4: CONTRACTS, MEDELEMENT 30% & 1C:FRESH -->
      <div v-else-if="activeTab === 'contracts'" class="space-y-5">
        <!-- Contracts Table -->
        <div
          class="rounded-xl border border-n-weak bg-n-solid-2 overflow-hidden"
        >
          <div
            class="flex flex-wrap items-center justify-between gap-2 border-b border-n-weak px-4 py-3"
          >
            <div>
              <h2 class="text-sm font-semibold text-n-slate-12">
                {{ UI.CONTRACTS.SECTION_TITLE }}
              </h2>
              <p class="text-xs text-n-slate-10">
                {{ UI.CONTRACTS.EXPIRY_AUTO_NOTE }}
              </p>
            </div>
            <Button
              size="xs"
              icon="i-lucide-plus"
              :label="UI.ADD_CONTRACT"
              @click="openNewContract"
            />
          </div>

          <div
            v-if="!contracts.length"
            class="px-4 py-8 text-center text-sm text-n-slate-10"
          >
            {{ UI.CONTRACTS.EMPTY }}
          </div>

          <div v-else class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr class="border-b border-n-weak text-xs text-n-slate-10">
                  <th class="px-4 py-2.5 font-medium">
                    {{ UI.CONTRACTS.COL_CLIENT }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.CONTRACTS.COL_TARIFF }}
                  </th>
                  <th class="px-3 py-2.5 text-right font-medium">
                    {{ UI.CONTRACTS.COL_MRR }}
                  </th>
                  <th class="px-3 py-2.5 text-right font-medium">
                    {{ UI.CONTRACTS.COL_MEDELEMENT }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.CONTRACTS.COL_EXPIRES }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.CONTRACTS.COL_STATUS }}
                  </th>
                  <th class="px-4 py-2.5 text-right font-medium">
                    {{ UI.CONTRACTS.COL_ACTIONS }}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak">
                <tr
                  v-for="c in contracts"
                  :key="c.id"
                  class="hover:bg-n-alpha-1"
                >
                  <td class="px-4 py-3">
                    <div class="font-medium text-n-slate-12">
                      {{ c.client_name }}
                    </div>
                    <div class="text-xs text-n-slate-10">
                      {{ c.title }}
                      <span v-if="c.contract_number">
                        · {{ c.contract_number }}
                      </span>
                      <span v-if="c.onelink_account_name" class="text-n-brand">
                        · {{ c.onelink_account_name }}
                      </span>
                    </div>
                  </td>
                  <td class="px-3 py-3 text-xs text-n-slate-11">
                    {{ CONTRACT_TARIFF_SHORT[c.tariff_code] || c.tariff_code }}
                  </td>
                  <td
                    class="px-3 py-3 text-right font-semibold text-n-slate-12 tabular-nums"
                  >
                    {{ formatMoney(c.monthly_amount, c.currency) }}
                  </td>
                  <td class="px-3 py-3 text-right text-xs tabular-nums">
                    <span
                      v-if="c.medelement_commission_enabled"
                      class="font-medium text-n-amber-11"
                    >
                      {{ UI.CONTRACTS.MEDELEMENT_30_PREFIX }}
                      {{ formatKzt(c.medelement_monthly_commission_kzt) }}
                    </span>
                    <span v-else class="text-n-slate-10">
                      {{ UI.CONTRACTS.DIRECT_ZERO }}
                    </span>
                  </td>
                  <td class="px-3 py-3 text-xs text-n-slate-11 tabular-nums">
                    {{ formatDateRu(c.ends_on) }}
                  </td>
                  <td class="px-3 py-3 text-xs">
                    <span
                      class="inline-flex rounded px-1.5 py-0.5 font-medium"
                      :class="
                        c.status === 'active'
                          ? 'bg-n-teal-3 text-n-teal-11'
                          : 'bg-n-alpha-2 text-n-slate-11'
                      "
                    >
                      {{ CONTRACT_STATUS_SHORT[c.status] || c.status }}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-right">
                    <div class="inline-flex items-center gap-1">
                      <Button
                        size="xs"
                        variant="ghost"
                        color="slate"
                        icon="i-lucide-pencil"
                        @click="openEditContract(c)"
                      />
                      <Button
                        size="xs"
                        variant="ghost"
                        color="ruby"
                        icon="i-lucide-trash-2"
                        @click="removeContractItem(c)"
                      />
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <!-- MedElement 30% Commissions, Partner Settlements & Debts -->
        <div
          class="rounded-xl border border-n-weak bg-n-solid-2 overflow-hidden"
        >
          <div
            class="flex flex-wrap items-center justify-between gap-2 border-b border-n-weak px-4 py-3"
          >
            <h2 class="text-sm font-semibold text-n-slate-12">
              {{ UI.CONTRACTS.OBLIGATIONS_TITLE }}
            </h2>
            <Button
              size="xs"
              icon="i-lucide-plus"
              :label="UI.ADD_OBLIGATION"
              @click="openNewObligation"
            />
          </div>

          <div
            class="flex flex-wrap items-center gap-1.5 border-b border-n-weak px-4 py-2.5"
          >
            <button
              type="button"
              class="rounded-md px-2.5 py-1 text-xs font-medium"
              :class="
                obligationFilter === 'open'
                  ? 'bg-n-alpha-2 text-n-slate-12'
                  : 'text-n-slate-11'
              "
              @click="obligationFilter = 'open'"
            >
              {{ UI.CONTRACTS.OB_FILTER_OPEN }}
            </button>
            <button
              type="button"
              class="rounded-md px-2.5 py-1 text-xs font-medium"
              :class="
                obligationFilter === 'medelement'
                  ? 'bg-n-alpha-2 text-n-slate-12'
                  : 'text-n-slate-11'
              "
              @click="obligationFilter = 'medelement'"
            >
              {{ UI.CONTRACTS.OB_FILTER_MED }}
            </button>
            <button
              type="button"
              class="rounded-md px-2.5 py-1 text-xs font-medium"
              :class="
                obligationFilter === 'partner'
                  ? 'bg-n-alpha-2 text-n-slate-12'
                  : 'text-n-slate-11'
              "
              @click="obligationFilter = 'partner'"
            >
              {{ UI.CONTRACTS.OB_FILTER_PARTNER }}
            </button>
            <button
              type="button"
              class="rounded-md px-2.5 py-1 text-xs font-medium"
              :class="
                obligationFilter === 'receivable'
                  ? 'bg-n-alpha-2 text-n-slate-12'
                  : 'text-n-slate-11'
              "
              @click="obligationFilter = 'receivable'"
            >
              {{ UI.CONTRACTS.OB_FILTER_REC }}
            </button>
            <button
              type="button"
              class="rounded-md px-2.5 py-1 text-xs font-medium"
              :class="
                obligationFilter === 'payable'
                  ? 'bg-n-alpha-2 text-n-slate-12'
                  : 'text-n-slate-11'
              "
              @click="obligationFilter = 'payable'"
            >
              {{ UI.CONTRACTS.OB_FILTER_PAY }}
            </button>
            <button
              type="button"
              class="rounded-md px-2.5 py-1 text-xs font-medium"
              :class="
                obligationFilter === 'paid'
                  ? 'bg-n-alpha-2 text-n-slate-12'
                  : 'text-n-slate-11'
              "
              @click="obligationFilter = 'paid'"
            >
              {{ UI.CONTRACTS.OB_FILTER_PAID }}
            </button>
          </div>

          <div
            v-if="!filteredObligations.length"
            class="px-4 py-8 text-center text-sm text-n-slate-10"
          >
            {{ UI.CONTRACTS.OB_EMPTY }}
          </div>

          <div v-else class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr class="border-b border-n-weak text-xs text-n-slate-10">
                  <th class="px-4 py-2.5 font-medium">
                    {{ UI.CONTRACTS.OB_COL_TITLE }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.CONTRACTS.OB_COL_KIND }}
                  </th>
                  <th class="px-3 py-2.5 text-right font-medium">
                    {{ UI.CONTRACTS.OB_COL_BASE }}
                  </th>
                  <th class="px-3 py-2.5 text-right font-medium">
                    {{ UI.CONTRACTS.OB_COL_OUTSTANDING }}
                  </th>
                  <th class="px-3 py-2.5 font-medium">
                    {{ UI.CONTRACTS.OB_COL_DUE }}
                  </th>
                  <th class="px-4 py-2.5 text-right font-medium">
                    {{ UI.CONTRACTS.COL_ACTIONS }}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak">
                <tr
                  v-for="ob in filteredObligations"
                  :key="ob.id"
                  class="hover:bg-n-alpha-1"
                >
                  <td class="px-4 py-2.5">
                    <div class="font-medium text-n-slate-12">
                      {{ ob.title }}
                    </div>
                    <div class="text-xs text-n-slate-10">
                      <span v-if="ob.counterparty_name">
                        {{ ob.counterparty_name }}
                      </span>
                      <span v-if="ob.period_label">
                        · {{ ob.period_label }}
                      </span>
                    </div>
                  </td>
                  <td class="px-3 py-2.5 text-xs text-n-slate-11">
                    {{ OBLIGATION_KIND_SHORT[ob.entry_kind] || ob.entry_kind }}
                  </td>
                  <td
                    class="px-3 py-2.5 text-right text-xs text-n-slate-10 tabular-nums"
                  >
                    <span v-if="ob.base_amount > 0">
                      {{ formatMoney(ob.base_amount, ob.currency) }}
                    </span>
                    <span v-else>{{ '—' }}</span>
                  </td>
                  <td
                    class="px-3 py-2.5 text-right font-semibold text-n-slate-12 tabular-nums"
                  >
                    {{
                      formatMoney(
                        ob.status === 'paid'
                          ? ob.amount
                          : ob.outstanding_amount,
                        ob.currency
                      )
                    }}
                  </td>
                  <td class="px-3 py-2.5 text-xs text-n-slate-11 tabular-nums">
                    {{ formatDateRu(ob.due_on) }}
                  </td>
                  <td class="px-4 py-2.5 text-right">
                    <div class="inline-flex items-center gap-1">
                      <Button
                        v-if="ob.status === 'open'"
                        size="xs"
                        variant="faded"
                        color="slate"
                        :label="UI.CONTRACTS.OB_MARK_PAID"
                        @click="markObligationPaid(ob)"
                      />
                      <Button
                        size="xs"
                        variant="ghost"
                        color="slate"
                        icon="i-lucide-pencil"
                        @click="openEditObligation(ob)"
                      />
                      <Button
                        size="xs"
                        variant="ghost"
                        color="ruby"
                        icon="i-lucide-trash-2"
                        @click="removeObligationItem(ob)"
                      />
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <!-- 1C:Fresh OData Sync Box -->
        <div
          class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
        >
          <div>
            <div class="text-sm font-semibold text-n-slate-12">
              {{ UI.CONTRACTS.ONEC_TITLE }}
            </div>
            <div class="mt-0.5 text-xs text-n-slate-10">
              <template v-if="onecSyncState?.last_synced_at">
                {{ UI.CONTRACTS.ONEC_LAST }}
                <strong class="text-n-slate-11 tabular-nums">
                  {{ formatDateTimeRu(onecSyncState.last_synced_at) }}
                </strong>
                <span>({{ onecSyncState.status }})</span>
              </template>
              <template v-else>
                {{ UI.CONTRACTS.ONEC_NEVER }}
              </template>
            </div>
          </div>
          <Button
            size="sm"
            variant="faded"
            color="slate"
            icon="i-lucide-refresh-cw"
            :label="UI.CONTRACTS.ONEC_SYNC_BTN"
            :is-loading="isSyncingOnec"
            @click="runOnecSync"
          />
        </div>
      </div>
    </div>

    <!-- MODALS OVERLAY -->
    <div
      v-if="activeModal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      @click.self="closeModal"
    >
      <!-- Deadline Modal -->
      <div
        v-if="activeModal === 'deadline'"
        class="w-full max-w-lg max-h-[90vh] overflow-y-auto rounded-xl border border-n-weak bg-n-solid-2 p-5 space-y-4"
      >
        <h3 class="text-base font-semibold text-n-slate-12">
          {{
            deadlineForm.id ? UI.MODALS.DEADLINE_EDIT : UI.MODALS.DEADLINE_NEW
          }}
        </h3>

        <div class="space-y-3 text-xs">
          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_TITLE }}
            </label>
            <input
              v-model="deadlineForm.title"
              type="text"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
            />
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CATEGORY }}
              </label>
              <select
                v-model="deadlineForm.category"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option
                  v-for="(label, code) in DEADLINE_CATEGORY_LABELS"
                  :key="code"
                  :value="code"
                >
                  {{ label }}
                </option>
              </select>
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_PAYER_MODE }}
              </label>
              <select
                v-model="deadlineForm.payer_mode"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option
                  v-for="opt in PAYER_MODE_OPTIONS"
                  :key="opt.code"
                  :value="opt.code"
                >
                  {{ opt.label }}
                </option>
              </select>
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_DUE_ON }}
              </label>
              <input
                v-model="deadlineForm.due_on"
                type="date"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_AMOUNT }}
              </label>
              <input
                v-model.number="deadlineForm.amount"
                type="number"
                step="0.01"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CURRENCY }}
              </label>
              <select
                v-model="deadlineForm.currency"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option v-for="cur in CURRENCY_OPTIONS" :key="cur" :value="cur">
                  {{ cur }}
                </option>
              </select>
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_DOMAIN }}
              </label>
              <input
                v-model="deadlineForm.related_domain"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CLIENT }}
              </label>
              <input
                v-model="deadlineForm.client_name"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_PROVIDER }}
              </label>
              <input
                v-model="deadlineForm.provider"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_RECURRENCE }}
              </label>
              <select
                v-model="deadlineForm.recurrence"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option
                  v-for="opt in RECURRENCE_OPTIONS"
                  :key="opt.code"
                  :value="opt.code"
                >
                  {{ opt.label }}
                </option>
              </select>
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_REMIND_DAYS }}
              </label>
              <input
                v-model="deadlineForm.remind_days_text"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>
          </div>

          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_NOTES }}
            </label>
            <textarea
              v-model="deadlineForm.notes"
              rows="2"
              class="!mb-0 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2.5 text-sm text-n-slate-12"
            />
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="UI.CANCEL"
            @click="closeModal"
          />
          <Button
            size="sm"
            :label="UI.SAVE"
            :is-loading="isSaving"
            @click="saveDeadline"
          />
        </div>
      </div>

      <!-- Account Modal -->
      <div
        v-else-if="activeModal === 'account'"
        class="w-full max-w-md max-h-[90vh] overflow-y-auto rounded-xl border border-n-weak bg-n-solid-2 p-5 space-y-4"
      >
        <h3 class="text-base font-semibold text-n-slate-12">
          {{ accountForm.id ? UI.MODALS.ACCOUNT_EDIT : UI.MODALS.ACCOUNT_NEW }}
        </h3>

        <div class="space-y-3 text-xs">
          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_ACC_NAME }}
            </label>
            <input
              v-model="accountForm.name"
              type="text"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
            />
          </div>

          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_ACC_KIND }}
            </label>
            <select
              v-model="accountForm.account_kind"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              @change="onAccountKindChange"
            >
              <option
                v-for="opt in ACCOUNT_KIND_OPTIONS"
                :key="opt.code"
                :value="opt.code"
              >
                {{ opt.label }}
              </option>
            </select>
          </div>

          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_ACC_SCOPE }}
            </label>
            <select
              v-model="accountForm.scope"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
            >
              <option
                v-for="opt in ACCOUNT_SCOPE_OPTIONS"
                :key="opt.code"
                :value="opt.code"
              >
                {{ opt.label }}
              </option>
            </select>
          </div>

          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_ACC_BALANCE }}
              </label>
              <input
                v-model.number="accountForm.current_balance"
                type="number"
                step="0.01"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CURRENCY }}
              </label>
              <select
                v-model="accountForm.currency"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option v-for="cur in CURRENCY_OPTIONS" :key="cur" :value="cur">
                  {{ cur }}
                </option>
              </select>
            </div>
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="UI.CANCEL"
            @click="closeModal"
          />
          <Button
            size="sm"
            :label="UI.SAVE"
            :is-loading="isSaving"
            @click="saveAccount"
          />
        </div>
      </div>

      <!-- Transaction Modal -->
      <div
        v-else-if="activeModal === 'transaction'"
        class="w-full max-w-lg max-h-[90vh] overflow-y-auto rounded-xl border border-n-weak bg-n-solid-2 p-5 space-y-4"
      >
        <h3 class="text-base font-semibold text-n-slate-12">
          {{ txForm.id ? UI.MODALS.TX_EDIT : UI.MODALS.TX_NEW }}
        </h3>

        <div class="space-y-3 text-xs">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_DATE }}
              </label>
              <input
                v-model="txForm.occurred_on"
                type="date"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_DIRECTION }}
              </label>
              <select
                v-model="txForm.direction"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option
                  v-for="opt in TX_DIRECTION_OPTIONS"
                  :key="opt.code"
                  :value="opt.code"
                >
                  {{ opt.label }}
                </option>
              </select>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_AMOUNT }}
              </label>
              <input
                v-model.number="txForm.amount"
                type="number"
                step="0.01"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CURRENCY }}
              </label>
              <select
                v-model="txForm.currency"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option v-for="cur in CURRENCY_OPTIONS" :key="cur" :value="cur">
                  {{ cur }}
                </option>
              </select>
            </div>
          </div>

          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_MERCHANT }}
            </label>
            <input
              v-model="txForm.merchant"
              type="text"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
            />
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CATEGORY }}
              </label>
              <select
                v-model="txForm.category"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option
                  v-for="cat in categoryOptions"
                  :key="cat.code"
                  :value="cat.code"
                >
                  {{ cat.label }}
                </option>
              </select>
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_PNL_TREATMENT }}
              </label>
              <select
                v-model="txForm.pnl_treatment"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option
                  v-for="opt in TX_PNL_OPTIONS"
                  :key="opt.code"
                  :value="opt.code"
                >
                  {{ opt.label }}
                </option>
              </select>
            </div>
          </div>

          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_DESCRIPTION }}
            </label>
            <input
              v-model="txForm.description"
              type="text"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
            />
          </div>

          <label class="inline-flex items-center gap-2 cursor-pointer pt-1">
            <input
              v-model="txForm.learn_vendor"
              type="checkbox"
              class="rounded border-n-weak"
            />
            <span class="text-xs text-n-slate-11">
              {{ UI.MODALS.FIELD_LEARN_VENDOR }}
            </span>
          </label>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="UI.CANCEL"
            @click="closeModal"
          />
          <Button
            size="sm"
            :label="UI.SAVE"
            :is-loading="isSaving"
            @click="saveTransaction"
          />
        </div>
      </div>

      <!-- Contract Modal -->
      <div
        v-else-if="activeModal === 'contract'"
        class="w-full max-w-lg max-h-[90vh] overflow-y-auto rounded-xl border border-n-weak bg-n-solid-2 p-5 space-y-4"
      >
        <h3 class="text-base font-semibold text-n-slate-12">
          {{
            contractForm.id ? UI.MODALS.CONTRACT_EDIT : UI.MODALS.CONTRACT_NEW
          }}
        </h3>

        <div class="space-y-3 text-xs">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CLIENT }}
              </label>
              <input
                v-model="contractForm.client_name"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_CONTRACT_NUM }}
              </label>
              <input
                v-model="contractForm.contract_number"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_TITLE }}
              </label>
              <input
                v-model="contractForm.title"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_STATUS }}
              </label>
              <select
                v-model="contractForm.status"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              >
                <option
                  v-for="opt in CONTRACT_STATUS_OPTIONS"
                  :key="opt.code"
                  :value="opt.code"
                >
                  {{ opt.label }}
                </option>
              </select>
            </div>
          </div>

          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_TARIFF }}
            </label>
            <select
              v-model="contractForm.tariff_code"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              @change="onContractTariffChange"
            >
              <option
                v-for="opt in CONTRACT_TARIFF_OPTIONS"
                :key="opt.code"
                :value="opt.code"
              >
                {{ opt.label }}
              </option>
            </select>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_MONTHLY_AMOUNT }}
              </label>
              <input
                v-model.number="contractForm.monthly_amount"
                type="number"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_ONE_TIME_AMOUNT }}
              </label>
              <input
                v-model.number="contractForm.one_time_amount"
                type="number"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_BILLING_DAY }}
              </label>
              <input
                v-model.number="contractForm.billing_day"
                type="number"
                min="1"
                max="31"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_STARTS_ON }}
              </label>
              <input
                v-model="contractForm.starts_on"
                type="date"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_ENDS_ON }}
              </label>
              <input
                v-model="contractForm.ends_on"
                type="date"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_ONELINK_ACC_ID }}
              </label>
              <input
                v-model="contractForm.onelink_account_id"
                type="number"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>
          </div>

          <label class="inline-flex items-center gap-2 cursor-pointer pt-1">
            <input
              v-model="contractForm.medelement_commission_enabled"
              type="checkbox"
              class="rounded border-n-weak"
            />
            <span class="text-xs text-n-slate-11">
              {{ UI.MODALS.FIELD_MEDELEMENT_ENABLED }}
            </span>
          </label>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="UI.CANCEL"
            @click="closeModal"
          />
          <Button
            size="sm"
            :label="UI.SAVE"
            :is-loading="isSaving"
            @click="saveContract"
          />
        </div>
      </div>

      <!-- Obligation Modal -->
      <div
        v-else-if="activeModal === 'obligation'"
        class="w-full max-w-lg max-h-[90vh] overflow-y-auto rounded-xl border border-n-weak bg-n-solid-2 p-5 space-y-4"
      >
        <h3 class="text-base font-semibold text-n-slate-12">
          {{
            obligationForm.id
              ? UI.MODALS.OBLIGATION_EDIT
              : UI.MODALS.OBLIGATION_NEW
          }}
        </h3>

        <div class="space-y-3 text-xs">
          <div>
            <label class="block mb-1 font-medium text-n-slate-11">
              {{ UI.MODALS.FIELD_OB_KIND }}
            </label>
            <select
              v-model="obligationForm.entry_kind"
              class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
            >
              <option
                v-for="opt in OBLIGATION_KIND_OPTIONS"
                :key="opt.code"
                :value="opt.code"
              >
                {{ opt.label }}
              </option>
            </select>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_TITLE }}
              </label>
              <input
                v-model="obligationForm.title"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_COUNTERPARTY }}
              </label>
              <input
                v-model="obligationForm.counterparty_name"
                type="text"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
              />
            </div>
          </div>

          <div
            v-if="obligationForm.entry_kind === 'medelement_commission'"
            class="grid grid-cols-2 gap-3"
          >
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_BASE_AMOUNT }}
              </label>
              <input
                v-model.number="obligationForm.base_amount"
                type="number"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
                @input="onObligationBaseChange"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_OVERAGE_EXCLUDED }}
              </label>
              <input
                v-model.number="obligationForm.overage_excluded_amount"
                type="number"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_AMOUNT }}
              </label>
              <input
                v-model.number="obligationForm.amount"
                type="number"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_PAID_AMOUNT }}
              </label>
              <input
                v-model.number="obligationForm.paid_amount"
                type="number"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12 tabular-nums"
              />
            </div>

            <div>
              <label class="block mb-1 font-medium text-n-slate-11">
                {{ UI.MODALS.FIELD_DUE_ON }}
              </label>
              <input
                v-model="obligationForm.due_on"
                type="date"
                class="!mb-0 !h-9 w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-sm text-n-slate-12"
              />
            </div>
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="UI.CANCEL"
            @click="closeModal"
          />
          <Button
            size="sm"
            :label="UI.SAVE"
            :is-loading="isSaving"
            @click="saveObligation"
          />
        </div>
      </div>
    </div>
  </section>
</template>
