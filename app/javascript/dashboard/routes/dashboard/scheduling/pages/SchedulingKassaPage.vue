<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMoneyInput from 'dashboard/components-next/Scheduling/SchedulingMoneyInput.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingResourceFilter from 'dashboard/components-next/Scheduling/SchedulingResourceFilter.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingSectionCard from 'dashboard/components-next/Scheduling/SchedulingSectionCard.vue';
import {
  EXPENSE_STATUS_VALUES,
  PAYMENT_KIND_VALUES,
  PAYMENT_METHOD_VALUES,
} from '../constants';
import {
  extractSchedulingError,
  toNumeric,
} from 'dashboard/stores/scheduling/shared';
import { formatCurrency } from '../helpers';
import { useSchedulingKassaStore } from 'dashboard/stores/scheduling/kassa';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t, locale } = useI18n();
const kassaStore = useSchedulingKassaStore();
const referencesStore = useSchedulingReferencesStore();
const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const formatDateTimeLabel = value => {
  if (!value) return '—';

  return new Intl.DateTimeFormat(localeCode.value, {
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    month: 'short',
  }).format(new Date(value));
};

const paymentDrawerOpen = ref(false);
const paymentForm = reactive({
  amount: '',
  appointmentId: '',
  paymentMethod: 'cash',
});

const tabOptions = computed(() => [
  { label: t('SCHEDULING.KASSA.INCOME_TAB'), value: 'income' },
  { label: t('SCHEDULING.KASSA.EXPENSES_TAB'), value: 'expenses' },
]);

const paymentMethodLabels = computed(() => ({
  bank_transfer: t('SCHEDULING.KASSA.PAYMENT_METHODS.bank_transfer'),
  card: t('SCHEDULING.KASSA.PAYMENT_METHODS.card'),
  cash: t('SCHEDULING.KASSA.PAYMENT_METHODS.cash'),
  kaspi_qr: t('SCHEDULING.KASSA.PAYMENT_METHODS.kaspi_qr'),
  kaspi_transfer: t('SCHEDULING.KASSA.PAYMENT_METHODS.kaspi_transfer'),
  other: t('SCHEDULING.KASSA.PAYMENT_METHODS.other'),
}));

const paymentKindLabels = computed(() => ({
  adjustment: t('SCHEDULING.KASSA.PAYMENT_KINDS.adjustment'),
  payment: t('SCHEDULING.KASSA.PAYMENT_KINDS.payment'),
  prepaid: t('SCHEDULING.KASSA.PAYMENT_KINDS.prepaid'),
}));

const expenseStatusLabels = computed(() => ({
  paid: t('SCHEDULING.KASSA.EXPENSE_STATUS.paid'),
  unpaid: t('SCHEDULING.KASSA.EXPENSE_STATUS.unpaid'),
}));

const appointmentOptions = computed(() =>
  kassaStore.appointmentCandidates.map(appointment => ({
    label: [
      appointment.clientName || `#${appointment.id}`,
      appointment.serviceNameSnapshot || t('SCHEDULING.CALENDAR.NO_SERVICE'),
      formatDateTimeLabel(appointment.startsAt),
    ]
      .filter(Boolean)
      .join(' · '),
    value: appointment.id,
  }))
);

const paymentMethodOptions = computed(() =>
  PAYMENT_METHOD_VALUES.map(value => ({
    label: paymentMethodLabels.value[value] || value,
    value,
  }))
);

const paymentKindOptions = computed(() =>
  PAYMENT_KIND_VALUES.map(value => ({
    label: paymentKindLabels.value[value] || value,
    value,
  }))
);

const expenseStatusOptions = computed(() =>
  EXPENSE_STATUS_VALUES.map(value => ({
    label: expenseStatusLabels.value[value] || value,
    value,
  }))
);

const paymentKindLabel = kind => paymentKindLabels.value[kind] || kind;
const paymentMethodLabel = method =>
  paymentMethodLabels.value[method] || method;
const expenseStatusLabel = status =>
  expenseStatusLabels.value[status] || status;

const paymentRows = computed(() => kassaStore.decoratedPayments);
const expenseRows = computed(() => kassaStore.decoratedExpenses);

const paymentColumns = computed(() => [
  {
    key: 'createdAt',
    label: t('SCHEDULING.KASSA.RECORDED_AT'),
    width: '180px',
  },
  {
    key: 'appointment',
    label: t('SCHEDULING.KASSA.APPOINTMENT'),
    width: '1.3fr',
  },
  { key: 'resource', label: t('SCHEDULING.GENERAL.RESOURCE'), width: '1fr' },
  {
    key: 'paymentKind',
    label: t('SCHEDULING.KASSA.PAYMENT_KIND'),
    width: '140px',
  },
  {
    key: 'paymentMethod',
    label: t('SCHEDULING.KASSA.PAYMENT_METHOD'),
    width: '160px',
  },
  {
    key: 'amount',
    label: t('SCHEDULING.GENERAL.AMOUNT'),
    width: '120px',
    align: 'end',
  },
  { key: 'actions', label: '', width: '140px', align: 'end' },
]);

const expenseColumns = computed(() => [
  {
    key: 'appointment',
    label: t('SCHEDULING.KASSA.APPOINTMENT'),
    width: '1.3fr',
  },
  { key: 'resource', label: t('SCHEDULING.GENERAL.RESOURCE'), width: '1fr' },
  { key: 'status', label: t('SCHEDULING.GENERAL.STATUS'), width: '140px' },
  { key: 'paidAt', label: t('SCHEDULING.KASSA.PAID_AT'), width: '180px' },
  {
    key: 'amount',
    label: t('SCHEDULING.GENERAL.AMOUNT'),
    width: '120px',
    align: 'end',
  },
  { key: 'actions', label: '', width: '140px', align: 'end' },
]);

const totals = computed(() => ({
  paidExpenses: kassaStore.expenseTotals.paid,
  totalExpenses: kassaStore.expenseTotals.total,
  totalIncome: kassaStore.paymentTotal,
  unpaidExpenses: kassaStore.expenseTotals.unpaid,
}));

const activeTabIndex = computed(() =>
  kassaStore.activeTab === 'income' ? 0 : 1
);

const unpaidExpenseCount = computed(
  () => expenseRows.value.filter(item => item.status !== 'paid').length
);

const hasPaymentFormValues = computed(() => {
  return (
    Number(paymentForm.amount) > 0 &&
    Number(paymentForm.appointmentId) > 0 &&
    !!paymentForm.paymentMethod
  );
});

const resourceName = resourceId => {
  return (
    referencesStore.resources.find(resource => resource.id === resourceId)
      ?.name || '—'
  );
};

const appointmentLabel = appointment => {
  if (!appointment) return '—';

  return [
    appointment.clientName || `#${appointment.id}`,
    appointment.serviceNameSnapshot,
  ]
    .filter(Boolean)
    .join(' · ');
};

const formatDateTime = value => formatDateTimeLabel(value);

const resetPaymentForm = () => {
  Object.assign(paymentForm, {
    amount: '',
    appointmentId: '',
    paymentMethod: 'cash',
  });
};

const loadPage = async () => {
  await Promise.all([
    referencesStore.loadResources({ include_inactive: true }),
    kassaStore.loadAll(),
  ]);
};

const openPaymentDrawer = () => {
  resetPaymentForm();
  paymentDrawerOpen.value = true;
};

const closePaymentDrawer = () => {
  paymentDrawerOpen.value = false;
  resetPaymentForm();
};

const toggleFilterValue = async (field, value) => {
  const current = kassaStore.filters[field];
  const nextValues = current.includes(value)
    ? current.filter(item => item !== value)
    : [...current, value];

  kassaStore.updateFilters({ [field]: nextValues });
  await kassaStore.loadAll();
};

const handleApplyFilters = async () => {
  try {
    await kassaStore.loadAll();
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const handleAddPayment = async () => {
  try {
    await kassaStore.addPayment({
      amount: paymentForm.amount,
      appointmentId: toNumeric(paymentForm.appointmentId),
      paymentMethod: paymentForm.paymentMethod,
    });
    useAlert(t('SCHEDULING.KASSA.SUCCESS_PAYMENT'));
    closePaymentDrawer();
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const handleCancelPayments = async appointmentId => {
  try {
    await kassaStore.cancelPayments(appointmentId);
    useAlert(t('SCHEDULING.KASSA.SUCCESS_CANCEL'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const handlePayExpense = async expenseId => {
  try {
    await kassaStore.payExpense(expenseId);
    useAlert(t('SCHEDULING.KASSA.SUCCESS_EXPENSE'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const handlePayAll = async () => {
  try {
    await kassaStore.payAll();
    useAlert(t('SCHEDULING.KASSA.SUCCESS_PAY_ALL'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

onMounted(async () => {
  await loadPage();
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-y-auto bg-n-surface-1">
    <SchedulingPageHeader :title="$t('SCHEDULING.NAV.KASSA')">
      <template #actions>
        <Button
          v-if="kassaStore.activeTab === 'income'"
          size="sm"
          icon="i-lucide-plus"
          :label="$t('SCHEDULING.KASSA.ADD_PAYMENT')"
          @click="openPaymentDrawer"
        />
        <Button
          v-else
          size="sm"
          color="teal"
          :disabled="!unpaidExpenseCount"
          :label="$t('SCHEDULING.KASSA.PAY_ALL')"
          @click="handlePayAll"
        />
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-4 px-5 pb-5 pt-3">
      <div v-if="kassaStore.ui.isLoading" class="flex justify-center py-16">
        <Spinner class="!w-8 !h-8" />
      </div>

      <SchedulingErrorState
        v-else-if="kassaStore.ui.error"
        :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
        :description="kassaStore.ui.error.message"
        @retry="loadPage"
      />

      <template v-else>
        <SchedulingSectionCard>
          <div class="flex flex-col gap-5">
            <TabBar
              active-text-class="text-n-slate-12 scale-100"
              :tabs="tabOptions"
              :initial-active-tab="activeTabIndex"
              @tab-changed="kassaStore.setActiveTab($event.value)"
            />

            <div
              class="grid gap-4 xl:grid-cols-[180px_180px_minmax(0,280px)_auto]"
            >
              <SchedulingDateTimeField
                v-model="kassaStore.filters.from"
                type="date"
                :label="$t('SCHEDULING.KASSA.FROM')"
              />
              <SchedulingDateTimeField
                v-model="kassaStore.filters.to"
                type="date"
                :label="$t('SCHEDULING.KASSA.TO')"
              />
              <div class="flex flex-col gap-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('SCHEDULING.TOOLBAR.RESOURCES') }}
                </span>
                <SchedulingResourceFilter
                  :resources="referencesStore.resources"
                  :model-value="kassaStore.filters.resourceIds"
                  @update:model-value="
                    kassaStore.updateFilters({ resourceIds: $event })
                  "
                />
              </div>
              <div class="flex items-end">
                <Button
                  size="sm"
                  color="slate"
                  variant="faded"
                  :label="$t('SCHEDULING.KASSA.APPLY_FILTERS')"
                  @click="handleApplyFilters"
                />
              </div>
            </div>

            <div
              v-if="kassaStore.activeTab === 'income'"
              class="flex flex-col gap-4"
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class="text-xs font-semibold uppercase text-n-slate-10">
                  {{ $t('SCHEDULING.KASSA.PAYMENT_KIND') }}
                </span>
                <Button
                  size="sm"
                  variant="faded"
                  color="slate"
                  :label="$t('SCHEDULING.GENERAL.CLEAR')"
                  :disabled="!kassaStore.filters.paymentKinds.length"
                  @click="
                    kassaStore.updateFilters({ paymentKinds: [] });
                    handleApplyFilters();
                  "
                />
                <Button
                  v-for="option in paymentKindOptions"
                  :key="option.value"
                  size="sm"
                  :variant="
                    kassaStore.filters.paymentKinds.includes(option.value)
                      ? 'solid'
                      : 'faded'
                  "
                  :color="
                    kassaStore.filters.paymentKinds.includes(option.value)
                      ? 'blue'
                      : 'slate'
                  "
                  :label="option.label"
                  @click="toggleFilterValue('paymentKinds', option.value)"
                />
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <span class="text-xs font-semibold uppercase text-n-slate-10">
                  {{ $t('SCHEDULING.KASSA.PAYMENT_METHOD') }}
                </span>
                <Button
                  size="sm"
                  variant="faded"
                  color="slate"
                  :label="$t('SCHEDULING.GENERAL.CLEAR')"
                  :disabled="!kassaStore.filters.paymentMethods.length"
                  @click="
                    kassaStore.updateFilters({ paymentMethods: [] });
                    handleApplyFilters();
                  "
                />
                <Button
                  v-for="option in paymentMethodOptions"
                  :key="option.value"
                  size="sm"
                  :variant="
                    kassaStore.filters.paymentMethods.includes(option.value)
                      ? 'solid'
                      : 'faded'
                  "
                  :color="
                    kassaStore.filters.paymentMethods.includes(option.value)
                      ? 'blue'
                      : 'slate'
                  "
                  :label="option.label"
                  @click="toggleFilterValue('paymentMethods', option.value)"
                />
              </div>
            </div>

            <div v-else class="flex flex-wrap items-center gap-2">
              <span class="text-xs font-semibold uppercase text-n-slate-10">
                {{ $t('SCHEDULING.GENERAL.STATUS') }}
              </span>
              <Button
                size="sm"
                variant="faded"
                color="slate"
                :label="$t('SCHEDULING.GENERAL.CLEAR')"
                :disabled="!kassaStore.filters.status.length"
                @click="
                  kassaStore.updateFilters({ status: [] });
                  handleApplyFilters();
                "
              />
              <Button
                v-for="option in expenseStatusOptions"
                :key="option.value"
                size="sm"
                :variant="
                  kassaStore.filters.status.includes(option.value)
                    ? 'solid'
                    : 'faded'
                "
                :color="
                  kassaStore.filters.status.includes(option.value)
                    ? 'blue'
                    : 'slate'
                "
                :label="option.label"
                @click="toggleFilterValue('status', option.value)"
              />
            </div>
          </div>
        </SchedulingSectionCard>

        <div class="grid gap-4 md:grid-cols-3">
          <SchedulingSectionCard
            :title="$t('SCHEDULING.KASSA.TOTAL_INCOME')"
            :description="$t('SCHEDULING.KASSA.TOTAL_INCOME_DESCRIPTION')"
          >
            <p class="mb-0 text-2xl font-semibold text-n-slate-12">
              {{ formatCurrency(totals.totalIncome) }}
            </p>
          </SchedulingSectionCard>

          <SchedulingSectionCard
            :title="$t('SCHEDULING.KASSA.TOTAL_UNPAID')"
            :description="$t('SCHEDULING.KASSA.TOTAL_UNPAID_DESCRIPTION')"
          >
            <p class="mb-0 text-2xl font-semibold text-n-ruby-11">
              {{ formatCurrency(totals.unpaidExpenses) }}
            </p>
          </SchedulingSectionCard>

          <SchedulingSectionCard
            :title="$t('SCHEDULING.KASSA.TOTAL_PAID')"
            :description="$t('SCHEDULING.KASSA.TOTAL_PAID_DESCRIPTION')"
          >
            <p class="mb-0 text-2xl font-semibold text-n-teal-11">
              {{ formatCurrency(totals.paidExpenses) }}
            </p>
          </SchedulingSectionCard>
        </div>

        <SchedulingSectionCard
          v-if="kassaStore.activeTab === 'income'"
          :title="$t('SCHEDULING.KASSA.INCOME_TITLE')"
          :description="$t('SCHEDULING.KASSA.INCOME_DESCRIPTION')"
        >
          <SchedulingEmptyState
            v-if="paymentRows.length === 0"
            icon="i-lucide-wallet-cards"
            :title="$t('SCHEDULING.KASSA.EMPTY_INCOME_TITLE')"
            :description="$t('SCHEDULING.KASSA.EMPTY_INCOME_DESCRIPTION')"
            :action-label="$t('SCHEDULING.KASSA.ADD_PAYMENT')"
            @action="openPaymentDrawer"
          />

          <SchedulingRecordTable
            v-else
            :columns="paymentColumns"
            :rows="paymentRows"
          >
            <template #cell-createdAt="{ row }">
              {{ formatDateTime(row.createdAt) }}
            </template>

            <template #cell-appointment="{ row }">
              <div class="flex flex-col gap-1 min-w-0">
                <span class="font-medium text-n-slate-12">
                  {{ appointmentLabel(row.appointment) }}
                </span>
                <span class="text-xs text-n-slate-10">
                  {{ formatDateTime(row.appointment?.startsAt) }}
                </span>
              </div>
            </template>

            <template #cell-resource="{ row }">
              {{ resourceName(row.appointment?.resourceId) }}
            </template>

            <template #cell-paymentKind="{ row }">
              {{ paymentKindLabel(row.paymentKind) }}
            </template>

            <template #cell-paymentMethod="{ row }">
              {{ paymentMethodLabel(row.paymentMethod) }}
            </template>

            <template #cell-amount="{ row }">
              {{ formatCurrency(row.amount) }}
            </template>

            <template #cell-actions="{ row }">
              <div class="flex justify-end">
                <Button
                  size="sm"
                  variant="ghost"
                  color="ruby"
                  :disabled="!row.appointmentId"
                  :label="$t('SCHEDULING.KASSA.CANCEL_PAYMENTS')"
                  @click="handleCancelPayments(row.appointmentId)"
                />
              </div>
            </template>
          </SchedulingRecordTable>
        </SchedulingSectionCard>

        <SchedulingSectionCard
          v-else
          :title="$t('SCHEDULING.KASSA.EXPENSES_TITLE')"
          :description="$t('SCHEDULING.KASSA.EXPENSES_DESCRIPTION')"
        >
          <template #headerActions>
            <Button
              size="sm"
              color="teal"
              :disabled="!unpaidExpenseCount"
              :label="$t('SCHEDULING.KASSA.PAY_ALL')"
              @click="handlePayAll"
            />
          </template>

          <SchedulingEmptyState
            v-if="expenseRows.length === 0"
            icon="i-lucide-badge-dollar-sign"
            :title="$t('SCHEDULING.KASSA.EMPTY_EXPENSES_TITLE')"
            :description="$t('SCHEDULING.KASSA.EMPTY_EXPENSES_DESCRIPTION')"
          />

          <SchedulingRecordTable
            v-else
            :columns="expenseColumns"
            :rows="expenseRows"
          >
            <template #cell-appointment="{ row }">
              <div class="flex flex-col gap-1 min-w-0">
                <span class="font-medium text-n-slate-12">
                  {{ appointmentLabel(row.appointment) }}
                </span>
                <span class="text-xs text-n-slate-10">
                  {{ formatDateTime(row.appointment?.startsAt) }}
                </span>
              </div>
            </template>

            <template #cell-resource="{ row }">
              {{ resourceName(row.resourceId) }}
            </template>

            <template #cell-status="{ row }">
              {{ expenseStatusLabel(row.status) }}
            </template>

            <template #cell-paidAt="{ row }">
              {{ formatDateTime(row.paidAt) }}
            </template>

            <template #cell-amount="{ row }">
              {{ formatCurrency(row.amount) }}
            </template>

            <template #cell-actions="{ row }">
              <div class="flex justify-end">
                <Button
                  size="sm"
                  color="teal"
                  variant="ghost"
                  :disabled="row.status === 'paid'"
                  :label="
                    row.status === 'paid'
                      ? $t('SCHEDULING.KASSA.ALREADY_PAID')
                      : $t('SCHEDULING.KASSA.PAY_EXPENSE')
                  "
                  @click="handlePayExpense(row.id)"
                />
              </div>
            </template>
          </SchedulingRecordTable>
        </SchedulingSectionCard>
      </template>
    </div>

    <SchedulingDrawer
      v-model="paymentDrawerOpen"
      width="md"
      :title="$t('SCHEDULING.KASSA.ADD_PAYMENT_TITLE')"
      :confirm-label="$t('SCHEDULING.KASSA.ADD_PAYMENT')"
      :is-loading="kassaStore.ui.isSaving"
      :disable-confirm="!hasPaymentFormValues"
      @close="closePaymentDrawer"
      @confirm="handleAddPayment"
    >
      <SchedulingFormFieldGroup
        :title="$t('SCHEDULING.KASSA.PAYMENT_FORM_TITLE')"
        :description="$t('SCHEDULING.KASSA.PAYMENT_FORM_DESCRIPTION')"
      >
        <SchedulingSelectField
          :model-value="paymentForm.appointmentId"
          :options="appointmentOptions"
          :placeholder="$t('SCHEDULING.KASSA.APPOINTMENT')"
          @update:model-value="paymentForm.appointmentId = $event"
        />
        <div class="grid gap-4 md:grid-cols-2">
          <SchedulingMoneyInput
            v-model="paymentForm.amount"
            min="0"
            :label="$t('SCHEDULING.GENERAL.AMOUNT')"
          />
          <SchedulingSelectField
            :model-value="paymentForm.paymentMethod"
            :options="paymentMethodOptions"
            :placeholder="$t('SCHEDULING.KASSA.PAYMENT_METHOD')"
            @update:model-value="paymentForm.paymentMethod = $event"
          />
        </div>
      </SchedulingFormFieldGroup>
    </SchedulingDrawer>
  </section>
</template>
