<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useDebounceFn } from '@vueuse/core';
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
import SchedulingMultiSelectFilter from 'dashboard/components-next/Scheduling/SchedulingMultiSelectFilter.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingResourceFilter from 'dashboard/components-next/Scheduling/SchedulingResourceFilter.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingSectionCard from 'dashboard/components-next/Scheduling/SchedulingSectionCard.vue';
import PaymentActionButton from 'dashboard/components/widgets/PaymentActionButton.vue';
import {
  EXPENSE_STATUS_VALUES,
  PAYMENT_KIND_VALUES,
  PAYMENT_METHOD_VALUES,
} from '../constants';
import {
  formatSchedulingErrorMessage,
  toIntegerNumeric,
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
const paymentDrawerAppointmentId = ref(null);
const cancelActionAppointmentId = ref(null);
const paymentForm = reactive({
  amount: '',
  appointmentId: '',
  paymentMethod: 'cash',
});

const tabOptions = computed(() => [
  { label: t('SCHEDULING.KASSA.INCOME_TAB'), value: 'income' },
  { label: t('SCHEDULING.KASSA.EXPENSES_TAB'), value: 'expenses' },
]);
const incomeSection = ref('appointments');
const incomeSectionTabOptions = computed(() => [
  {
    label: t('SCHEDULING.KASSA.APPOINTMENTS_TAB'),
    value: 'appointments',
  },
  { label: t('SCHEDULING.KASSA.JOURNAL_TAB'), value: 'journal' },
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

const paymentStatusLabels = computed(() => ({
  awaiting_payment: t('SCHEDULING.PAYMENT_STATUS.awaiting_payment'),
  cancelled: t('SCHEDULING.PAYMENT_STATUS.cancelled'),
  paid: t('SCHEDULING.PAYMENT_STATUS.paid'),
  prepaid: t('SCHEDULING.PAYMENT_STATUS.prepaid'),
}));

const expenseStatusLabels = computed(() => ({
  paid: t('SCHEDULING.KASSA.EXPENSE_STATUS.paid'),
  unpaid: t('SCHEDULING.KASSA.EXPENSE_STATUS.unpaid'),
}));

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

const formatErrorMessage = error => formatSchedulingErrorMessage(error, t);

const pageErrorDescription = computed(() =>
  formatErrorMessage(kassaStore.ui.error)
);

const paymentKindLabel = kind => paymentKindLabels.value[kind] || kind;
const paymentMethodLabel = method =>
  paymentMethodLabels.value[method] || method;
const paymentStatusLabel = status =>
  paymentStatusLabels.value[status] || status || '—';
const expenseStatusLabel = status =>
  expenseStatusLabels.value[status] || status;

const paymentRows = computed(() => kassaStore.decoratedPayments);
const expenseRows = computed(() => kassaStore.decoratedExpenses);
const incomeAppointments = computed(() => {
  return [...kassaStore.appointmentCandidates]
    .sort((left, right) => new Date(left.startsAt) - new Date(right.startsAt))
    .map(appointment => {
      const paymentsJournal = [...(appointment.payments || [])].sort(
        (left, right) => new Date(right.createdAt) - new Date(left.createdAt)
      );
      const receivedAmount =
        appointment.paymentStatus === 'cancelled'
          ? 0
          : Number(appointment.prepaidAmount || 0) +
            Number(appointment.settlementAmount || 0);

      return {
        ...appointment,
        paymentTotal: paymentsJournal.reduce((sum, payment) => {
          return sum + Number(payment.amount || 0);
        }, 0),
        paymentsJournal,
        receivedAmount,
        remainingAmount: Math.max(
          Number(appointment.serviceAmount || 0) - receivedAmount,
          0
        ),
      };
    })
    .filter(appointment => appointment.remainingAmount > 0);
});
const appointmentOptions = computed(() =>
  incomeAppointments.value.map(appointment => ({
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
const activeIncomeSectionIndex = computed(() =>
  incomeSection.value === 'appointments' ? 0 : 1
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

const paymentStatusBadgeClass = status => {
  if (status === 'paid') {
    return 'bg-n-teal-9/10 text-n-teal-11';
  }

  if (status === 'prepaid') {
    return 'bg-n-brand/10 text-n-brand';
  }

  if (status === 'cancelled') {
    return 'bg-n-ruby-9/10 text-n-ruby-11';
  }

  return 'bg-n-amber-9/10 text-n-amber-11';
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

const defaultPaymentMethodForAppointment = appointment => {
  return (
    appointment?.settlementPaymentMethod ||
    appointment?.prepaidPaymentMethod ||
    'cash'
  );
};

const selectedPaymentAppointment = computed(() => {
  return (
    kassaStore.appointmentCandidates.find(appointment => {
      return Number(appointment.id) === Number(paymentForm.appointmentId);
    }) || null
  );
});

const selectedPaymentAppointmentDetails = computed(() => {
  return (
    incomeAppointments.value.find(appointment => {
      return Number(appointment.id) === Number(paymentForm.appointmentId);
    }) || null
  );
});

const lockedPaymentAppointment = computed(() => {
  return (
    Number(paymentDrawerAppointmentId.value) > 0 &&
    Number(selectedPaymentAppointment.value?.id) ===
      Number(paymentDrawerAppointmentId.value)
  );
});

const applyAppointmentToPaymentForm = appointment => {
  if (!appointment) {
    paymentForm.appointmentId = '';
    paymentForm.amount = '';
    paymentForm.paymentMethod = 'cash';
    return;
  }

  paymentForm.appointmentId = appointment.id;
  paymentForm.amount =
    appointment.remainingAmount > 0 ? String(appointment.remainingAmount) : '';
  paymentForm.paymentMethod = defaultPaymentMethodForAppointment(appointment);
};

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
  paymentDrawerAppointmentId.value = null;
  paymentDrawerOpen.value = true;
};

const openAppointmentPaymentDrawer = appointment => {
  resetPaymentForm();
  paymentDrawerAppointmentId.value = appointment.id;
  applyAppointmentToPaymentForm(appointment);
  paymentDrawerOpen.value = true;
};

const closePaymentDrawer = () => {
  paymentDrawerOpen.value = false;
  paymentDrawerAppointmentId.value = null;
  resetPaymentForm();
};

const handlePaymentAppointmentChange = appointmentId => {
  paymentForm.appointmentId = appointmentId;

  const appointment = incomeAppointments.value.find(item => {
    return Number(item.id) === Number(appointmentId);
  });

  if (!appointment) return;

  applyAppointmentToPaymentForm(appointment);
};

const reloadWithCurrentFilters = useDebounceFn(async () => {
  try {
    await kassaStore.loadAll();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
}, 150);

const handleFilterUpdate = patch => {
  kassaStore.updateFilters(patch);
  reloadWithCurrentFilters();
};

const handleAddPayment = async () => {
  try {
    await kassaStore.addPayment({
      amount: toIntegerNumeric(paymentForm.amount, 'amount'),
      appointmentId: toNumeric(paymentForm.appointmentId),
      paymentMethod: paymentForm.paymentMethod,
    });
    useAlert(t('SCHEDULING.KASSA.SUCCESS_PAYMENT'));
    closePaymentDrawer();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const handleCancelPayments = async appointmentId => {
  cancelActionAppointmentId.value = appointmentId;

  try {
    await kassaStore.cancelPayments(appointmentId);
    useAlert(t('SCHEDULING.KASSA.SUCCESS_CANCEL'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    cancelActionAppointmentId.value = null;
  }
};

const handlePayExpense = async expenseId => {
  try {
    await kassaStore.payExpense(expenseId);
    useAlert(t('SCHEDULING.KASSA.SUCCESS_EXPENSE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const handlePayAll = async () => {
  try {
    await kassaStore.payAll();
    useAlert(t('SCHEDULING.KASSA.SUCCESS_PAY_ALL'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
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
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-4 px-5 pb-5 pt-3">
      <div v-if="kassaStore.ui.isLoading" class="flex justify-center py-16">
        <Spinner class="!w-8 !h-8" />
      </div>

      <SchedulingErrorState
        v-else-if="kassaStore.ui.error"
        :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
        :description="pageErrorDescription"
        @retry="loadPage"
      />

      <template v-else>
        <div class="grid gap-4 md:grid-cols-3">
          <div class="rounded-2xl bg-n-alpha-black2 px-5 py-4">
            <p class="mb-1 text-base font-semibold text-n-slate-12">
              {{ $t('SCHEDULING.KASSA.TOTAL_INCOME') }}
            </p>
            <p class="mb-3 text-xs text-n-slate-11">
              {{ $t('SCHEDULING.KASSA.TOTAL_INCOME_DESCRIPTION') }}
            </p>
            <p class="mb-0 text-2xl font-semibold text-n-slate-12">
              {{ formatCurrency(totals.totalIncome) }}
            </p>
          </div>

          <div class="rounded-2xl bg-n-alpha-black2 px-5 py-4">
            <p class="mb-1 text-base font-semibold text-n-slate-12">
              {{ $t('SCHEDULING.KASSA.TOTAL_UNPAID') }}
            </p>
            <p class="mb-3 text-xs text-n-slate-11">
              {{ $t('SCHEDULING.KASSA.TOTAL_UNPAID_DESCRIPTION') }}
            </p>
            <p class="mb-0 text-2xl font-semibold text-n-ruby-11">
              {{ formatCurrency(totals.unpaidExpenses) }}
            </p>
          </div>

          <div class="rounded-2xl bg-n-alpha-black2 px-5 py-4">
            <p class="mb-1 text-base font-semibold text-n-slate-12">
              {{ $t('SCHEDULING.KASSA.TOTAL_PAID') }}
            </p>
            <p class="mb-3 text-xs text-n-slate-11">
              {{ $t('SCHEDULING.KASSA.TOTAL_PAID_DESCRIPTION') }}
            </p>
            <p class="mb-0 text-2xl font-semibold text-n-teal-11">
              {{ formatCurrency(totals.paidExpenses) }}
            </p>
          </div>
        </div>

        <SchedulingSectionCard>
          <div class="flex flex-col gap-4">
            <TabBar
              active-text-class="text-n-slate-12 scale-100"
              :tabs="tabOptions"
              :initial-active-tab="activeTabIndex"
              @tab-changed="kassaStore.setActiveTab($event.value)"
            />

            <div class="flex flex-wrap items-end justify-start gap-3">
              <div class="w-[170px] max-w-full flex-none">
                <SchedulingDateTimeField
                  :model-value="kassaStore.filters.from"
                  type="date"
                  :label="$t('SCHEDULING.KASSA.FROM')"
                  @update:model-value="handleFilterUpdate({ from: $event })"
                />
              </div>

              <div class="w-[170px] max-w-full flex-none">
                <SchedulingDateTimeField
                  :model-value="kassaStore.filters.to"
                  type="date"
                  :label="$t('SCHEDULING.KASSA.TO')"
                  @update:model-value="handleFilterUpdate({ to: $event })"
                />
              </div>

              <div class="w-fit max-w-[240px] min-w-[180px] flex-none">
                <div class="flex flex-col gap-1">
                  <span class="text-sm font-medium text-n-slate-12">
                    {{ $t('SCHEDULING.TOOLBAR.RESOURCES') }}
                  </span>
                  <SchedulingResourceFilter
                    :resources="referencesStore.resources"
                    :model-value="kassaStore.filters.resourceIds"
                    @update:model-value="
                      handleFilterUpdate({ resourceIds: $event })
                    "
                  />
                </div>
              </div>

              <div
                v-if="kassaStore.activeTab === 'income'"
                class="w-fit max-w-[200px] min-w-[160px] flex-none"
              >
                <div class="flex flex-col gap-1">
                  <span class="text-sm font-medium text-n-slate-12">
                    {{ $t('SCHEDULING.KASSA.PAYMENT_KIND') }}
                  </span>
                  <SchedulingMultiSelectFilter
                    :model-value="kassaStore.filters.paymentKinds"
                    :options="paymentKindOptions"
                    :placeholder="$t('SCHEDULING.KASSA.PAYMENT_KIND')"
                    :show-trigger-icon="false"
                    @update:model-value="
                      handleFilterUpdate({ paymentKinds: $event })
                    "
                  />
                </div>
              </div>

              <div
                v-if="kassaStore.activeTab === 'income'"
                class="w-fit max-w-[200px] min-w-[160px] flex-none"
              >
                <div class="flex flex-col gap-1">
                  <span class="text-sm font-medium text-n-slate-12">
                    {{ $t('SCHEDULING.KASSA.PAYMENT_METHOD') }}
                  </span>
                  <SchedulingMultiSelectFilter
                    :model-value="kassaStore.filters.paymentMethods"
                    :options="paymentMethodOptions"
                    :placeholder="$t('SCHEDULING.KASSA.PAYMENT_METHOD')"
                    :show-trigger-icon="false"
                    @update:model-value="
                      handleFilterUpdate({ paymentMethods: $event })
                    "
                  />
                </div>
              </div>

              <div v-else class="w-fit max-w-[200px] min-w-[160px] flex-none">
                <div class="flex flex-col gap-1">
                  <span class="text-sm font-medium text-n-slate-12">
                    {{ $t('SCHEDULING.GENERAL.STATUS') }}
                  </span>
                  <SchedulingMultiSelectFilter
                    :model-value="kassaStore.filters.status"
                    :options="expenseStatusOptions"
                    :placeholder="$t('SCHEDULING.GENERAL.STATUS')"
                    :show-trigger-icon="false"
                    @update:model-value="handleFilterUpdate({ status: $event })"
                  />
                </div>
              </div>
            </div>
          </div>
        </SchedulingSectionCard>

        <SchedulingSectionCard
          v-if="kassaStore.activeTab === 'income'"
          borderless
          :title="
            incomeSection === 'appointments'
              ? $t('SCHEDULING.KASSA.APPOINTMENTS_TITLE')
              : $t('SCHEDULING.KASSA.INCOME_TITLE')
          "
          :description="
            incomeSection === 'appointments'
              ? $t('SCHEDULING.KASSA.APPOINTMENTS_DESCRIPTION')
              : $t('SCHEDULING.KASSA.INCOME_DESCRIPTION')
          "
        >
          <template #headerActions>
            <TabBar
              active-text-class="text-n-slate-12 scale-100"
              :tabs="incomeSectionTabOptions"
              :initial-active-tab="activeIncomeSectionIndex"
              @tab-changed="incomeSection = $event.value"
            />
          </template>

          <template v-if="incomeSection === 'appointments'">
            <SchedulingEmptyState
              v-if="incomeAppointments.length === 0"
              icon="i-lucide-wallet-cards"
              :title="$t('SCHEDULING.KASSA.EMPTY_APPOINTMENTS_TITLE')"
              :description="
                $t('SCHEDULING.KASSA.EMPTY_APPOINTMENTS_DESCRIPTION')
              "
              :action-label="$t('SCHEDULING.KASSA.ADD_PAYMENT')"
              @action="openPaymentDrawer"
            />

            <div v-else class="flex flex-col gap-3">
              <div
                v-for="appointment in incomeAppointments"
                :key="appointment.id"
                class="rounded-2xl bg-n-alpha-black2 px-4 py-4"
              >
                <div class="flex flex-col gap-4">
                  <div
                    class="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between"
                  >
                    <div class="min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <span
                          class="truncate text-base font-semibold text-n-slate-12"
                        >
                          {{ appointment.clientName || `#${appointment.id}` }}
                        </span>
                        <span
                          class="rounded-full px-2 py-1 text-[11px] font-medium"
                          :class="
                            paymentStatusBadgeClass(appointment.paymentStatus)
                          "
                        >
                          {{ paymentStatusLabel(appointment.paymentStatus) }}
                        </span>
                      </div>

                      <div
                        class="mt-1 flex flex-wrap items-center gap-2 text-sm text-n-slate-11"
                      >
                        <span>{{ resourceName(appointment.resourceId) }}</span>
                        <span
                          class="inline-block size-1 rounded-full bg-n-slate-8"
                          aria-hidden="true"
                        />
                        <span>
                          {{
                            appointment.serviceNameSnapshot ||
                            $t('SCHEDULING.CALENDAR.NO_SERVICE')
                          }}
                        </span>
                        <span
                          class="inline-block size-1 rounded-full bg-n-slate-8"
                          aria-hidden="true"
                        />
                        <span>{{ formatDateTime(appointment.startsAt) }}</span>
                      </div>
                    </div>

                    <div class="grid gap-2 sm:grid-cols-3 xl:min-w-[420px]">
                      <div class="rounded-xl bg-n-surface-1/80 px-3 py-2">
                        <p
                          class="mb-1 text-[11px] font-medium uppercase tracking-[0.08em] text-n-slate-10"
                        >
                          {{ $t('SCHEDULING.KASSA.SERVICE_AMOUNT') }}
                        </p>
                        <p class="mb-0 text-sm font-semibold text-n-slate-12">
                          {{ formatCurrency(appointment.serviceAmount) }}
                        </p>
                      </div>

                      <div class="rounded-xl bg-n-teal-9/10 px-3 py-2">
                        <p
                          class="mb-1 text-[11px] font-medium uppercase tracking-[0.08em] text-n-teal-11"
                        >
                          {{ $t('SCHEDULING.KASSA.RECEIVED_AMOUNT') }}
                        </p>
                        <p class="mb-0 text-sm font-semibold text-n-teal-12">
                          {{ formatCurrency(appointment.receivedAmount) }}
                        </p>
                      </div>

                      <div class="rounded-xl bg-n-amber-9/10 px-3 py-2">
                        <p
                          class="mb-1 text-[11px] font-medium uppercase tracking-[0.08em] text-n-amber-11"
                        >
                          {{ $t('SCHEDULING.KASSA.REMAINING_AMOUNT') }}
                        </p>
                        <p class="mb-0 text-sm font-semibold text-n-amber-12">
                          {{ formatCurrency(appointment.remainingAmount) }}
                        </p>
                      </div>
                    </div>
                  </div>

                  <details
                    v-if="appointment.paymentsJournal.length"
                    class="rounded-xl bg-n-surface-1/65 px-3 py-2"
                  >
                    <summary
                      class="flex cursor-pointer list-none items-center justify-between gap-2 [&::-webkit-details-marker]:hidden"
                    >
                      <div
                        class="flex min-w-0 items-center gap-2 text-xs text-n-slate-11"
                      >
                        <span class="font-medium text-n-slate-12">
                          {{ $t('SCHEDULING.KASSA.PAYMENT_JOURNAL') }}
                        </span>
                        <span>
                          {{
                            $t('SCHEDULING.GENERAL.SELECTED_COUNT', {
                              count: appointment.paymentsJournal.length,
                            })
                          }}
                        </span>
                        <span
                          class="inline-block size-1 rounded-full bg-n-slate-8"
                          aria-hidden="true"
                        />
                        <span>{{
                          formatCurrency(appointment.paymentTotal)
                        }}</span>
                      </div>
                      <span
                        class="size-4 shrink-0 text-n-slate-10 i-lucide-chevron-down"
                        aria-hidden="true"
                      />
                    </summary>

                    <div class="mt-2 flex flex-col gap-2">
                      <div
                        v-for="payment in appointment.paymentsJournal"
                        :key="payment.id"
                        class="flex flex-col gap-2 rounded-xl bg-n-surface-1/80 px-3 py-2 text-xs text-n-slate-11 md:flex-row md:items-center md:justify-between"
                      >
                        <div class="flex flex-wrap items-center gap-2">
                          <span
                            class="rounded-full bg-n-alpha-black2 px-2 py-1 font-medium text-n-slate-12"
                          >
                            {{ paymentKindLabel(payment.paymentKind) }}
                          </span>
                          <span class="font-semibold text-n-slate-12">
                            {{ formatCurrency(payment.amount) }}
                          </span>
                          <span>{{
                            paymentMethodLabel(payment.paymentMethod)
                          }}</span>
                        </div>
                        <span>{{ formatDateTime(payment.createdAt) }}</span>
                      </div>
                    </div>
                  </details>

                  <div
                    class="flex flex-col gap-2 pt-1 sm:flex-row sm:items-center sm:justify-end"
                  >
                    <Button
                      size="sm"
                      :label="$t('SCHEDULING.KASSA.PAY_APPOINTMENT')"
                      @click="openAppointmentPaymentDrawer(appointment)"
                    />

                    <PaymentActionButton
                      :appointment-id="Number(appointment.id)"
                      :default-amount="appointment.remainingAmount"
                      :require-amount-input="false"
                      delivery-mode="copy"
                      :label="$t('SCHEDULING.KASSA.KASPI_PAYMENT_LINK')"
                    />

                    <Button
                      v-if="
                        appointment.receivedAmount > 0 &&
                        appointment.paymentStatus !== 'cancelled'
                      "
                      size="sm"
                      variant="ghost"
                      color="ruby"
                      :disabled="kassaStore.ui.isSaving"
                      :label="
                        cancelActionAppointmentId === appointment.id
                          ? $t('SCHEDULING.KASSA.CANCELLING_PAYMENTS')
                          : $t('SCHEDULING.KASSA.CANCEL_PAYMENTS')
                      "
                      @click="handleCancelPayments(appointment.id)"
                    />
                  </div>
                </div>
              </div>
            </div>
          </template>

          <SchedulingEmptyState
            v-else-if="paymentRows.length === 0"
            icon="i-lucide-wallet-cards"
            :title="$t('SCHEDULING.KASSA.EMPTY_INCOME_TITLE')"
            :description="$t('SCHEDULING.KASSA.EMPTY_INCOME_DESCRIPTION')"
            :action-label="$t('SCHEDULING.KASSA.ADD_PAYMENT')"
            @action="openPaymentDrawer"
          />

          <SchedulingRecordTable
            v-else
            borderless
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
                  :disabled="!row.appointmentId || kassaStore.ui.isSaving"
                  :label="
                    cancelActionAppointmentId === row.appointmentId
                      ? $t('SCHEDULING.KASSA.CANCELLING_PAYMENTS')
                      : $t('SCHEDULING.KASSA.CANCEL_PAYMENTS')
                  "
                  @click="handleCancelPayments(row.appointmentId)"
                />
              </div>
            </template>
          </SchedulingRecordTable>
        </SchedulingSectionCard>

        <SchedulingSectionCard
          v-else
          borderless
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
            borderless
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
        <div
          v-if="lockedPaymentAppointment && selectedPaymentAppointment"
          class="rounded-2xl bg-n-alpha-black2 px-4 py-3"
        >
          <p class="mb-1 text-sm font-semibold text-n-slate-12">
            {{ appointmentLabel(selectedPaymentAppointment) }}
          </p>
          <p class="mb-0 text-xs text-n-slate-11">
            {{ formatDateTime(selectedPaymentAppointment.startsAt) }}
            <span
              class="mx-1 inline-block size-1 rounded-full bg-n-slate-8"
              aria-hidden="true"
            />
            {{ resourceName(selectedPaymentAppointment.resourceId) }}
          </p>
          <p class="mb-0 mt-3 text-sm font-medium text-n-amber-11">
            {{ $t('SCHEDULING.KASSA.REMAINING_AMOUNT') }}
            {{
              formatCurrency(
                selectedPaymentAppointmentDetails?.remainingAmount || 0
              )
            }}
          </p>
        </div>

        <SchedulingSelectField
          v-else
          :model-value="paymentForm.appointmentId"
          :options="appointmentOptions"
          :placeholder="$t('SCHEDULING.KASSA.APPOINTMENT')"
          @update:model-value="handlePaymentAppointmentChange"
        />
        <div class="grid gap-4 md:grid-cols-2">
          <SchedulingMoneyInput
            v-model="paymentForm.amount"
            min="0"
            :label="$t('SCHEDULING.GENERAL.AMOUNT')"
          />
          <SchedulingSelectField
            :label="$t('SCHEDULING.KASSA.PAYMENT_METHOD')"
            :model-value="paymentForm.paymentMethod"
            :options="paymentMethodOptions"
            :placeholder="$t('SCHEDULING.KASSA.PAYMENT_METHOD')"
            @update:model-value="paymentForm.paymentMethod = $event"
          />
        </div>
        <div class="flex justify-end">
          <PaymentActionButton
            v-if="paymentForm.appointmentId"
            :appointment-id="Number(paymentForm.appointmentId)"
            :default-amount="
              selectedPaymentAppointmentDetails?.remainingAmount ||
              paymentForm.amount
            "
            :require-amount-input="false"
            delivery-mode="copy"
            :label="$t('SCHEDULING.KASSA.KASPI_PAYMENT_LINK')"
          />
        </div>
      </SchedulingFormFieldGroup>
    </SchedulingDrawer>
  </section>
</template>
