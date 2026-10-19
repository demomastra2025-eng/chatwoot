<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import WhatsappUsageAPI from 'dashboard/api/whatsappUsage';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import ReportHeader from './components/ReportHeader.vue';

const { t, locale } = useI18n();
const route = useRoute();
const accountId = computed(() => Number(route.params.accountId || 0));

const usage = ref(null);
const loading = ref(false);
const hasError = ref(false);
let generation = 0;

const formatLocale = computed(() =>
  String(locale.value || 'ru').replace(/_/g, '-')
);

const toFiniteNumber = value => {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && value.trim() === '') return null;
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
};

const formatCount = value => {
  const count = toFiniteNumber(value);
  if (count === null) return t('WHATSAPP_USAGE.COUNT_UNAVAILABLE');
  return new Intl.NumberFormat(formatLocale.value, {
    maximumFractionDigits: 0,
  }).format(count);
};

const formatKzt = value => {
  const amount = toFiniteNumber(value);
  if (amount === null) return t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE');
  return new Intl.NumberFormat(formatLocale.value, {
    style: 'currency',
    currency: 'KZT',
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  }).format(amount);
};

const formatUsd = value => {
  const amount = toFiniteNumber(value);
  if (amount === null) return '—';
  return new Intl.NumberFormat(formatLocale.value, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount);
};

const formattedRate = computed(() => {
  const rate = toFiniteNumber(usage.value?.exchange_rate?.rate_per_usd);
  if (rate === null) return t('WHATSAPP_USAGE.RATE_UNAVAILABLE');
  return new Intl.NumberFormat(formatLocale.value, {
    maximumFractionDigits: 2,
  }).format(rate);
});

const categoryDefinitions = [
  { category: 'service', labelKey: 'WHATSAPP_USAGE.CATEGORY_SERVICE' },
  { category: 'utility', labelKey: 'WHATSAPP_USAGE.CATEGORY_UTILITY' },
  { category: 'marketing', labelKey: 'WHATSAPP_USAGE.CATEGORY_MARKETING' },
  { category: 'authentication', labelKey: 'WHATSAPP_USAGE.CATEGORY_AUTH' },
  {
    category: 'authentication-international',
    labelKey: 'WHATSAPP_USAGE.CATEGORY_AUTH_INTERNATIONAL',
  },
  {
    category: 'referral_conversion',
    labelKey: 'WHATSAPP_USAGE.CATEGORY_REFERRAL_CONVERSION',
  },
];

const categoryRows = computed(() => {
  const rows = Array.isArray(usage.value?.category_breakdown)
    ? usage.value.category_breakdown
    : [];
  const map = new Map(rows.map(r => [r.category, r]));
  return categoryDefinitions
    .map(({ category, labelKey }) => {
      const row = map.get(category) || {};
      return {
        category,
        label: t(labelKey),
        deliveredCount: toFiniteNumber(row.delivered_count) || 0,
        chargeableCount: toFiniteNumber(row.chargeable_count) || 0,
        freeCount: toFiniteNumber(row.free_count) || 0,
      };
    })
    .filter(
      row =>
        ['service', 'utility', 'marketing'].includes(row.category) ||
        row.deliveredCount > 0
    );
});

const managers = computed(() =>
  Array.isArray(usage.value?.managers) ? usage.value.managers : []
);

const consecutiveSummary = computed(
  () => usage.value?.consecutive_summary || {}
);

const phones = computed(() =>
  Array.isArray(usage.value?.phones) ? usage.value.phones : []
);

const loadReport = async () => {
  if (!accountId.value) return;
  generation += 1;
  const currentGen = generation;
  loading.value = true;
  hasError.value = false;
  try {
    const response = await WhatsappUsageAPI.getMonthlyUsage(accountId.value);
    if (currentGen !== generation) return;
    usage.value = response?.data?.whatsapp_usage || null;
  } catch {
    if (currentGen !== generation) return;
    usage.value = null;
    hasError.value = true;
  } finally {
    if (currentGen === generation) loading.value = false;
  }
};

watch(
  accountId,
  () => {
    usage.value = null;
    loadReport();
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  generation += 1;
});
</script>

<template>
  <ReportHeader
    :header-title="t('WHATSAPP_USAGE.REPORT.TITLE')"
    :header-description="
      t('WHATSAPP_USAGE.REPORT.DESCRIPTION', {
        month: usage?.month || '—',
      })
    "
  >
    <Button
      icon="i-lucide-refresh-cw"
      :label="t('WHATSAPP_USAGE.REPORT.REFRESH')"
      size="sm"
      color="slate"
      variant="faded"
      :disabled="loading"
      @click="loadReport"
    />
  </ReportHeader>

  <div class="flex min-w-0 flex-col gap-5 pb-10">
    <div
      v-if="loading"
      role="status"
      class="flex items-center justify-center gap-2 py-16 text-sm text-n-slate-11"
    >
      <Spinner />
      {{ t('WHATSAPP_USAGE.REPORT.LOADING') }}
    </div>

    <div
      v-else-if="hasError"
      role="alert"
      class="flex items-center justify-between gap-3 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
    >
      <p class="m-0 text-sm text-n-slate-11">
        {{ t('WHATSAPP_USAGE.REPORT.ERROR') }}
      </p>
      <Button
        :label="t('WHATSAPP_USAGE.REPORT.RETRY')"
        size="sm"
        @click="loadReport"
      />
    </div>

    <template v-else-if="usage">
      <!-- KPI Cards -->
      <div
        class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4"
        data-testid="whatsapp-report-kpis"
      >
        <!-- Card 1: Total with VAT -->
        <div
          class="flex flex-col justify-between gap-2 rounded-xl bg-n-solid-2 p-5 shadow outline outline-1 outline-n-container"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="text-xs font-medium text-n-slate-11">
              {{ t('WHATSAPP_USAGE.REPORT.KPI_TOTAL_WITH_VAT') }}
            </span>
            <span
              class="rounded-full bg-n-teal-3 px-2 py-0.5 text-[11px] font-medium text-n-teal-11"
            >
              +{{ usage.vat_rate_percent || 12 }}% НДС
            </span>
          </div>
          <div
            class="text-2xl font-semibold tabular-nums text-n-slate-12"
            data-testid="whatsapp-report-amount-with-vat"
          >
            {{
              formatKzt(
                usage.estimated_amount_with_vat_kzt ??
                  usage.estimated_amount_kzt
              )
            }}
          </div>
          <p class="m-0 text-xs text-n-slate-10">
            {{
              t('WHATSAPP_USAGE.REPORT.KPI_BASE_BREAKDOWN', {
                baseKzt: formatKzt(usage.estimated_amount_kzt),
                usd: formatUsd(usage.estimated_amount_usd),
                rate: formattedRate,
              })
            }}
          </p>
        </div>

        <!-- Card 2: Total Delivered -->
        <div
          class="flex flex-col justify-between gap-2 rounded-xl bg-n-solid-2 p-5 shadow outline outline-1 outline-n-container"
        >
          <span class="text-xs font-medium text-n-slate-11">
            {{ t('WHATSAPP_USAGE.REPORT.KPI_DELIVERED') }}
          </span>
          <div
            class="text-2xl font-semibold tabular-nums text-n-slate-12"
            data-testid="whatsapp-report-delivered-count"
          >
            {{ formatCount(usage.delivered_count) }}
          </div>
          <p class="m-0 text-xs text-n-slate-10">
            {{
              t('WHATSAPP_USAGE.REPORT.KPI_DELIVERED_SUB', {
                paid: formatCount(usage.chargeable_message_count),
                service: formatCount(usage.service_delivered_count),
                templates: formatCount(usage.template_delivered_count),
              })
            }}
          </p>
        </div>

        <!-- Card 3: Free Service Allowance -->
        <div
          class="flex flex-col justify-between gap-2 rounded-xl bg-n-solid-2 p-5 shadow outline outline-1 outline-n-container"
        >
          <span class="text-xs font-medium text-n-slate-11">
            {{ t('WHATSAPP_USAGE.REPORT.KPI_FREE_QUOTA') }}
          </span>
          <div class="text-2xl font-semibold tabular-nums text-n-slate-12">
            {{ formatCount(usage.free_service_quota_count) }} /
            {{ formatCount(usage.free_service_quota_limit) }}
          </div>
          <p class="m-0 text-xs text-n-slate-10">
            {{
              t('WHATSAPP_USAGE.REPORT.KPI_FREE_QUOTA_SUB', {
                phones: formatCount(usage.official_cloud_phone_count),
                perPhone: formatCount(usage.free_service_quota_limit_per_phone),
              })
            }}
          </p>
        </div>

        <!-- Card 4: Consecutive / Double Messages Overpayment -->
        <div
          class="flex flex-col justify-between gap-2 rounded-xl bg-n-solid-2 p-5 shadow outline outline-1"
          :class="
            consecutiveSummary.chargeable_consecutive_count > 0
              ? 'outline-n-amber-6'
              : 'outline-n-container'
          "
          data-testid="whatsapp-report-consecutive-kpi"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="text-xs font-medium text-n-slate-11">
              {{ t('WHATSAPP_USAGE.REPORT.KPI_CONSECUTIVE_TITLE') }}
            </span>
            <span
              v-if="consecutiveSummary.consecutive_ratio_percent > 0"
              class="rounded-full bg-n-amber-3 px-2 py-0.5 text-[11px] font-semibold text-n-amber-11"
            >
              {{ consecutiveSummary.consecutive_ratio_percent }}%
            </span>
          </div>
          <div class="text-2xl font-semibold tabular-nums text-n-amber-11">
            {{
              formatKzt(
                consecutiveSummary.estimated_overpayment_with_vat_kzt ??
                  consecutiveSummary.estimated_overpayment_kzt ??
                  0
              )
            }}
          </div>
          <p class="m-0 text-xs text-n-slate-10">
            {{
              t('WHATSAPP_USAGE.REPORT.KPI_CONSECUTIVE_SUB', {
                total: formatCount(
                  consecutiveSummary.consecutive_service_count || 0
                ),
                paid: formatCount(
                  consecutiveSummary.chargeable_consecutive_count || 0
                ),
              })
            }}
          </p>
        </div>
      </div>

      <!-- Formula & Why Card Charges Are Higher Explanation -->
      <section
        class="rounded-xl bg-n-solid-2 px-5 py-4 shadow outline outline-1 outline-n-container"
        data-testid="whatsapp-report-formula-card"
      >
        <div class="flex items-start gap-3">
          <i
            class="i-lucide-calculator mt-0.5 size-4 shrink-0 text-n-teal-10"
            aria-hidden="true"
          />
          <div class="min-w-0 flex-1 text-xs leading-5 text-n-slate-11">
            <p class="m-0 font-semibold text-n-slate-12">
              {{ t('WHATSAPP_USAGE.REPORT.FORMULA_TITLE') }}
            </p>
            <p class="m-0 mt-1">
              {{ t('WHATSAPP_USAGE.REPORT.FORMULA_TEXT') }}
            </p>
          </div>
        </div>
      </section>

      <!-- Managers Table (Consecutive / Double Messages Breakdown) -->
      <section
        class="min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
        data-testid="whatsapp-report-managers"
      >
        <div
          class="flex flex-wrap items-center justify-between gap-2 border-b border-n-weak px-5 py-4"
        >
          <div>
            <h2 class="m-0 text-heading-2 text-n-slate-12">
              {{ t('WHATSAPP_USAGE.REPORT.MANAGERS_TITLE') }}
            </h2>
            <p class="m-0 mt-0.5 text-xs text-n-slate-10">
              {{ t('WHATSAPP_USAGE.REPORT.MANAGERS_SUBTITLE') }}
            </p>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="w-full text-left text-sm">
            <thead class="border-b border-n-weak text-xs text-n-slate-10">
              <tr>
                <th class="py-3 pl-5 pr-4 font-medium">
                  {{ t('WHATSAPP_USAGE.REPORT.COL_MANAGER') }}
                </th>
                <th class="px-3 py-3 text-right font-medium">
                  {{ t('WHATSAPP_USAGE.REPORT.COL_DELIVERED') }}
                </th>
                <th class="px-3 py-3 text-right font-medium">
                  {{ t('WHATSAPP_USAGE.REPORT.COL_PAID') }}
                </th>
                <th class="px-3 py-3 text-right font-medium">
                  {{ t('WHATSAPP_USAGE.REPORT.COL_CONSECUTIVE') }}
                </th>
                <th class="px-3 py-3 text-right font-medium">
                  {{ t('WHATSAPP_USAGE.REPORT.COL_CONSECUTIVE_RATIO') }}
                </th>
                <th class="px-3 py-3 text-right font-medium">
                  {{ t('WHATSAPP_USAGE.REPORT.COL_AMOUNT_WITH_VAT') }}
                </th>
                <th class="py-3 pl-3 pr-5 text-right font-medium">
                  {{ t('WHATSAPP_USAGE.REPORT.COL_OVERPAYMENT') }}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-n-weak">
              <tr
                v-for="manager in managers"
                :key="manager.user_id"
                class="text-n-slate-12 hover:bg-n-alpha-1"
                data-testid="whatsapp-report-manager-row"
              >
                <td class="py-3 pl-5 pr-4 font-medium">
                  {{ manager.name }}
                </td>
                <td class="px-3 py-3 text-right tabular-nums text-n-slate-11">
                  {{ formatCount(manager.delivered_count) }}
                </td>
                <td class="px-3 py-3 text-right tabular-nums text-n-slate-11">
                  {{ formatCount(manager.chargeable_count) }}
                </td>
                <td class="px-3 py-3 text-right tabular-nums">
                  <span class="font-medium text-n-slate-12">
                    {{ formatCount(manager.consecutive_count) }}
                  </span>
                  <span
                    v-if="manager.chargeable_consecutive_count > 0"
                    class="ml-1 text-xs text-n-slate-10"
                  >
                    ({{
                      t('WHATSAPP_USAGE.REPORT.PAID_SHORT', {
                        count: formatCount(
                          manager.chargeable_consecutive_count
                        ),
                      })
                    }})
                  </span>
                </td>
                <td class="px-3 py-3 text-right tabular-nums">
                  <span
                    class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium"
                    :class="
                      manager.consecutive_ratio_percent >= 25
                        ? 'bg-n-ruby-3 text-n-ruby-11'
                        : manager.consecutive_ratio_percent >= 15
                          ? 'bg-n-amber-3 text-n-amber-11'
                          : 'bg-n-alpha-2 text-n-slate-11'
                    "
                  >
                    {{ manager.consecutive_ratio_percent }}%
                  </span>
                </td>
                <td class="px-3 py-3 text-right tabular-nums text-n-slate-11">
                  {{
                    formatKzt(
                      manager.estimated_amount_with_vat_kzt ??
                        manager.estimated_amount_kzt
                    )
                  }}
                </td>
                <td
                  class="py-3 pl-3 pr-5 text-right font-medium tabular-nums"
                  :class="
                    manager.chargeable_consecutive_count > 0
                      ? 'text-n-amber-11'
                      : 'text-n-slate-10'
                  "
                >
                  {{
                    formatKzt(
                      manager.consecutive_overpayment_with_vat_kzt ??
                        manager.consecutive_overpayment_kzt
                    )
                  }}
                </td>
              </tr>
              <tr v-if="!managers.length">
                <td colspan="7" class="px-5 py-8 text-center text-n-slate-10">
                  {{ t('WHATSAPP_USAGE.REPORT.MANAGERS_EMPTY') }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- Categories & Phones Grid -->
      <div class="grid grid-cols-1 gap-5 xl:grid-cols-2">
        <!-- Categories Table -->
        <section
          class="min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
          data-testid="whatsapp-report-categories"
        >
          <h2
            class="m-0 border-b border-n-weak px-5 py-4 text-heading-2 text-n-slate-12"
          >
            {{ t('WHATSAPP_USAGE.REPORT.CATEGORIES_TITLE') }}
          </h2>
          <div class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-n-weak text-xs text-n-slate-10">
                <tr>
                  <th class="py-3 pl-5 pr-4 font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.COL_CATEGORY') }}
                  </th>
                  <th class="px-3 py-3 text-right font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.COL_DELIVERED') }}
                  </th>
                  <th class="px-3 py-3 text-right font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.COL_PAID') }}
                  </th>
                  <th class="py-3 pl-3 pr-5 text-right font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.COL_FREE') }}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak">
                <tr
                  v-for="row in categoryRows"
                  :key="row.category"
                  class="text-n-slate-11"
                >
                  <td class="py-3 pl-5 pr-4 font-medium text-n-slate-12">
                    {{ row.label }}
                  </td>
                  <td class="px-3 py-3 text-right tabular-nums">
                    {{ formatCount(row.deliveredCount) }}
                  </td>
                  <td class="px-3 py-3 text-right tabular-nums">
                    {{ formatCount(row.chargeableCount) }}
                  </td>
                  <td class="py-3 pl-3 pr-5 text-right tabular-nums">
                    {{ formatCount(row.freeCount) }}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <!-- Connected Phones Table -->
        <section
          class="min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
          data-testid="whatsapp-report-phones"
        >
          <h2
            class="m-0 border-b border-n-weak px-5 py-4 text-heading-2 text-n-slate-12"
          >
            {{ t('WHATSAPP_USAGE.REPORT.PHONES_TITLE') }}
          </h2>
          <div class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-n-weak text-xs text-n-slate-10">
                <tr>
                  <th class="py-3 pl-5 pr-4 font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.COL_PHONE') }}
                  </th>
                  <th class="px-3 py-3 text-right font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.COL_DELIVERED') }}
                  </th>
                  <th class="px-3 py-3 text-right font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.KPI_FREE_QUOTA') }}
                  </th>
                  <th class="py-3 pl-3 pr-5 text-right font-medium">
                    {{ t('WHATSAPP_USAGE.REPORT.COL_AMOUNT_WITH_VAT') }}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak">
                <tr
                  v-for="phone in phones"
                  :key="phone.phone_number"
                  class="text-n-slate-11"
                >
                  <td class="py-3 pl-5 pr-4 font-medium text-n-slate-12">
                    {{ phone.phone_number }}
                  </td>
                  <td class="px-3 py-3 text-right tabular-nums">
                    {{ formatCount(phone.delivered_count) }}
                  </td>
                  <td class="px-3 py-3 text-right tabular-nums">
                    {{ formatCount(phone.free_service_quota_count) }} /
                    {{ formatCount(phone.free_service_quota_limit) }}
                  </td>
                  <td class="py-3 pl-3 pr-5 text-right tabular-nums">
                    {{
                      formatKzt(
                        phone.estimated_amount_with_vat_kzt ??
                          phone.estimated_amount_kzt
                      )
                    }}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </template>
  </div>
</template>
