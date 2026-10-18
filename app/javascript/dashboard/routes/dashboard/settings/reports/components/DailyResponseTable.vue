<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import format from 'date-fns/format';

import ReportsAPI from 'dashboard/api/standaloneReports';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import {
  downloadCsvFile,
  downloadExcelFile,
  generateFileName,
} from 'dashboard/helper/downloadHelper';
import ReportMetricCard from './ReportMetricCard.vue';

const props = defineProps({
  from: {
    type: Number,
    default: 0,
  },
  to: {
    type: Number,
    default: 0,
  },
});

const { t, locale } = useI18n();
const route = useRoute();
const accountId = computed(() => String(route?.params?.accountId || ''));

let generation = 0;
const report = ref({});
const isLoading = ref(false);
const hasError = ref(false);

const summary = computed(() => report.value.summary || {});
const rows = computed(() => report.value.rows || []);

const localeCode = computed(() => {
  const raw = String(locale?.value || 'ru').replace('_', '-');
  try {
    return Intl.getCanonicalLocales(raw)[0] || 'ru-RU';
  } catch {
    return 'ru-RU';
  }
});

const numberFormatter = computed(() => new Intl.NumberFormat(localeCode.value));
const formatCount = value => numberFormatter.value.format(Number(value || 0));

const formatShare = value => {
  if (value === null || value === undefined) return '—';
  const num = Number(value);
  if (!Number.isFinite(num)) return '—';
  return `${num.toFixed(1).replace('.0', '')}%`;
};

const formatDurationMinutes = value => {
  if (value === null || value === undefined) return '—';
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds < 0) return '—';
  if (seconds > 0 && seconds < 60) {
    return `${Math.round(seconds)} ${t('REPORT.DAILY_RESPONSE.UNIT_SEC')}`;
  }
  const totalMinutes = Math.round(seconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const mins = totalMinutes % 60;
  if (hours > 0) {
    return `${hours} ${t('REPORT.DAILY_RESPONSE.UNIT_HOUR')} ${String(mins).padStart(2, '0')} ${t('REPORT.DAILY_RESPONSE.UNIT_MIN')}`;
  }
  return `${mins} ${t('REPORT.DAILY_RESPONSE.UNIT_MIN')}`;
};

const formatDateLabel = isoDate => {
  if (!isoDate) return '—';
  const [y, m, d] = String(isoDate).split('-');
  if (!y || !m || !d) return String(isoDate);
  return `${d}.${m}.${y}`;
};

const weekdayLabel = isoWeekday => {
  const key = `REPORT.DAILY_RESPONSE.WEEKDAYS.${Number(isoWeekday || 1)}`;
  return t(key);
};

const summaryMetrics = computed(() => [
  {
    key: 'total',
    label: t('REPORT.DAILY_RESPONSE.SUMMARY.TOTAL'),
    value: formatCount(summary.value.total),
    info: t('REPORT.DAILY_RESPONSE.SUMMARY.TOTAL_INFO'),
  },
  {
    key: 'answered',
    label: t('REPORT.DAILY_RESPONSE.SUMMARY.ANSWERED'),
    value: formatCount(summary.value.answered),
    info: t('REPORT.DAILY_RESPONSE.SUMMARY.ANSWERED_INFO'),
  },
  {
    key: 'unanswered',
    label: t('REPORT.DAILY_RESPONSE.SUMMARY.UNANSWERED'),
    value: formatCount(summary.value.unanswered),
    info: t('REPORT.DAILY_RESPONSE.SUMMARY.UNANSWERED_INFO'),
  },
  {
    key: 'share',
    label: t('REPORT.DAILY_RESPONSE.SUMMARY.ANSWERED_SHARE'),
    value: formatShare(summary.value.answered_share_percent),
    info: t('REPORT.DAILY_RESPONSE.SUMMARY.ANSWERED_SHARE_INFO'),
  },
]);

const resolvedRange = computed(() => {
  if (!props.from || !props.to) return null;
  const startDate = new Date(Number(props.from) * 1000);
  const endDate = new Date(Number(props.to) * 1000);
  if (Number.isNaN(startDate.getTime()) || Number.isNaN(endDate.getTime())) {
    return null;
  }
  return {
    fromDate: format(startDate, 'yyyy-MM-dd'),
    toDate: format(endDate, 'yyyy-MM-dd'),
  };
});

const loadDailyResponse = async () => {
  const range = resolvedRange.value;
  if (!range) return;

  generation += 1;
  const request = generation;
  const account = accountId.value;
  isLoading.value = true;
  hasError.value = false;

  try {
    const response = await ReportsAPI.getDailyResponse(range);
    if (request !== generation || account !== accountId.value) return;
    report.value = response.data?.payload || {};
  } catch {
    if (request !== generation || account !== accountId.value) return;
    report.value = {};
    hasError.value = true;
  } finally {
    if (request === generation) isLoading.value = false;
  }
};

const exportHeaders = computed(() => [
  t('REPORT.DAILY_RESPONSE.COLUMNS.DATE'),
  t('REPORT.DAILY_RESPONSE.COLUMNS.DAY'),
  t('REPORT.DAILY_RESPONSE.COLUMNS.TOTAL'),
  t('REPORT.DAILY_RESPONSE.COLUMNS.ANSWERED'),
  t('REPORT.DAILY_RESPONSE.COLUMNS.UNANSWERED'),
  t('REPORT.DAILY_RESPONSE.COLUMNS.ANSWERED_SHARE'),
  t('REPORT.DAILY_RESPONSE.COLUMNS.AVG_FIRST_RESPONSE'),
  t('REPORT.DAILY_RESPONSE.COLUMNS.AVG_REPLY_WAIT'),
]);

const exportRows = computed(() =>
  rows.value.map(row => [
    formatDateLabel(row.date),
    weekdayLabel(row.iso_weekday),
    Number(row.total || 0),
    Number(row.answered || 0),
    Number(row.unanswered || 0),
    formatShare(row.answered_share_percent),
    formatDurationMinutes(row.avg_first_response_seconds),
    formatDurationMinutes(row.avg_reply_wait_seconds),
  ])
);

const csvCell = value => `"${String(value ?? '').replace(/"/g, '""')}"`;
const htmlEntities = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};
const htmlCell = (value, tag = 'td') =>
  `<${tag}>${String(value ?? '').replace(
    /[&<>"']/g,
    ch => htmlEntities[ch]
  )}</${tag}>`;

const downloadCsv = () => {
  if (!rows.value.length) return;
  const lines = [exportHeaders.value, ...exportRows.value].map(line =>
    line.map(csvCell).join(',')
  );
  const fileName = generateFileName({
    type: 'daily-response-report',
    to: props.to || Math.floor(Date.now() / 1000),
    extension: 'csv',
  });
  downloadCsvFile(fileName, `\uFEFF${lines.join('\n')}`);
};

const downloadExcel = () => {
  if (!rows.value.length) return;
  const headerHtml = `<tr>${exportHeaders.value.map(h => htmlCell(h, 'th')).join('')}</tr>`;
  const bodyHtml = exportRows.value
    .map(r => `<tr>${r.map(c => htmlCell(c, 'td')).join('')}</tr>`)
    .join('');
  const content = `<!doctype html><html><head><meta charset="utf-8" /></head><body><table border="1">${headerHtml}${bodyHtml}</table></body></html>`;
  const fileName = generateFileName({
    type: 'daily-response-report',
    to: props.to || Math.floor(Date.now() / 1000),
    extension: 'xls',
  });
  downloadExcelFile(fileName, `\uFEFF${content}`);
};

watch(
  [accountId, () => props.from, () => props.to],
  () => {
    loadDailyResponse();
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  generation += 1;
});
</script>

<template>
  <section
    class="mt-5 min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
    data-testid="daily-response-report"
  >
    <div
      class="flex flex-wrap items-center justify-between gap-3 border-b border-n-weak px-6 py-4"
    >
      <div>
        <h2 class="m-0 text-heading-2 text-n-slate-12">
          {{ t('REPORT.DAILY_RESPONSE.TITLE') }}
        </h2>
        <p class="mb-0 mt-1 text-xs text-n-slate-10">
          {{ t('REPORT.DAILY_RESPONSE.DESCRIPTION') }}
        </p>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          variant="faded"
          color="slate"
          icon="i-lucide-file-spreadsheet"
          :label="t('REPORT.DAILY_RESPONSE.EXPORT_EXCEL')"
          :disabled="isLoading || !rows.length"
          @click="downloadExcel"
        />
        <Button
          size="sm"
          variant="faded"
          color="slate"
          icon="i-lucide-download"
          :label="t('REPORT.DAILY_RESPONSE.EXPORT_CSV')"
          :disabled="isLoading || !rows.length"
          @click="downloadCsv"
        />
      </div>
    </div>

    <div
      class="grid grid-cols-1 gap-5 border-b border-n-weak px-6 py-5 sm:grid-cols-2 xl:grid-cols-4"
    >
      <ReportMetricCard
        v-for="metric in summaryMetrics"
        :key="metric.key"
        :label="metric.label"
        :value="metric.value"
        :info-text="metric.info"
        :disabled="isLoading"
      />
    </div>

    <div
      v-if="isLoading && !rows.length"
      role="status"
      class="flex items-center justify-center gap-2 py-12 text-sm text-n-slate-11"
    >
      <Spinner />
      <span>{{ t('REPORT.LOADING_CHART') }}</span>
    </div>

    <div
      v-else-if="hasError"
      role="alert"
      class="flex items-center justify-between gap-3 px-6 py-5"
    >
      <p class="m-0 text-sm text-n-slate-11">
        {{ t('REPORT.DATA_FETCHING_FAILED') }}
      </p>
      <Button
        size="sm"
        :label="t('REPORTS.DATE_RANGE.APPLY')"
        @click="loadDailyResponse"
      />
    </div>

    <div v-else class="overflow-x-auto">
      <table class="w-full min-w-[54rem] text-left text-sm">
        <thead class="bg-n-surface-2 text-xs text-n-slate-10">
          <tr>
            <th class="px-5 py-2.5 font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.DATE') }}
            </th>
            <th class="px-4 py-2.5 font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.DAY') }}
            </th>
            <th class="px-4 py-2.5 text-right font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.TOTAL') }}
            </th>
            <th class="px-4 py-2.5 text-right font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.ANSWERED') }}
            </th>
            <th class="px-4 py-2.5 text-right font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.UNANSWERED') }}
            </th>
            <th class="px-4 py-2.5 text-right font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.ANSWERED_SHARE') }}
            </th>
            <th class="px-4 py-2.5 text-right font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.AVG_FIRST_RESPONSE') }}
            </th>
            <th class="px-5 py-2.5 text-right font-medium">
              {{ t('REPORT.DAILY_RESPONSE.COLUMNS.AVG_REPLY_WAIT') }}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak">
          <tr v-for="row in rows" :key="row.date" class="text-n-slate-11">
            <td class="whitespace-nowrap px-5 py-2.5 font-medium text-n-slate-12 tabular-nums">
              {{ formatDateLabel(row.date) }}
            </td>
            <td class="whitespace-nowrap px-4 py-2.5">
              {{ weekdayLabel(row.iso_weekday) }}
            </td>
            <td class="whitespace-nowrap px-4 py-2.5 text-right tabular-nums font-medium text-n-slate-12">
              {{ formatCount(row.total) }}
            </td>
            <td class="whitespace-nowrap px-4 py-2.5 text-right tabular-nums text-n-teal-11">
              {{ formatCount(row.answered) }}
            </td>
            <td class="whitespace-nowrap px-4 py-2.5 text-right tabular-nums text-n-amber-11">
              {{ formatCount(row.unanswered) }}
            </td>
            <td class="whitespace-nowrap px-4 py-2.5 text-right tabular-nums">
              {{ formatShare(row.answered_share_percent) }}
            </td>
            <td class="whitespace-nowrap px-4 py-2.5 text-right tabular-nums">
              {{ formatDurationMinutes(row.avg_first_response_seconds) }}
            </td>
            <td class="whitespace-nowrap px-5 py-2.5 text-right tabular-nums">
              {{ formatDurationMinutes(row.avg_reply_wait_seconds) }}
            </td>
          </tr>
          <tr v-if="!rows.length">
            <td colspan="8" class="px-5 py-8 text-center text-n-slate-10">
              {{ t('REPORT.NO_ENOUGH_DATA') }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>
