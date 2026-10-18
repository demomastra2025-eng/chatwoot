<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';

import ReportsAPI from 'dashboard/api/standaloneReports';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import BarChart from 'shared/components/charts/BarChart.vue';
import { useAlert } from 'dashboard/composables';
import ReportHeader from './components/ReportHeader.vue';
import ReportMetricCard from './components/ReportMetricCard.vue';
import ReportDateRange from './components/ReportDateRange.vue';

const { t, te, locale } = useI18n();
const route = useRoute();
const accountId = computed(() => String(route?.params?.accountId || ''));

let generation = 0;
const report = ref({});
const fromDate = ref('');
const toDate = ref('');
const timezone = ref('Asia/Almaty');
const maxRangeDays = ref(90);
const isLoading = ref(false);
const hasError = ref(false);

const summary = computed(() => report.value.summary || {});
const dailyBreakdown = computed(() => report.value.daily_breakdown || []);
const rows = computed(() => report.value.rows || []);
const coverage = computed(() => report.value.coverage || { complete: true });

const localeCode = computed(() => {
  const raw = String(locale.value || 'ru').replace('_', '-');
  try {
    return Intl.getCanonicalLocales(raw)[0] || 'ru-RU';
  } catch {
    return 'ru-RU';
  }
});

const numberFormatter = computed(() => new Intl.NumberFormat(localeCode.value));
const dateFormatter = computed(
  () =>
    new Intl.DateTimeFormat(localeCode.value, {
      day: 'numeric',
      month: 'short',
      timeZone: 'UTC',
      year: 'numeric',
    })
);
const shortDateFormatter = computed(
  () =>
    new Intl.DateTimeFormat(localeCode.value, {
      day: 'numeric',
      month: 'short',
      timeZone: 'UTC',
    })
);
const dateTimeFormatter = computed(
  () =>
    new Intl.DateTimeFormat(localeCode.value, {
      dateStyle: 'medium',
      timeStyle: 'short',
      timeZone: timezone.value || 'Asia/Almaty',
    })
);

const formatCount = value => numberFormatter.value.format(Number(value || 0));

const formatDuration = value => {
  if (value === null || value === undefined) return '—';
  const num = Number(value);
  if (!Number.isFinite(num) || num < 0) return '—';

  if (num >= 60) {
    const mins = Math.floor(num / 60);
    const secs = Math.round(num % 60);
    const minText = new Intl.NumberFormat(localeCode.value, {
      style: 'unit',
      unit: 'minute',
      unitDisplay: 'short',
    }).format(mins);
    if (secs === 0) return minText;
    const secText = new Intl.NumberFormat(localeCode.value, {
      style: 'unit',
      unit: 'second',
      unitDisplay: 'short',
    }).format(secs);
    return `${minText} ${secText}`;
  }

  return new Intl.NumberFormat(localeCode.value, {
    maximumFractionDigits: num < 10 ? 1 : 0,
    style: 'unit',
    unit: 'second',
    unitDisplay: 'short',
  }).format(num);
};

const formatDate = value => {
  if (!value) return '—';
  const parsed = new Date(`${value}T12:00:00Z`);
  return Number.isNaN(parsed.getTime())
    ? String(value)
    : dateFormatter.value.format(parsed);
};

const formatDateTime = value => {
  if (!value) return '—';
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime())
    ? String(value)
    : dateTimeFormatter.value.format(parsed);
};

const isCallAnswered = call => Boolean(call?.answered_at);

const effectiveStatusKey = call => {
  const raw = call?.status;
  if (raw === 'completed' && !isCallAnswered(call)) {
    return 'no_answer';
  }
  return raw || 'unknown';
};

const statusLabel = call => {
  const status = typeof call === 'string' ? call : effectiveStatusKey(call);
  const key = `REPORTS.CALLS.STATUSES.${status}`;
  return status && te(key) ? t(key) : status || '—';
};

const statusBadgeClass = call => {
  const status = effectiveStatusKey(call);
  if (status === 'completed' || status === 'answered') {
    return 'bg-n-teal-3 text-n-teal-11';
  }
  if (status === 'no_answer' || status === 'busy' || status === 'cancelled') {
    return 'bg-n-amber-3 text-n-amber-11';
  }
  if (status === 'failed') {
    return 'bg-n-ruby-3 text-n-ruby-11';
  }
  return 'bg-n-slate-3 text-n-slate-11';
};

const PROVIDER_NAMES = {
  sipuni: 'Sipuni',
  asterisk: 'Asterisk',
  binotel: 'Binotel',
  onlinepbx: 'OnlinePBX',
  tele2: 'Tele2 / Altel',
  beeline: 'Beeline',
  kcell: 'Kcell',
};

const formatProvider = provider => {
  if (!provider) return '—';
  const normalized = String(provider).trim().toLowerCase();
  return PROVIDER_NAMES[normalized] || provider;
};

const callPhoneNumber = call => {
  if (call?.direction === 'outbound') {
    return call.to_number || call.from_number || '';
  }
  return call?.from_number || call?.to_number || '';
};

const conversationUrl = call => {
  if (!call?.conversation_id || !accountId.value) return '';
  return `/app/accounts/${accountId.value}/conversations/${call.conversation_id}`;
};

const answerRateText = computed(() => {
  const total = Number(summary.value.logical_call_count || 0);
  const answered = Number(summary.value.answered_count || 0);
  if (total <= 0) return '';
  const pct =
    summary.value.answer_rate_percent ??
    Math.round((answered / total) * 1000) / 10;
  return `${String(pct).replace('.0', '')}%`;
});

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
    value: answerRateText.value
      ? `${formatCount(summary.value.answered_count)} (${answerRateText.value})`
      : formatCount(summary.value.answered_count),
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
    value: formatDuration(summary.value.average_answered_duration_seconds),
    info: t('REPORTS.CALLS.AVERAGE_DURATION_INFO'),
  },
]);

const hasChartData = computed(() =>
  dailyBreakdown.value.some(day => Number(day.logical_call_count || 0) > 0)
);

const dailyChartCollection = computed(() => ({
  labels: dailyBreakdown.value.map(day => {
    const parsed = new Date(`${day.date}T12:00:00Z`);
    return Number.isNaN(parsed.getTime())
      ? day.date
      : shortDateFormatter.value.format(parsed);
  }),
  datasets: [
    {
      label: t('REPORTS.CALLS.ANSWERED_CALLS'),
      data: dailyBreakdown.value.map(day => Number(day.answered_count || 0)),
      backgroundColor: '#16a394',
      borderRadius: 4,
      maxBarThickness: 24,
    },
    {
      label: t('REPORTS.CALLS.UNANSWERED_CALLS'),
      data: dailyBreakdown.value.map(day => Number(day.unanswered_count || 0)),
      backgroundColor: '#df9b30',
      borderRadius: 4,
      maxBarThickness: 24,
    },
  ],
}));

const dailyChartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: { position: 'bottom' },
  },
  scales: {
    x: { stacked: true, grid: { display: false } },
    y: { stacked: true, beginAtZero: true, ticks: { precision: 0 } },
  },
};

const loadReport = async (range = {}) => {
  generation += 1;
  const request = generation;
  const account = accountId.value;
  isLoading.value = true;
  hasError.value = false;

  try {
    const response = await ReportsAPI.getCalls(range);
    if (request !== generation || account !== accountId.value) return;
    report.value = response.data?.payload || {};
    const meta = response.data?.meta || {};
    fromDate.value = meta.from_date || range.fromDate || '';
    toDate.value = meta.to_date || range.toDate || '';
    timezone.value = meta.timezone || timezone.value;
    maxRangeDays.value = meta.max_range_days || maxRangeDays.value;
  } catch {
    if (request !== generation || account !== accountId.value) return;
    report.value = {};
    hasError.value = true;
    useAlert(t('REPORTS.CALLS.ERROR'));
  } finally {
    if (request === generation) isLoading.value = false;
  }
};

const applyRange = range => loadReport(range);

watch(
  accountId,
  () => {
    report.value = {};
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
      class="flex items-center justify-between gap-3 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
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
      v-if="coverage.complete === false"
      class="rounded-xl bg-n-amber-2 px-4 py-3 text-sm text-n-amber-11 outline outline-1 -outline-offset-1 outline-n-amber-6"
      role="status"
    >
      {{
        t('REPORTS.CALLS.COVERAGE_LIMITED', {
          count: formatCount(coverage.sampled_calls),
          limit: formatCount(coverage.limit),
        })
      }}
    </div>

    <div
      class="grid grid-cols-1 gap-5 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container sm:grid-cols-2 xl:grid-cols-4"
    >
      <ReportMetricCard
        v-for="metric in metrics"
        :key="metric.key"
        :label="metric.label"
        :value="metric.value"
        :info-text="metric.info"
        :disabled="isLoading"
      />
    </div>

    <div
      v-if="isLoading && !rows.length && !dailyBreakdown.length"
      role="status"
      class="flex items-center justify-center gap-2 rounded-xl bg-n-solid-2 py-14 text-sm text-n-slate-11 shadow outline outline-1 outline-n-container"
    >
      <Spinner />
      <span>{{ t('REPORT.LOADING_CHART') }}</span>
    </div>

    <template v-else>
      <section
        class="min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
      >
        <div
          class="flex flex-wrap items-center justify-between gap-3 border-b border-n-weak px-5 py-4"
        >
          <h2 class="m-0 text-heading-2 text-n-slate-12">
            {{ t('REPORTS.CALLS.DAILY_TITLE') }}
          </h2>
          <div
            v-if="
              summary.inbound_count !== undefined ||
              summary.outbound_count !== undefined
            "
            class="flex items-center gap-4 text-xs text-n-slate-11"
          >
            <span>
              {{ t('REPORTS.CALLS.INBOUND') }}:
              <strong class="font-semibold text-n-slate-12">{{
                formatCount(summary.inbound_count)
              }}</strong>
            </span>
            <span>
              {{ t('REPORTS.CALLS.OUTBOUND') }}:
              <strong class="font-semibold text-n-slate-12">{{
                formatCount(summary.outbound_count)
              }}</strong>
            </span>
          </div>
        </div>

        <div v-if="hasChartData" class="border-b border-n-weak px-5 py-4">
          <div class="h-60">
            <BarChart
              :collection="dailyChartCollection"
              :chart-options="dailyChartOptions"
            />
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="w-full min-w-[34rem] text-left text-sm">
            <thead class="bg-n-surface-2 text-xs text-n-slate-10">
              <tr>
                <th class="px-5 py-2.5 font-medium">
                  {{ t('REPORTS.CALLS.DATE') }}
                </th>
                <th class="px-5 py-2.5 text-right font-medium">
                  {{ t('REPORTS.CALLS.LOGICAL_CALLS') }}
                </th>
                <th class="px-5 py-2.5 text-right font-medium">
                  {{ t('REPORTS.CALLS.ANSWERED_CALLS') }}
                </th>
                <th class="px-5 py-2.5 text-right font-medium">
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
                <td class="px-5 py-2.5 font-medium text-n-slate-12">
                  {{ formatDate(day.date) }}
                </td>
                <td class="px-5 py-2.5 text-right tabular-nums">
                  {{ formatCount(day.logical_call_count) }}
                </td>
                <td class="px-5 py-2.5 text-right tabular-nums text-n-teal-11">
                  {{ formatCount(day.answered_count) }}
                </td>
                <td class="px-5 py-2.5 text-right tabular-nums text-n-amber-11">
                  {{ formatCount(day.unanswered_count) }}
                </td>
              </tr>
              <tr v-if="!isLoading && !hasError && dailyBreakdown.length === 0">
                <td colspan="4" class="px-5 py-8 text-center text-n-slate-10">
                  {{ t('REPORTS.CALLS.EMPTY') }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section
        class="min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
      >
        <div class="border-b border-n-weak px-5 py-4">
          <h2 class="m-0 text-heading-2 text-n-slate-12">
            {{ t('REPORTS.CALLS.ROWS_TITLE') }}
          </h2>
          <p class="mb-0 mt-1 text-xs text-n-slate-10">
            {{ t('REPORTS.CALLS.ROWS_LIMIT_NOTE') }}
          </p>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full min-w-[54rem] text-left text-sm">
            <thead class="bg-n-surface-2 text-xs text-n-slate-10">
              <tr>
                <th class="px-5 py-2.5 font-medium">
                  {{ t('REPORTS.CALLS.DATE') }}
                </th>
                <th class="px-5 py-2.5 font-medium">
                  {{ t('REPORTS.CALLS.CONTACT') }}
                </th>
                <th class="px-5 py-2.5 font-medium">
                  {{ t('REPORTS.CALLS.DIRECTION') }}
                </th>
                <th class="px-5 py-2.5 font-medium">
                  {{ t('REPORTS.CALLS.STATUS') }}
                </th>
                <th class="px-5 py-2.5 font-medium">
                  {{ t('REPORTS.CALLS.INBOX') }}
                </th>
                <th class="px-5 py-2.5 font-medium">
                  {{ t('REPORTS.CALLS.PROVIDER') }}
                </th>
                <th class="px-5 py-2.5 text-right font-medium">
                  {{ t('REPORTS.CALLS.DURATION') }}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-n-weak">
              <tr v-for="call in rows" :key="call.id" class="text-n-slate-11">
                <td class="whitespace-nowrap px-5 py-2.5 tabular-nums">
                  {{ formatDateTime(call.started_at) }}
                </td>
                <td class="px-5 py-2.5">
                  <div class="flex flex-col gap-0.5">
                    <div class="flex items-center gap-2">
                      <span class="font-medium text-n-slate-12">
                        {{ call.contact_name || callPhoneNumber(call) || '—' }}
                      </span>
                      <router-link
                        v-if="conversationUrl(call)"
                        :to="conversationUrl(call)"
                        class="text-xs font-medium text-n-brand hover:underline"
                      >
                        #{{ call.conversation_id }}
                      </router-link>
                    </div>
                    <span
                      v-if="call.contact_name && callPhoneNumber(call)"
                      class="text-xs tabular-nums text-n-slate-10"
                    >
                      {{ callPhoneNumber(call) }}
                    </span>
                  </div>
                </td>
                <td class="whitespace-nowrap px-5 py-2.5">
                  <span class="inline-flex items-center gap-1.5 text-xs">
                    <span
                      class="size-3.5 shrink-0"
                      :class="
                        call.direction === 'outbound'
                          ? 'i-lucide-phone-outgoing text-n-blue-11'
                          : 'i-lucide-phone-incoming text-n-teal-11'
                      "
                    />
                    {{
                      t(
                        `REPORTS.CALLS.${call.direction?.toUpperCase() || 'INBOUND'}`
                      )
                    }}
                  </span>
                </td>
                <td class="whitespace-nowrap px-5 py-2.5">
                  <span
                    class="inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium"
                    :class="statusBadgeClass(call)"
                  >
                    {{ statusLabel(call) }}
                  </span>
                </td>
                <td class="px-5 py-2.5">{{ call.inbox_name || '—' }}</td>
                <td class="px-5 py-2.5">{{ formatProvider(call.provider) }}</td>
                <td class="whitespace-nowrap px-5 py-2.5 text-right tabular-nums">
                  {{ formatDuration(call.duration_seconds) }}
                </td>
              </tr>
              <tr v-if="!isLoading && !hasError && rows.length === 0">
                <td colspan="7" class="px-5 py-8 text-center text-n-slate-10">
                  {{ t('REPORTS.CALLS.EMPTY') }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </template>
  </div>
</template>
