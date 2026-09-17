<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import format from 'date-fns/format';

import CrmReportsAPI from 'dashboard/api/crm/reports';
import { useAlert } from 'dashboard/composables';
import {
  downloadCsvFile,
  downloadExcelFile,
  generateFileName,
} from 'dashboard/helper/downloadHelper';
import { normalizeMeta, normalizePayload } from 'dashboard/stores/crm/shared';
import BarChart from 'shared/components/charts/BarChart.vue';
import DoughnutChart from 'shared/components/charts/DoughnutChart.vue';
import LineChart from 'shared/components/charts/LineChart.vue';
import ReportFilters from './components/ReportFilters.vue';
import ReportHeader from './components/ReportHeader.vue';

const { t, locale } = useI18n();

const report = ref(null);
const meta = ref({});
const managerEffectiveness = ref(null);
const managerMeta = ref({});
const managerEffectivenessError = ref(false);
const isExportMenuOpen = ref(false);
const isLoading = ref(false);
const activeSection = ref('overview');

const palette = [
  '#2563EB',
  '#10B981',
  '#F97316',
  '#7C3AED',
  '#06B6D4',
  '#E11D48',
  '#84CC16',
  '#F59E0B',
];

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);
const currency = computed(
  () => report.value?.summary?.currency || meta.value.currency || 'KZT'
);

const sections = computed(() => [
  {
    key: 'overview',
    icon: 'i-lucide-layout-dashboard',
    label: t('CRM_DEAL_REPORTS.SECTIONS.OVERVIEW.TITLE'),
    description: t('CRM_DEAL_REPORTS.SECTIONS.OVERVIEW.DESCRIPTION'),
  },
  {
    key: 'effectiveness',
    icon: 'i-lucide-table-properties',
    label: t('CRM_DEAL_REPORTS.SECTIONS.EFFECTIVENESS.TITLE'),
    description: t('CRM_DEAL_REPORTS.SECTIONS.EFFECTIVENESS.DESCRIPTION'),
  },
  {
    key: 'forecast',
    icon: 'i-lucide-calendar-clock',
    label: t('CRM_DEAL_REPORTS.SECTIONS.FORECAST.TITLE'),
    description: t('CRM_DEAL_REPORTS.SECTIONS.FORECAST.DESCRIPTION'),
  },
  {
    key: 'sources',
    icon: 'i-lucide-git-branch',
    label: t('CRM_DEAL_REPORTS.SECTIONS.SOURCES.TITLE'),
    description: t('CRM_DEAL_REPORTS.SECTIONS.SOURCES.DESCRIPTION'),
  },
  {
    key: 'team',
    icon: 'i-lucide-users-round',
    label: t('CRM_DEAL_REPORTS.SECTIONS.TEAM.TITLE'),
    description: t('CRM_DEAL_REPORTS.SECTIONS.TEAM.DESCRIPTION'),
  },
]);

const currentSection = computed(
  () =>
    sections.value.find(section => section.key === activeSection.value) ||
    sections.value[0]
);

const summary = computed(() => report.value?.summary || {});
const stageDistribution = computed(() => report.value?.stageDistribution || []);
const forecastByPeriod = computed(() => report.value?.forecastByPeriod || []);
const wonLostByPeriod = computed(() => report.value?.wonLostByPeriod || []);
const sourcePerformance = computed(() => report.value?.sourcePerformance || []);
const ownerPerformance = computed(() => report.value?.ownerPerformance || []);
const agingBuckets = computed(() => report.value?.agingBuckets || []);
const managerRows = computed(() => managerEffectiveness.value?.rows || []);
const managerTotals = computed(() => managerEffectiveness.value?.totals || {});
const callDurationThresholdSeconds = computed(
  () => managerMeta.value?.callDurationThresholdSeconds || 25
);

const numberFormatter = computed(
  () =>
    new Intl.NumberFormat(localeCode.value, {
      maximumFractionDigits: 0,
    })
);

const moneyFormatter = computed(
  () =>
    new Intl.NumberFormat(localeCode.value, {
      currency: currency.value,
      maximumFractionDigits: 0,
      style: 'currency',
    })
);

const compactMoneyFormatter = computed(
  () =>
    new Intl.NumberFormat(localeCode.value, {
      compactDisplay: 'short',
      currency: currency.value,
      maximumFractionDigits: 1,
      notation: 'compact',
      style: 'currency',
    })
);

const toNumber = value => Number(value || 0);
const minorToMajor = value => toNumber(value) / 100;
const formatNumber = value => numberFormatter.value.format(toNumber(value));
const formatMoney = value => moneyFormatter.value.format(minorToMajor(value));
const formatCompactMoney = value =>
  compactMoneyFormatter.value.format(minorToMajor(value));
const formatPercent = value =>
  `${toNumber(value).toFixed(1).replace('.0', '')}%`;
const percentage = (value, total) => {
  if (toNumber(total) <= 0) return 0;

  return Math.round((toNumber(value) / toNumber(total)) * 1000) / 10;
};
const widthPercent = (value, total) => {
  if (toNumber(total) <= 0 || toNumber(value) <= 0) return 0;

  return Math.max(6, percentage(value, total));
};

const formatPeriod = value => {
  if (!value) return t('CRM_DEAL_REPORTS.EMPTY_VALUE');

  return format(new Date(value), 'dd MMM yyyy');
};

const sourceLabel = source => {
  switch (String(source || 'manual').toLowerCase()) {
    case 'conversation':
      return t('CRM_DEAL_REPORTS.SOURCES.CONVERSATION');
    case 'ai':
      return t('CRM_DEAL_REPORTS.SOURCES.AI');
    case 'import':
      return t('CRM_DEAL_REPORTS.SOURCES.IMPORT');
    case 'other':
      return t('CRM_DEAL_REPORTS.SOURCES.OTHER');
    case 'manual':
      return t('CRM_DEAL_REPORTS.SOURCES.MANUAL');
    default:
      return source || t('CRM_DEAL_REPORTS.SOURCES.MANUAL');
  }
};

const agingBucketLabel = bucket => {
  switch (bucket.key) {
    case '0_3':
      return t('CRM_DEAL_REPORTS.AGING_BUCKETS.0_3');
    case '4_7':
      return t('CRM_DEAL_REPORTS.AGING_BUCKETS.4_7');
    case '8_14':
      return t('CRM_DEAL_REPORTS.AGING_BUCKETS.8_14');
    case '15_30':
      return t('CRM_DEAL_REPORTS.AGING_BUCKETS.15_30');
    case '31_plus':
      return t('CRM_DEAL_REPORTS.AGING_BUCKETS.31_plus');
    default:
      return t('CRM_DEAL_REPORTS.EMPTY_VALUE');
  }
};

const stageLabel = stage => {
  const pipelineName = stage.pipelineName ? `${stage.pipelineName} · ` : '';
  return `${pipelineName}${stage.stageName}`;
};

const hasDatasetData = collection =>
  collection?.datasets?.some(dataset =>
    dataset.data.some(value => toNumber(value) > 0)
  );

const totalSourceDeals = computed(() =>
  sourcePerformance.value.reduce(
    (total, item) => total + toNumber(item.dealCount),
    0
  )
);
const forecastAmountMinor = computed(() =>
  forecastByPeriod.value.reduce(
    (total, item) => total + toNumber(item.amountMinor),
    0
  )
);
const weightedForecastAmountMinor = computed(() =>
  forecastByPeriod.value.reduce(
    (total, item) => total + toNumber(item.weightedAmountMinor),
    0
  )
);

const maxStageCount = computed(() =>
  Math.max(
    ...stageDistribution.value.map(stage => toNumber(stage.dealCount)),
    0
  )
);
const maxStageAmount = computed(() =>
  Math.max(
    ...stageDistribution.value.map(stage => toNumber(stage.amountMinor)),
    0
  )
);
const maxOwnerAmount = computed(() =>
  Math.max(
    ...ownerPerformance.value.map(owner => toNumber(owner.amountMinor)),
    0
  )
);
const maxAgingCount = computed(() =>
  Math.max(...agingBuckets.value.map(bucket => toNumber(bucket.dealCount)), 0)
);

const stageRows = computed(() =>
  stageDistribution.value.map((stage, index) => ({
    ...stage,
    amountLabel: formatMoney(stage.amountMinor),
    amountWidth: widthPercent(stage.amountMinor, maxStageAmount.value),
    color: stage.stageColor || palette[index % palette.length],
    countLabel: formatNumber(stage.dealCount),
    countWidth: widthPercent(stage.dealCount, maxStageCount.value),
    label: stageLabel(stage),
  }))
);

const sourceRows = computed(() =>
  sourcePerformance.value.map((source, index) => ({
    ...source,
    color: palette[index % palette.length],
    label: sourceLabel(source.source),
    share: percentage(source.dealCount, totalSourceDeals.value),
    shareWidth: widthPercent(source.dealCount, totalSourceDeals.value),
  }))
);

const ownerRows = computed(() =>
  ownerPerformance.value.map(owner => ({
    ...owner,
    amountLabel: formatMoney(owner.amountMinor),
    amountWidth: widthPercent(owner.amountMinor, maxOwnerAmount.value),
    label: owner.ownerName || t('CRM_DEAL_REPORTS.UNASSIGNED'),
  }))
);

const agingRows = computed(() =>
  agingBuckets.value.map(bucket => ({
    ...bucket,
    label: agingBucketLabel(bucket),
    width: widthPercent(bucket.dealCount, maxAgingCount.value),
  }))
);

const baseBarOptions = {
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: { display: false },
  },
  scales: {
    x: {
      grid: { display: false },
      ticks: { precision: 0 },
    },
    y: {
      beginAtZero: true,
      grid: { drawOnChartArea: false },
      ticks: { precision: 0 },
    },
  },
};

const moneyAxisOptions = computed(() => ({
  ...baseBarOptions,
  indexAxis: 'y',
  plugins: {
    legend: { display: false },
    tooltip: {
      callbacks: {
        label: context => formatMoney(toNumber(context.raw) * 100),
      },
    },
  },
  scales: {
    x: {
      beginAtZero: true,
      grid: { display: false },
      ticks: {
        callback: value => formatCompactMoney(toNumber(value) * 100),
      },
    },
    y: {
      grid: { display: false },
    },
  },
}));

const stackedCountOptions = computed(() => ({
  ...baseBarOptions,
  plugins: {
    legend: { display: true, position: 'bottom' },
  },
  scales: {
    x: {
      stacked: true,
      grid: { display: false },
    },
    y: {
      beginAtZero: true,
      stacked: true,
      grid: { drawOnChartArea: false },
      ticks: { precision: 0 },
    },
  },
}));

const lineMoneyOptions = computed(() => ({
  plugins: {
    legend: { display: true, position: 'bottom' },
    tooltip: {
      callbacks: {
        label: context =>
          `${context.dataset.label}: ${formatMoney(toNumber(context.raw) * 100)}`,
      },
    },
  },
  scales: {
    x: { grid: { display: false } },
    y: {
      beginAtZero: true,
      grid: { drawOnChartArea: false },
      ticks: {
        callback: value => formatCompactMoney(toNumber(value) * 100),
      },
    },
  },
}));

const doughnutOptions = computed(() => ({
  cutout: '70%',
  plugins: {
    legend: { display: false },
    tooltip: {
      callbacks: {
        label: context => {
          const value = toNumber(context.raw);
          return `${context.label}: ${formatNumber(value)} (${formatPercent(
            percentage(value, totalSourceDeals.value)
          )})`;
        },
      },
    },
  },
}));

const stageAmountCollection = computed(() => ({
  labels: stageDistribution.value.map(stageLabel),
  datasets: [
    {
      backgroundColor: stageDistribution.value.map(
        (stage, index) => stage.stageColor || palette[index % palette.length]
      ),
      borderRadius: 8,
      data: stageDistribution.value.map(stage =>
        minorToMajor(stage.amountMinor)
      ),
      label: t('CRM_DEAL_REPORTS.CHARTS.STAGE_AMOUNT.DATASET'),
    },
  ],
}));

const forecastCollection = computed(() => ({
  labels: forecastByPeriod.value.map(item => formatPeriod(item.period)),
  datasets: [
    {
      backgroundColor: 'rgba(37, 99, 235, 0.12)',
      borderColor: '#2563EB',
      data: forecastByPeriod.value.map(item => minorToMajor(item.amountMinor)),
      fill: true,
      label: t('CRM_DEAL_REPORTS.CHARTS.FORECAST_AMOUNT.DATASET'),
      tension: 0.35,
    },
    {
      backgroundColor: 'rgba(16, 185, 129, 0.1)',
      borderColor: '#10B981',
      data: forecastByPeriod.value.map(item =>
        minorToMajor(item.weightedAmountMinor)
      ),
      fill: true,
      label: t('CRM_DEAL_REPORTS.CHARTS.FORECAST_WEIGHTED.DATASET'),
      tension: 0.35,
    },
  ],
}));

const wonLostPeriods = computed(() => [
  ...new Set(wonLostByPeriod.value.map(item => item.period)),
]);

const wonLostCollection = computed(() => {
  const valueFor = (period, outcome) =>
    wonLostByPeriod.value.find(
      item => item.period === period && item.outcome === outcome
    )?.dealCount || 0;

  return {
    labels: wonLostPeriods.value.map(formatPeriod),
    datasets: [
      {
        backgroundColor: '#16A34A',
        borderRadius: 8,
        data: wonLostPeriods.value.map(period => valueFor(period, 'won')),
        label: t('CRM_DEAL_REPORTS.CHARTS.WON_LOST.WON'),
      },
      {
        backgroundColor: '#DC2626',
        borderRadius: 8,
        data: wonLostPeriods.value.map(period => valueFor(period, 'lost')),
        label: t('CRM_DEAL_REPORTS.CHARTS.WON_LOST.LOST'),
      },
    ],
  };
});

const sourceDoughnutCollection = computed(() => ({
  labels: sourceRows.value.map(source => source.label),
  datasets: [
    {
      backgroundColor: sourceRows.value.map(source => source.color),
      borderColor: '#FFFFFF',
      borderWidth: 2,
      data: sourceRows.value.map(source => source.dealCount),
      hoverOffset: 8,
      label: t('CRM_DEAL_REPORTS.CHARTS.SOURCE.DATASET'),
    },
  ],
}));

const sourceOutcomeCollection = computed(() => ({
  labels: sourceRows.value.map(source => source.label),
  datasets: [
    {
      backgroundColor: '#2563EB',
      borderRadius: 8,
      data: sourceRows.value.map(item => item.openCount),
      label: t('CRM_DEAL_REPORTS.CHARTS.SOURCE.OPEN'),
    },
    {
      backgroundColor: '#16A34A',
      borderRadius: 8,
      data: sourceRows.value.map(item => item.wonCount),
      label: t('CRM_DEAL_REPORTS.CHARTS.SOURCE.WON'),
    },
    {
      backgroundColor: '#DC2626',
      borderRadius: 8,
      data: sourceRows.value.map(item => item.lostCount),
      label: t('CRM_DEAL_REPORTS.CHARTS.SOURCE.LOST'),
    },
  ],
}));

const ownerCollection = computed(() => ({
  labels: ownerRows.value.map(owner => owner.label),
  datasets: [
    {
      backgroundColor: '#7C3AED',
      borderRadius: 8,
      data: ownerRows.value.map(owner => minorToMajor(owner.amountMinor)),
      label: t('CRM_DEAL_REPORTS.CHARTS.OWNER_AMOUNT.DATASET'),
    },
  ],
}));

const forecastSummaryCards = computed(() => [
  {
    key: 'forecastTotal',
    label: t('CRM_DEAL_REPORTS.LABELS.FORECAST_TOTAL'),
    value: formatMoney(forecastAmountMinor.value),
  },
  {
    key: 'weightedTotal',
    label: t('CRM_DEAL_REPORTS.LABELS.WEIGHTED_TOTAL'),
    value: formatMoney(weightedForecastAmountMinor.value),
  },
  {
    key: 'closedTotal',
    label: t('CRM_DEAL_REPORTS.LABELS.CLOSED_TOTAL'),
    value: formatNumber(
      toNumber(summary.value.wonDealsCount) +
        toNumber(summary.value.lostDealsCount)
    ),
  },
]);

const summaryCards = computed(() => [
  {
    key: 'openDeals',
    icon: 'i-lucide-briefcase-business',
    label: t('CRM_DEAL_REPORTS.SUMMARY.OPEN_DEALS'),
    value: formatNumber(summary.value.openDealsCount),
    helper: t('CRM_DEAL_REPORTS.SUMMARY.OPEN_DEALS_HELPER'),
    accent: 'text-n-blue-11 bg-n-blue-3',
  },
  {
    key: 'pipelineAmount',
    icon: 'i-lucide-circle-dollar-sign',
    label: t('CRM_DEAL_REPORTS.SUMMARY.PIPELINE_AMOUNT'),
    value: formatMoney(summary.value.pipelineAmountMinor),
    helper: t('CRM_DEAL_REPORTS.SUMMARY.PIPELINE_AMOUNT_HELPER'),
    accent: 'text-n-teal-11 bg-n-teal-3',
  },
  {
    key: 'weightedPipeline',
    icon: 'i-lucide-target',
    label: t('CRM_DEAL_REPORTS.SUMMARY.WEIGHTED_PIPELINE'),
    value: formatMoney(summary.value.weightedPipelineAmountMinor),
    helper: t('CRM_DEAL_REPORTS.SUMMARY.WEIGHTED_PIPELINE_HELPER'),
    accent: 'text-n-teal-11 bg-n-teal-3',
  },
  {
    key: 'winRate',
    icon: 'i-lucide-trophy',
    label: t('CRM_DEAL_REPORTS.SUMMARY.WIN_RATE'),
    value: formatPercent(summary.value.winRate),
    helper: t('CRM_DEAL_REPORTS.SUMMARY.WIN_RATE_HELPER', {
      won: formatNumber(summary.value.wonDealsCount),
      lost: formatNumber(summary.value.lostDealsCount),
    }),
    accent: 'text-n-amber-11 bg-n-amber-3',
  },
]);

const effectivenessSummaryCards = computed(() => [
  {
    key: 'leads',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.CARDS.LEADS'),
    value: formatNumber(managerTotals.value.leadsCount),
  },
  {
    key: 'longCalls',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.CARDS.LONG_CALLS', {
      seconds: callDurationThresholdSeconds.value,
    }),
    value: formatNumber(managerTotals.value.longCallsCount),
  },
  {
    key: 'meetings',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.CARDS.MEETINGS'),
    value: formatNumber(managerTotals.value.meetingsCount),
  },
  {
    key: 'won',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.CARDS.WON'),
    value: formatNumber(managerTotals.value.wonCount),
  },
  {
    key: 'payments',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.CARDS.PAYMENTS'),
    value: formatMoney(managerTotals.value.paymentsAmountMinor),
  },
]);

const effectivenessMoneyColumns = computed(() => [
  {
    key: 'cashAmountMinor',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.CASH'),
  },
  {
    key: 'nonCashAmountMinor',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.NON_CASH'),
  },

  {
    key: 'tradeInAmountMinor',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.TRADE_IN'),
  },
]);

const effectivenessNumberColumns = computed(() => [
  {
    key: 'leadsCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.LEADS'),
  },
  {
    key: 'openCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.IN_PROGRESS'),
  },
  {
    key: 'badCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.BAD'),
  },
  {
    key: 'callAttemptsCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.CALL_ATTEMPTS'),
  },
  {
    key: 'connectedCallsCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.CONNECTED_CALLS'),
  },
  {
    key: 'longCallsCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.LONG_CALLS', {
      seconds: callDurationThresholdSeconds.value,
    }),
  },
  {
    key: 'meetingsCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.MEETINGS'),
  },
  {
    key: 'wonCount',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.WON'),
  },
]);

const effectivenessPercentColumns = computed(() => [
  {
    key: 'badRate',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.BAD_RATE'),
  },
  {
    key: 'leadToMeetingConversion',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.LEAD_TO_MEETING'),
  },
  {
    key: 'callToMeetingConversion',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.CALL_TO_MEETING'),
  },
  {
    key: 'meetingToDealConversion',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.MEETING_TO_DEAL'),
  },
  {
    key: 'leadToDealConversion',
    label: t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.LEAD_TO_DEAL'),
  },
]);

const csvCell = value => `"${String(value ?? '').replace(/"/g, '""')}"`;
const csvRow = values => values.map(csvCell).join(',');
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
    character => htmlEntities[character]
  )}</${tag}>`;
const htmlRow = (values, tag = 'td') =>
  `<tr>${values.map(value => htmlCell(value, tag)).join('')}</tr>`;
const csvMoney = value => minorToMajor(value).toFixed(2);
const csvPercent = value => toNumber(value).toFixed(1);

const effectivenessExportHeader = computed(() => [
  t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.MANAGER'),
  ...effectivenessNumberColumns.value.map(column => column.label),
  ...effectivenessPercentColumns.value.map(column => column.label),
  t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.DEAL_AMOUNT'),
  t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.WON_AMOUNT'),
  t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.PAYMENTS'),
  ...effectivenessMoneyColumns.value.map(column => column.label),
]);

const effectivenessExportRowFor = (row, label) => [
  label,
  ...effectivenessNumberColumns.value.map(column => toNumber(row[column.key])),
  ...effectivenessPercentColumns.value.map(column =>
    csvPercent(row[column.key])
  ),
  csvMoney(row.dealAmountMinor),
  csvMoney(row.wonAmountMinor),
  csvMoney(row.paymentsAmountMinor),
  ...effectivenessMoneyColumns.value.map(column => csvMoney(row[column.key])),
];

const effectivenessExportRows = computed(() => [
  ...managerRows.value.map(row =>
    effectivenessExportRowFor(
      row,
      row.ownerName || t('CRM_DEAL_REPORTS.UNASSIGNED')
    )
  ),
  effectivenessExportRowFor(
    managerTotals.value,
    t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.TOTAL')
  ),
]);

const managerEffectivenessFileName = extension =>
  generateFileName({
    extension,
    type: 'manager-effectiveness',
    to: Math.floor(Date.now() / 1000),
  });

const downloadManagerEffectivenessCsv = () => {
  const content = [
    effectivenessExportHeader.value,
    ...effectivenessExportRows.value,
  ]
    .map(csvRow)
    .join('\n');

  downloadCsvFile(managerEffectivenessFileName('csv'), `\uFEFF${content}`);
};

const downloadManagerEffectivenessExcel = () => {
  const rows = [
    htmlRow(effectivenessExportHeader.value, 'th'),
    ...effectivenessExportRows.value.map(row => htmlRow(row)),
  ].join('');
  const content = `<!doctype html><html><head><meta charset="utf-8" /></head><body><table>${rows}</table></body></html>`;

  downloadExcelFile(managerEffectivenessFileName('xls'), `\uFEFF${content}`);
};

const downloadManagerEffectiveness = formatType => {
  if (!managerRows.value.length) return;

  if (formatType === 'excel') {
    downloadManagerEffectivenessExcel();
  } else {
    downloadManagerEffectivenessCsv();
  }

  isExportMenuOpen.value = false;
};

const toggleExportMenu = () => {
  isExportMenuOpen.value = !isExportMenuOpen.value;
};

const hasReportData = computed(
  () =>
    toNumber(summary.value.createdDealsCount) > 0 ||
    toNumber(summary.value.openDealsCount) > 0 ||
    toNumber(summary.value.wonDealsCount) > 0 ||
    toNumber(summary.value.lostDealsCount) > 0 ||
    managerRows.value.length > 0
);

const requestPayload = payload => ({
  group_by: payload.groupBy?.period,
  since: payload.from,
  until: payload.to,
});

const loadDealReport = async payload => {
  isLoading.value = true;

  managerEffectivenessError.value = false;

  try {
    const [dealReportResult, managerEffectivenessResult] =
      await Promise.allSettled([
        CrmReportsAPI.deals(requestPayload(payload)),
        CrmReportsAPI.managerEffectiveness(requestPayload(payload)),
      ]);

    if (dealReportResult.status === 'rejected') {
      throw dealReportResult.reason;
    }

    report.value = normalizePayload(dealReportResult.value.data);
    meta.value = normalizeMeta(dealReportResult.value.data);

    if (managerEffectivenessResult.status === 'fulfilled') {
      managerEffectiveness.value = normalizePayload(
        managerEffectivenessResult.value.data
      );
      managerMeta.value = normalizeMeta(managerEffectivenessResult.value.data);
    } else {
      managerEffectiveness.value = { rows: [], totals: {} };
      managerMeta.value = {};
      managerEffectivenessError.value = true;
    }
  } catch {
    useAlert(t('CRM_DEAL_REPORTS.ERROR'));
  } finally {
    isLoading.value = false;
  }
};

const onFilterChange = payload => {
  loadDealReport(payload);
};
</script>

<template>
  <ReportHeader :header-title="$t('CRM_DEAL_REPORTS.HEADER')" />

  <div class="flex flex-col gap-4 pb-8">
    <section
      class="rounded-xl bg-n-solid-2 p-5 shadow-sm outline outline-1 outline-n-container"
    >
      <div
        class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between"
      >
        <div class="flex gap-3">
          <div
            class="mt-1 flex size-10 shrink-0 items-center justify-center rounded-xl bg-n-blue-3 text-n-blue-11"
          >
            <i class="i-lucide-briefcase-business text-lg" />
          </div>
          <div class="max-w-3xl">
            <p
              class="text-xs font-semibold uppercase tracking-wide text-n-blue-11"
            >
              {{ $t('CRM_DEAL_REPORTS.KICKER') }}
            </p>
            <h2 class="mt-1 text-xl font-semibold text-n-slate-12">
              {{ $t('CRM_DEAL_REPORTS.TITLE') }}
            </h2>
            <p class="mt-2 text-sm leading-6 text-n-slate-11">
              {{ $t('CRM_DEAL_REPORTS.DESCRIPTION') }}
            </p>
          </div>
        </div>
        <div
          class="inline-flex items-center gap-2 rounded-xl bg-n-alpha-1 px-3 py-2 text-sm text-n-slate-11"
        >
          <i class="i-lucide-coins text-n-slate-10" />
          {{ $t('CRM_DEAL_REPORTS.CURRENCY_HINT', { currency }) }}
        </div>
      </div>
    </section>

    <ReportFilters
      :show-business-hours="false"
      :show-entity-filter="false"
      show-group-by
      @filter-change="onFilterChange"
    />

    <div
      v-if="isLoading"
      class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4"
    >
      <div
        v-for="item in 4"
        :key="item"
        class="h-28 animate-pulse rounded-xl bg-n-slate-3"
      />
    </div>

    <template v-else-if="report">
      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4">
        <div
          v-for="card in summaryCards"
          :key="card.key"
          class="rounded-xl bg-n-solid-2 p-5 shadow-sm outline outline-1 outline-n-container"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="text-sm font-medium text-n-slate-11">
                {{ card.label }}
              </p>
              <p class="mt-3 text-2xl font-semibold text-n-slate-12">
                {{ card.value }}
              </p>
            </div>
            <span
              :class="card.accent"
              class="flex size-9 items-center justify-center rounded-xl"
            >
              <i :class="card.icon" class="text-lg" />
            </span>
          </div>
          <p class="mt-3 text-xs leading-5 text-n-slate-10">
            {{ card.helper }}
          </p>
        </div>
      </div>

      <div
        v-if="!hasReportData"
        class="rounded-xl bg-n-solid-2 p-8 text-center shadow-sm outline outline-1 outline-n-container"
      >
        <i
          class="i-lucide-chart-no-axes-column mx-auto text-3xl text-n-slate-9"
        />
        <p class="mt-3 text-sm font-medium text-n-slate-12">
          {{ $t('CRM_DEAL_REPORTS.EMPTY_TITLE') }}
        </p>
        <p class="mt-1 text-sm text-n-slate-10">
          {{ $t('CRM_DEAL_REPORTS.EMPTY_DESCRIPTION') }}
        </p>
      </div>

      <template v-else>
        <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-5">
          <button
            v-for="section in sections"
            :key="section.key"
            type="button"
            class="rounded-xl border p-4 text-left transition hover:border-n-blue-6 hover:bg-n-blue-2"
            :class="
              activeSection === section.key
                ? 'border-n-blue-8 bg-n-blue-3 text-n-blue-12'
                : 'border-n-container bg-n-solid-2 text-n-slate-11'
            "
            @click="activeSection = section.key"
          >
            <div class="flex items-center gap-2 text-sm font-semibold">
              <i :class="section.icon" />
              <span>{{ section.label }}</span>
            </div>
            <p class="mt-2 text-xs leading-5 opacity-80">
              {{ section.description }}
            </p>
          </button>
        </div>

        <section
          class="rounded-xl bg-n-solid-2 p-5 shadow-sm outline outline-1 outline-n-container"
        >
          <div class="flex flex-col gap-1">
            <h3 class="text-base font-semibold text-n-slate-12">
              {{ currentSection.label }}
            </h3>
            <p class="text-sm text-n-slate-10">
              {{ currentSection.description }}
            </p>
          </div>

          <div
            v-if="activeSection === 'overview'"
            class="mt-5 grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)]"
          >
            <section class="rounded-xl border border-n-container p-4">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h4 class="text-sm font-semibold text-n-slate-12">
                    {{ $t('CRM_DEAL_REPORTS.CHARTS.STAGE_FLOW.TITLE') }}
                  </h4>
                  <p class="mt-1 text-xs leading-5 text-n-slate-10">
                    {{ $t('CRM_DEAL_REPORTS.CHARTS.STAGE_FLOW.DESCRIPTION') }}
                  </p>
                </div>
              </div>

              <div class="mt-4 flex flex-col gap-3">
                <div
                  v-for="stage in stageRows"
                  :key="stage.stageId"
                  class="rounded-xl bg-n-alpha-1 p-3"
                >
                  <div class="flex items-start justify-between gap-4">
                    <div class="min-w-0">
                      <div class="flex items-center gap-2">
                        <span
                          class="size-2 rounded-full"
                          :style="{ backgroundColor: stage.color }"
                        />
                        <p class="truncate text-sm font-medium text-n-slate-12">
                          {{ stage.label }}
                        </p>
                      </div>
                      <p class="mt-1 text-xs text-n-slate-10">
                        {{ stage.amountLabel }}
                      </p>
                    </div>
                    <div class="text-right">
                      <p class="text-sm font-semibold text-n-slate-12">
                        {{ stage.countLabel }}
                      </p>
                      <p class="text-xs text-n-slate-10">
                        {{ $t('CRM_DEAL_REPORTS.LABELS.DEALS') }}
                      </p>
                    </div>
                  </div>
                  <div class="mt-3 space-y-2">
                    <div class="h-2 rounded-full bg-n-slate-4">
                      <div
                        class="h-2 rounded-full"
                        :style="{
                          width: `${stage.countWidth}%`,
                          backgroundColor: stage.color,
                        }"
                      />
                    </div>
                    <div class="h-1.5 rounded-full bg-n-slate-3">
                      <div
                        class="h-1.5 rounded-full bg-n-teal-9"
                        :style="{ width: `${stage.amountWidth}%` }"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <section class="rounded-xl border border-n-container p-4">
              <h4 class="text-sm font-semibold text-n-slate-12">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.STAGE_AMOUNT.TITLE') }}
              </h4>
              <p class="mt-1 text-xs leading-5 text-n-slate-10">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.STAGE_AMOUNT.DESCRIPTION') }}
              </p>
              <div class="mt-4 h-[28rem]">
                <BarChart
                  v-if="hasDatasetData(stageAmountCollection)"
                  :collection="stageAmountCollection"
                  :chart-options="moneyAxisOptions"
                />
                <p
                  v-else
                  class="flex h-full items-center justify-center text-sm text-n-slate-10"
                >
                  {{ $t('REPORT.NO_ENOUGH_DATA') }}
                </p>
              </div>
            </section>
          </div>

          <div
            v-else-if="activeSection === 'effectiveness'"
            class="mt-5 flex flex-col gap-5"
          >
            <div
              v-if="managerEffectivenessError"
              class="rounded-xl border border-n-amber-5 bg-n-amber-2 p-4 text-sm text-n-amber-12"
            >
              <div class="flex gap-2">
                <i class="i-lucide-triangle-alert mt-0.5" />
                <p>
                  {{ $t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.LOAD_ERROR') }}
                </p>
              </div>
            </div>

            <div class="grid grid-cols-1 gap-3 md:grid-cols-5">
              <div
                v-for="card in effectivenessSummaryCards"
                :key="card.key"
                class="rounded-xl border border-n-container bg-n-alpha-1 p-4"
              >
                <p class="text-xs font-medium text-n-slate-10">
                  {{ card.label }}
                </p>
                <p class="mt-2 text-xl font-semibold text-n-slate-12">
                  {{ card.value }}
                </p>
              </div>
            </div>

            <section class="rounded-xl border border-n-container p-4">
              <div
                class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between"
              >
                <div class="flex flex-col gap-1">
                  <h4 class="text-sm font-semibold text-n-slate-12">
                    {{
                      $t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.TABLE_TITLE')
                    }}
                  </h4>
                  <p class="text-xs leading-5 text-n-slate-10">
                    {{
                      $t(
                        'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.TABLE_DESCRIPTION'
                      )
                    }}
                  </p>
                </div>
                <div
                  v-if="managerRows.length"
                  class="relative inline-flex"
                  @keydown.escape="isExportMenuOpen = false"
                >
                  <button
                    type="button"
                    class="inline-flex items-center justify-center gap-2 rounded-lg border border-n-container bg-n-solid-2 px-3 py-2 text-sm font-medium text-n-slate-11 transition hover:border-n-blue-6 hover:text-n-blue-11"
                    :aria-expanded="isExportMenuOpen"
                    aria-haspopup="menu"
                    @click="toggleExportMenu"
                  >
                    <i class="i-lucide-download size-4" />
                    <span>
                      {{ $t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.EXPORT') }}
                    </span>
                    <i class="i-lucide-chevron-down size-4" />
                  </button>

                  <div
                    v-if="isExportMenuOpen"
                    class="absolute right-0 top-full z-20 mt-2 w-44 overflow-hidden rounded-lg border border-n-container bg-n-solid-2 py-1 shadow-lg"
                    role="menu"
                  >
                    <button
                      type="button"
                      class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-n-slate-11 hover:bg-n-alpha-1 hover:text-n-slate-12"
                      role="menuitem"
                      @click="downloadManagerEffectiveness('csv')"
                    >
                      <i class="i-lucide-file-text size-4" />
                      <span>
                        {{
                          $t(
                            'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.EXPORT_CSV'
                          )
                        }}
                      </span>
                    </button>
                    <button
                      type="button"
                      class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-n-slate-11 hover:bg-n-alpha-1 hover:text-n-slate-12"
                      role="menuitem"
                      @click="downloadManagerEffectiveness('excel')"
                    >
                      <i class="i-lucide-file-spreadsheet size-4" />
                      <span>
                        {{
                          $t(
                            'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.EXPORT_EXCEL'
                          )
                        }}
                      </span>
                    </button>
                  </div>
                </div>
              </div>

              <div
                v-if="managerRows.length"
                class="mt-4 overflow-x-auto rounded-xl border border-n-container"
              >
                <table class="w-full min-w-[108rem] text-left text-sm">
                  <thead class="bg-n-alpha-1 text-xs text-n-slate-10">
                    <tr>
                      <th
                        class="sticky left-0 z-10 bg-n-alpha-1 px-4 py-3 font-medium"
                      >
                        {{
                          $t(
                            'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.MANAGER'
                          )
                        }}
                      </th>
                      <th
                        v-for="column in effectivenessNumberColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right font-medium"
                      >
                        {{ column.label }}
                      </th>
                      <th
                        v-for="column in effectivenessPercentColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right font-medium"
                      >
                        {{ column.label }}
                      </th>
                      <th class="px-3 py-3 text-right font-medium">
                        {{
                          $t(
                            'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.DEAL_AMOUNT'
                          )
                        }}
                      </th>
                      <th class="px-3 py-3 text-right font-medium">
                        {{
                          $t(
                            'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.WON_AMOUNT'
                          )
                        }}
                      </th>
                      <th class="px-3 py-3 text-right font-medium">
                        {{
                          $t(
                            'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.COLUMNS.PAYMENTS'
                          )
                        }}
                      </th>
                      <th
                        v-for="column in effectivenessMoneyColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right font-medium"
                      >
                        {{ column.label }}
                      </th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-n-weak">
                    <tr
                      v-for="row in managerRows"
                      :key="row.ownerId || 'unassigned'"
                      class="bg-n-solid-2 align-top text-n-slate-11"
                    >
                      <td class="sticky left-0 z-10 bg-n-solid-2 px-4 py-3">
                        <div class="flex flex-col">
                          <span class="font-medium text-n-slate-12">
                            {{
                              row.ownerName || $t('CRM_DEAL_REPORTS.UNASSIGNED')
                            }}
                          </span>
                          <span class="text-xs text-n-slate-10">
                            {{
                              $t(
                                'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.ROW_HELPER',
                                {
                                  won: formatNumber(row.wonCount),
                                  badRate: formatPercent(row.badRate),
                                }
                              )
                            }}
                          </span>
                        </div>
                      </td>
                      <td
                        v-for="column in effectivenessNumberColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right tabular-nums"
                      >
                        {{ formatNumber(row[column.key]) }}
                      </td>
                      <td
                        v-for="column in effectivenessPercentColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right tabular-nums"
                      >
                        {{ formatPercent(row[column.key]) }}
                      </td>
                      <td class="px-3 py-3 text-right tabular-nums">
                        {{ formatMoney(row.dealAmountMinor) }}
                      </td>
                      <td class="px-3 py-3 text-right tabular-nums">
                        {{ formatMoney(row.wonAmountMinor) }}
                      </td>
                      <td class="px-3 py-3 text-right tabular-nums">
                        {{ formatMoney(row.paymentsAmountMinor) }}
                      </td>
                      <td
                        v-for="column in effectivenessMoneyColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right tabular-nums"
                      >
                        {{ formatMoney(row[column.key]) }}
                      </td>
                    </tr>
                  </tbody>
                  <tfoot
                    class="border-t border-n-container bg-n-alpha-1 font-semibold text-n-slate-12"
                  >
                    <tr>
                      <td class="sticky left-0 z-10 bg-n-alpha-1 px-4 py-3">
                        {{ $t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.TOTAL') }}
                      </td>
                      <td
                        v-for="column in effectivenessNumberColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right tabular-nums"
                      >
                        {{ formatNumber(managerTotals[column.key]) }}
                      </td>
                      <td
                        v-for="column in effectivenessPercentColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right tabular-nums"
                      >
                        {{ formatPercent(managerTotals[column.key]) }}
                      </td>
                      <td class="px-3 py-3 text-right tabular-nums">
                        {{ formatMoney(managerTotals.dealAmountMinor) }}
                      </td>
                      <td class="px-3 py-3 text-right tabular-nums">
                        {{ formatMoney(managerTotals.wonAmountMinor) }}
                      </td>
                      <td class="px-3 py-3 text-right tabular-nums">
                        {{ formatMoney(managerTotals.paymentsAmountMinor) }}
                      </td>
                      <td
                        v-for="column in effectivenessMoneyColumns"
                        :key="column.key"
                        class="px-3 py-3 text-right tabular-nums"
                      >
                        {{ formatMoney(managerTotals[column.key]) }}
                      </td>
                    </tr>
                  </tfoot>
                </table>
              </div>

              <p
                v-else
                class="mt-4 rounded-xl bg-n-alpha-1 p-6 text-center text-sm text-n-slate-10"
              >
                {{ $t('REPORT.NO_ENOUGH_DATA') }}
              </p>
            </section>

            <section
              class="rounded-xl border border-n-container bg-n-alpha-1 p-4"
            >
              <div class="flex gap-3">
                <i class="i-lucide-info mt-0.5 text-n-blue-10" />
                <div class="space-y-1 text-xs leading-5 text-n-slate-10">
                  <p>
                    {{
                      $t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.NOTES.LEADS')
                    }}
                  </p>
                  <p>
                    {{
                      $t('CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.NOTES.CALLS', {
                        seconds: callDurationThresholdSeconds,
                      })
                    }}
                  </p>
                  <p>
                    {{
                      $t(
                        'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.NOTES.MEETINGS'
                      )
                    }}
                  </p>
                  <p>
                    {{
                      $t(
                        'CRM_DEAL_REPORTS.MANAGER_EFFECTIVENESS.NOTES.PAYMENTS'
                      )
                    }}
                  </p>
                </div>
              </div>
            </section>
          </div>

          <div
            v-else-if="activeSection === 'forecast'"
            class="mt-5 grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,1fr)_22rem]"
          >
            <section class="rounded-xl border border-n-container p-4">
              <h4 class="text-sm font-semibold text-n-slate-12">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.FORECAST_AMOUNT.TITLE') }}
              </h4>
              <p class="mt-1 text-xs leading-5 text-n-slate-10">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.FORECAST_AMOUNT.DESCRIPTION') }}
              </p>
              <div class="mt-4 h-80">
                <LineChart
                  v-if="hasDatasetData(forecastCollection)"
                  :collection="forecastCollection"
                  :chart-options="lineMoneyOptions"
                />
                <p
                  v-else
                  class="flex h-full items-center justify-center text-sm text-n-slate-10"
                >
                  {{ $t('REPORT.NO_ENOUGH_DATA') }}
                </p>
              </div>
            </section>

            <aside class="flex flex-col gap-4">
              <div class="rounded-xl border border-n-container p-4">
                <h4 class="text-sm font-semibold text-n-slate-12">
                  {{ $t('CRM_DEAL_REPORTS.LABELS.FORECAST_HEALTH') }}
                </h4>
                <div class="mt-4 space-y-3">
                  <div
                    v-for="item in forecastSummaryCards"
                    :key="item.key"
                    class="rounded-lg bg-n-alpha-1 px-3 py-2"
                  >
                    <p class="text-xs text-n-slate-10">
                      {{ item.label }}
                    </p>
                    <p class="mt-1 text-sm font-semibold text-n-slate-12">
                      {{ item.value }}
                    </p>
                  </div>
                </div>
              </div>

              <div class="rounded-xl border border-n-container p-4">
                <h4 class="text-sm font-semibold text-n-slate-12">
                  {{ $t('CRM_DEAL_REPORTS.CHARTS.WON_LOST.TITLE') }}
                </h4>
                <p class="mt-1 text-xs leading-5 text-n-slate-10">
                  {{ $t('CRM_DEAL_REPORTS.CHARTS.WON_LOST.DESCRIPTION') }}
                </p>
                <div class="mt-4 h-52">
                  <BarChart
                    v-if="hasDatasetData(wonLostCollection)"
                    :collection="wonLostCollection"
                    :chart-options="stackedCountOptions"
                  />
                  <p
                    v-else
                    class="flex h-full items-center justify-center text-sm text-n-slate-10"
                  >
                    {{ $t('REPORT.NO_ENOUGH_DATA') }}
                  </p>
                </div>
              </div>
            </aside>
          </div>

          <div
            v-else-if="activeSection === 'sources'"
            class="mt-5 grid grid-cols-1 gap-5 xl:grid-cols-[24rem_minmax(0,1fr)]"
          >
            <section class="rounded-xl border border-n-container p-4">
              <h4 class="text-sm font-semibold text-n-slate-12">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.SOURCE_MIX.TITLE') }}
              </h4>
              <p class="mt-1 text-xs leading-5 text-n-slate-10">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.SOURCE_MIX.DESCRIPTION') }}
              </p>
              <div class="relative mt-4 h-80">
                <DoughnutChart
                  v-if="hasDatasetData(sourceDoughnutCollection)"
                  :collection="sourceDoughnutCollection"
                  :chart-options="doughnutOptions"
                />
                <div
                  v-if="hasDatasetData(sourceDoughnutCollection)"
                  class="pointer-events-none absolute inset-x-0 top-24 flex flex-col items-center"
                >
                  <span class="text-2xl font-semibold text-n-slate-12">
                    {{ formatNumber(totalSourceDeals) }}
                  </span>
                  <span class="text-xs text-n-slate-10">
                    {{ $t('CRM_DEAL_REPORTS.LABELS.DEALS') }}
                  </span>
                </div>
                <p
                  v-else
                  class="flex h-full items-center justify-center text-sm text-n-slate-10"
                >
                  {{ $t('REPORT.NO_ENOUGH_DATA') }}
                </p>
              </div>
            </section>

            <section class="rounded-xl border border-n-container p-4">
              <div class="flex flex-col gap-1">
                <h4 class="text-sm font-semibold text-n-slate-12">
                  {{ $t('CRM_DEAL_REPORTS.TABLES.SOURCE.TITLE') }}
                </h4>
                <p class="text-xs leading-5 text-n-slate-10">
                  {{ $t('CRM_DEAL_REPORTS.CHARTS.SOURCE.DESCRIPTION') }}
                </p>
              </div>

              <div class="mt-4 grid grid-cols-1 gap-5 lg:grid-cols-2">
                <div class="h-72">
                  <BarChart
                    v-if="hasDatasetData(sourceOutcomeCollection)"
                    :collection="sourceOutcomeCollection"
                    :chart-options="stackedCountOptions"
                  />
                  <p
                    v-else
                    class="flex h-full items-center justify-center text-sm text-n-slate-10"
                  >
                    {{ $t('REPORT.NO_ENOUGH_DATA') }}
                  </p>
                </div>

                <div class="space-y-3">
                  <div
                    v-for="source in sourceRows"
                    :key="source.source"
                    class="rounded-xl bg-n-alpha-1 p-3"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0">
                        <div class="flex items-center gap-2">
                          <span
                            class="size-2 rounded-full"
                            :style="{ backgroundColor: source.color }"
                          />
                          <p
                            class="truncate text-sm font-medium text-n-slate-12"
                          >
                            {{ source.label }}
                          </p>
                        </div>
                        <p class="mt-1 text-xs text-n-slate-10">
                          {{
                            $t('CRM_DEAL_REPORTS.TABLES.SOURCE.ROW_HELPER', {
                              won: formatNumber(source.wonCount),
                              lost: formatNumber(source.lostCount),
                              winRate: formatPercent(source.winRate),
                            })
                          }}
                        </p>
                      </div>
                      <div class="text-right">
                        <p class="text-sm font-semibold text-n-slate-12">
                          {{ formatPercent(source.share) }}
                        </p>
                        <p class="text-xs text-n-slate-10">
                          {{ formatMoney(source.wonAmountMinor) }}
                        </p>
                      </div>
                    </div>
                    <div class="mt-3 h-2 rounded-full bg-n-slate-4">
                      <div
                        class="h-2 rounded-full"
                        :style="{
                          width: `${source.shareWidth}%`,
                          backgroundColor: source.color,
                        }"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <div v-else class="mt-5 grid grid-cols-1 gap-5 xl:grid-cols-2">
            <section class="rounded-xl border border-n-container p-4">
              <h4 class="text-sm font-semibold text-n-slate-12">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.OWNER_AMOUNT.TITLE') }}
              </h4>
              <p class="mt-1 text-xs leading-5 text-n-slate-10">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.OWNER_AMOUNT.DESCRIPTION') }}
              </p>
              <div class="mt-4 h-72">
                <BarChart
                  v-if="hasDatasetData(ownerCollection)"
                  :collection="ownerCollection"
                  :chart-options="moneyAxisOptions"
                />
                <p
                  v-else
                  class="flex h-full items-center justify-center text-sm text-n-slate-10"
                >
                  {{ $t('REPORT.NO_ENOUGH_DATA') }}
                </p>
              </div>

              <div class="mt-4 space-y-3">
                <div
                  v-for="owner in ownerRows"
                  :key="owner.ownerId || owner.label"
                  class="rounded-xl bg-n-alpha-1 p-3"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="truncate text-sm font-medium text-n-slate-12">
                        {{ owner.label }}
                      </p>
                      <p class="mt-1 text-xs text-n-slate-10">
                        {{
                          $t('CRM_DEAL_REPORTS.TABLES.TEAM.ROW_HELPER', {
                            deals: formatNumber(owner.dealCount),
                            won: formatNumber(owner.wonCount),
                            winRate: formatPercent(owner.winRate),
                          })
                        }}
                      </p>
                    </div>
                    <p class="text-sm font-semibold text-n-slate-12">
                      {{ owner.amountLabel }}
                    </p>
                  </div>
                  <div class="mt-3 h-2 rounded-full bg-n-slate-4">
                    <div
                      class="h-2 rounded-full bg-n-purple-9"
                      :style="{ width: `${owner.amountWidth}%` }"
                    />
                  </div>
                </div>
              </div>
            </section>

            <section class="rounded-xl border border-n-container p-4">
              <h4 class="text-sm font-semibold text-n-slate-12">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.AGING.TITLE') }}
              </h4>
              <p class="mt-1 text-xs leading-5 text-n-slate-10">
                {{ $t('CRM_DEAL_REPORTS.CHARTS.AGING.DESCRIPTION') }}
              </p>
              <div class="mt-4 space-y-3">
                <div
                  v-for="bucket in agingRows"
                  :key="bucket.key"
                  class="rounded-xl bg-n-alpha-1 p-3"
                >
                  <div class="flex items-center justify-between gap-3">
                    <p class="text-sm font-medium text-n-slate-12">
                      {{ bucket.label }}
                    </p>
                    <p class="text-sm font-semibold text-n-slate-12">
                      {{ formatNumber(bucket.dealCount) }}
                    </p>
                  </div>
                  <div class="mt-3 h-2 rounded-full bg-n-slate-4">
                    <div
                      class="h-2 rounded-full bg-n-orange-9"
                      :style="{ width: `${bucket.width}%` }"
                    />
                  </div>
                </div>
              </div>
            </section>
          </div>
        </section>
      </template>
    </template>
  </div>
</template>
