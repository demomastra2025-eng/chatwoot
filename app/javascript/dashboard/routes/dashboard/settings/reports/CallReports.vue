<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import ReportsAPI from 'dashboard/api/standaloneReports';
import Button from 'dashboard/components-next/button/Button.vue';
import { useAlert } from 'dashboard/composables';
import ReportHeader from './components/ReportHeader.vue';
import ReportMetricCard from './components/ReportMetricCard.vue';
import ReportDateRange from './components/ReportDateRange.vue';

const { t, te, locale } = useI18n();
const report = ref({});
const fromDate = ref('');
const toDate = ref('');
const timezone = ref('UTC');
const maxRangeDays = ref(90);
const isLoading = ref(false);
const hasError = ref(false);

const summary = computed(() => report.value.summary || {});
const dailyBreakdown = computed(() => report.value.daily_breakdown || []);
const rows = computed(() => report.value.rows || []);
const coverage = computed(() => report.value.coverage || {});

const numberFormatter = computed(() => new Intl.NumberFormat(locale.value));
const secondFormatter = computed(
  () =>
    new Intl.NumberFormat(locale.value, {
      maximumFractionDigits: 1,
      style: 'unit',
      unit: 'second',
      unitDisplay: 'short',
    })
);
const dateFormatter = computed(
  () =>
    new Intl.DateTimeFormat(locale.value, {
      day: 'numeric',
      month: 'short',
      timeZone: 'UTC',
      year: 'numeric',
    })
);
const dateTimeFormatter = computed(
  () =>
    new Intl.DateTimeFormat(locale.value, {
      dateStyle: 'medium',
      timeStyle: 'short',
      timeZone: timezone.value,
    })
);

const formatCount = value => numberFormatter.value.format(Number(value || 0));
const formatSeconds = value =>
  value === null || value === undefined
    ? '—'
    : secondFormatter.value.format(Number(value));
const formatDate = value =>
  dateFormatter.value.format(new Date(`${value}T12:00:00Z`));
const formatDateTime = value => dateTimeFormatter.value.format(new Date(value));
const statusLabel = status => {
  const key = `REPORTS.CALLS.STATUSES.${status}`;
  return status && te(key) ? t(key) : status || '—';
};
const metrics = computed(() => [
  {
    key: 'logical',
    label: t('REPORTS.CALLS.LOGICAL_CALLS'),
    value: formatCount(summary.value.logical_call_count),
    info: t('REPORTS.CALLS.LOGICAL_CALLS_INFO'),
  },
  {
    key: 'answered',
    label: t('REPORTS.CALLS.ANSWERED_CALLS'),
    value: formatCount(summary.value.answered_count),
    info: t('REPORTS.CALLS.ANSWERED_INFO'),
  },
  {
    key: 'unanswered',
    label: t('REPORTS.CALLS.UNANSWERED_CALLS'),
    value: formatCount(summary.value.unanswered_count),
    info: t('REPORTS.CALLS.UNANSWERED_INFO'),
  },
  {
    key: 'duration',
    label: t('REPORTS.CALLS.AVERAGE_DURATION'),
    value: formatSeconds(summary.value.average_answered_duration_seconds),
    info: t('REPORTS.CALLS.AVERAGE_DURATION_INFO'),
  },
]);

const loadReport = async (range = {}) => {
  isLoading.value = true;
  hasError.value = false;

  try {
    const response = await ReportsAPI.getCalls(range);
    report.value = response.data?.payload || {};
    const meta = response.data?.meta || {};
    fromDate.value = meta.from_date || range.fromDate || '';
    toDate.value = meta.to_date || range.toDate || '';
    timezone.value = meta.timezone || timezone.value;
    maxRangeDays.value = meta.max_range_days || maxRangeDays.value;
  } catch {
    report.value = {};
    hasError.value = true;
    useAlert(t('REPORTS.CALLS.ERROR'));
  } finally {
    isLoading.value = false;
  }
};

const applyRange = range => loadReport(range);

onMounted(() => loadReport());
</script>

<template>
  <ReportHeader
    :header-title="t('REPORTS.CALLS.TITLE')"
    :header-description="t('REPORTS.CALLS.DESCRIPTION')"
  />

  <div class="flex flex-col gap-4 pb-8">
    <ReportDateRange
      v-model:from-date="fromDate"
      v-model:to-date="toDate"
      :timezone="timezone"
      :max-range-days="maxRangeDays"
      :is-loading="isLoading"
      @apply="applyRange"
    />

    <div
      v-if="!isLoading && hasError"
      class="flex items-center justify-between gap-3 rounded-lg border border-n-weak bg-n-surface-1 p-3"
      role="alert"
    >
      <p class="m-0 text-sm text-n-slate-11">{{ t('REPORTS.CALLS.ERROR') }}</p>
      <Button
        size="sm"
        :label="t('REPORTS.DATE_RANGE.APPLY')"
        @click="loadReport({ fromDate, toDate })"
      />
    </div>

    <div
      v-if="!coverage.complete"
      class="rounded-lg border border-n-amber-6 bg-n-amber-2 px-3 py-2 text-sm text-n-amber-11"
      role="status"
    >
      {{
        t('REPORTS.CALLS.COVERAGE_LIMITED', {
          count: formatCount(coverage.sampled_calls),
          limit: formatCount(coverage.limit),
        })
      }}
    </div>

    <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
      <div
        v-for="metric in metrics"
        :key="metric.key"
        class="rounded-xl border border-n-weak bg-n-surface-1 p-3"
      >
        <ReportMetricCard
          :label="metric.label"
          :value="metric.value"
          :info-text="metric.info"
          :disabled="isLoading"
        />
      </div>
    </div>

    <section
      class="overflow-hidden rounded-xl border border-n-weak bg-n-surface-1"
    >
      <div class="border-b border-n-weak px-4 py-3">
        <h2 class="m-0 text-sm font-semibold text-n-slate-12">
          {{ t('REPORTS.CALLS.DAILY_TITLE') }}
        </h2>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[34rem] text-left text-sm">
          <thead class="bg-n-surface-2 text-xs text-n-slate-10">
            <tr>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.DATE') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.LOGICAL_CALLS') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.ANSWERED_CALLS') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.UNANSWERED_CALLS') }}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-n-weak">
            <tr
              v-for="day in dailyBreakdown"
              :key="day.date"
              class="text-n-slate-11"
            >
              <td class="px-4 py-2.5">{{ formatDate(day.date) }}</td>
              <td class="px-4 py-2.5">
                {{ formatCount(day.logical_call_count) }}
              </td>
              <td class="px-4 py-2.5">{{ formatCount(day.answered_count) }}</td>
              <td class="px-4 py-2.5">
                {{ formatCount(day.unanswered_count) }}
              </td>
            </tr>
            <tr v-if="!isLoading && !hasError && dailyBreakdown.length === 0">
              <td colspan="4" class="px-4 py-8 text-center text-n-slate-10">
                {{ t('REPORTS.CALLS.EMPTY') }}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section
      class="overflow-hidden rounded-xl border border-n-weak bg-n-surface-1"
    >
      <div class="border-b border-n-weak px-4 py-3">
        <h2 class="m-0 text-sm font-semibold text-n-slate-12">
          {{ t('REPORTS.CALLS.ROWS_TITLE') }}
        </h2>
        <p class="mb-0 mt-1 text-xs text-n-slate-10">
          {{ t('REPORTS.CALLS.ROWS_LIMIT_NOTE') }}
        </p>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[48rem] text-left text-sm">
          <thead class="bg-n-surface-2 text-xs text-n-slate-10">
            <tr>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.DATE') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.DIRECTION') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.STATUS') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.INBOX') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.PROVIDER') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.CALLS.DURATION') }}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-n-weak">
            <tr v-for="call in rows" :key="call.id" class="text-n-slate-11">
              <td class="px-4 py-2.5">{{ formatDateTime(call.started_at) }}</td>
              <td class="px-4 py-2.5">
                {{
                  t(
                    `REPORTS.CALLS.${call.direction?.toUpperCase() || 'INBOUND'}`
                  )
                }}
              </td>
              <td class="px-4 py-2.5">{{ statusLabel(call.status) }}</td>
              <td class="px-4 py-2.5">{{ call.inbox_name || '—' }}</td>
              <td class="px-4 py-2.5">{{ call.provider || '—' }}</td>
              <td class="px-4 py-2.5">
                {{ formatSeconds(call.duration_seconds) }}
              </td>
            </tr>
            <tr v-if="!isLoading && !hasError && rows.length === 0">
              <td colspan="6" class="px-4 py-8 text-center text-n-slate-10">
                {{ t('REPORTS.CALLS.EMPTY') }}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>
