<script setup>
import { computed, onMounted, reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import format from 'date-fns/format';

import CrmReportsAPI from 'dashboard/api/crm/reports';
import { normalizeMeta, normalizePayload } from 'dashboard/stores/crm/shared';
import { taskCatalogLabel } from 'dashboard/components-next/CRM/taskCatalogLabels';

const props = defineProps({
  from: {
    type: Number,
    default: null,
  },
  to: {
    type: Number,
    default: null,
  },
});

const { t, locale } = useI18n();

const makeState = () => ({
  data: null,
  error: null,
  loading: false,
  meta: {},
  requestId: 0,
});

const reports = reactive({
  stageDurations: makeState(),
  taskResults: makeState(),
  dealsWithoutNextAction: makeState(),
});

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);
const number = value =>
  new Intl.NumberFormat(localeCode.value, { maximumFractionDigits: 0 }).format(
    Number(value || 0)
  );
const decimalNumber = value =>
  new Intl.NumberFormat(localeCode.value, { maximumFractionDigits: 1 }).format(
    value
  );

const lifecycleLabel = lifecycle => {
  switch (lifecycle) {
    case 'completed':
      return t('CRM_DEAL_REPORTS.ACTIVITY.COMPLETED');
    case 'cancelled':
      return t('CRM_DEAL_REPORTS.ACTIVITY.CANCELLED');
    default:
      return lifecycle || t('CRM_DEAL_REPORTS.ACTIVITY.UNKNOWN');
  }
};

const taskDimension = (value, kind) =>
  taskCatalogLabel(kind, value, t) ||
  value?.code ||
  (value?.kind === 'not_configured'
    ? t('CRM_DEAL_REPORTS.ACTIVITY.NOT_CONFIGURED')
    : t('CRM_DEAL_REPORTS.ACTIVITY.UNKNOWN'));

const dimensionIdentity = value => {
  if (value?.id !== null && value?.id !== undefined) {
    return JSON.stringify(['id', value.id]);
  }

  return JSON.stringify(['legacy', value?.kind ?? null, value?.code ?? null]);
};

const stageOutcomeLabel = outcome => {
  switch (outcome) {
    case 'open':
      return t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_OUTCOMES.OPEN');
    case 'won':
      return t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_OUTCOMES.WON');
    case 'lost':
      return t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_OUTCOMES.LOST');
    default:
      return t('CRM_DEAL_REPORTS.ACTIVITY.UNKNOWN');
  }
};

const noActionCountFrom = rows => {
  const value = rows?.[0]?.noActionCount;
  if (value === null || value === undefined || value === '') return null;

  const count = Number(value);
  return Number.isFinite(count) ? count : null;
};

const aggregateCoverage = row => {
  if (row.unknownCount > 0) return 'unknown';
  if (row.estimatedCount > 0) return 'estimated';

  return 'exact';
};

const stageRows = computed(() => reports.stageDurations.data?.rows || []);
const stageRowKey = row =>
  JSON.stringify([
    row.pipelineId,
    row.pipelineName,
    row.stageId,
    row.stageName,
    row.stageOutcome,
  ]);
const taskRows = computed(() => {
  const groupedRows = new Map();

  (reports.taskResults.data?.rows || []).forEach(row => {
    const taskTypeLabel = taskDimension(row.taskType, 'type');
    const taskOutcomeLabel = taskDimension(row.taskOutcome, 'outcome');
    const lifecycleType = row.lifecycleType;
    const key = JSON.stringify([
      dimensionIdentity(row.taskType),
      dimensionIdentity(row.taskOutcome),
      row.lifecycleType,
    ]);
    const groupedRow = groupedRows.get(key) || {
      key,
      taskTypeLabel,
      taskOutcomeLabel,
      lifecycleType,
      lifecycleTypeLabel: lifecycleLabel(lifecycleType),
      occurrenceCount: 0,
      exactCount: 0,
      estimatedCount: 0,
      unknownCount: 0,
    };

    groupedRow.occurrenceCount += Number(row.occurrenceCount || 0);
    groupedRow.exactCount += Number(row.exactCount || 0);
    groupedRow.estimatedCount += Number(row.estimatedCount || 0);
    groupedRow.unknownCount += Number(row.unknownCount || 0);
    groupedRows.set(key, groupedRow);
  });

  return [...groupedRows.values()].map(row => ({
    ...row,
    coverage: aggregateCoverage(row),
  }));
});
const sumRows = (rows, valueFor) =>
  rows.reduce((total, row) => {
    if (total === null) return null;

    const value = Number(valueFor(row));
    return Number.isFinite(value) ? total + value : null;
  }, 0);
const stagePassCount = computed(() => {
  if (reports.stageDurations.data === null) return null;

  return sumRows(stageRows.value, row => row.totalCount);
});
const completedEventCount = computed(() => {
  if (reports.taskResults.data === null) return null;

  return sumRows(
    taskRows.value.filter(row => row.lifecycleType === 'completed'),
    row => row.occurrenceCount
  );
});
const cancelledEventCount = computed(() => {
  if (reports.taskResults.data === null) return null;

  return sumRows(
    taskRows.value.filter(row => row.lifecycleType === 'cancelled'),
    row => row.occurrenceCount
  );
});
const taskLifecycleCounts = computed(() => {
  const countFor = lifecycleType =>
    sumRows(
      taskRows.value.filter(row => row.lifecycleType === lifecycleType),
      row => row.occurrenceCount
    ) ?? 0;

  return {
    completed: countFor('completed'),
    cancelled: countFor('cancelled'),
    other:
      sumRows(
        taskRows.value.filter(
          row => !['completed', 'cancelled'].includes(row.lifecycleType)
        ),
        row => row.occurrenceCount
      ) ?? 0,
  };
});
const taskEventCount = computed(() => {
  if (reports.taskResults.data === null) return null;

  return sumRows(taskRows.value, row => row.occurrenceCount);
});
const taskMaxOccurrenceCount = computed(() =>
  Math.max(0, ...taskRows.value.map(row => Number(row.occurrenceCount) || 0))
);
const taskBarWidth = value => {
  if (!taskMaxOccurrenceCount.value) return '0%';

  const ratio = Math.max(0, Number(value) || 0) / taskMaxOccurrenceCount.value;
  return `${Math.min(100, ratio * 100).toFixed(1)}%`;
};
const metricValue = value => (value === null ? '—' : number(value));
const stagePassLabel = value =>
  t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_ROW_PASSES', {
    count: number(value),
  });
const coverageTone = coverage => {
  if (coverage === 'exact') return 'exact';
  if (coverage === 'estimated') return 'estimated';
  if (coverage === 'unknown_before') return 'estimated';

  return 'unknown';
};
const donutCircumference = 2 * Math.PI * 42;
const donutSegments = computed(() => {
  if (!taskEventCount.value) return [];

  const categories = [
    {
      key: 'completed',
      label: t('CRM_DEAL_REPORTS.ACTIVITY.COMPLETED'),
      count: taskLifecycleCounts.value.completed,
      color: '#159B8B',
    },
    {
      key: 'cancelled',
      label: t('CRM_DEAL_REPORTS.ACTIVITY.CANCELLED'),
      count: taskLifecycleCounts.value.cancelled,
      color: '#ED7969',
    },
    {
      key: 'other',
      label: t('CRM_DEAL_REPORTS.ACTIVITY.OTHER_LIFECYCLE'),
      count: taskLifecycleCounts.value.other,
      color: '#D9A340',
    },
  ];
  let offset = 0;

  return categories
    .filter(category => category.count > 0)
    .map(category => {
      const length =
        (category.count / taskEventCount.value) * donutCircumference;
      const segment = {
        ...category,
        length,
        offset,
        dashArray: String(length) + ' ' + String(donutCircumference - length),
        dashOffset: String(-offset),
      };
      offset += length;
      return segment;
    });
});
const donutLabel = computed(() =>
  t('CRM_DEAL_REPORTS.ACTIVITY.TASK_DISTRIBUTION_ARIA', {
    total: number(taskEventCount.value || 0),
    completed: number(taskLifecycleCounts.value.completed),
    cancelled: number(taskLifecycleCounts.value.cancelled),
    other: number(taskLifecycleCounts.value.other),
  })
);
const stageScale = computed(() => {
  const maximumSeconds = stageRows.value.reduce((maximum, row) => {
    const median = Number(row.medianDurationSeconds);
    const p75 = Number(row.p75DurationSeconds);
    const rowMaximum = Math.max(
      Number.isFinite(median) ? median : 0,
      Number.isFinite(p75) ? p75 : 0
    );
    return Math.max(maximum, rowMaximum);
  }, 0);
  const units = [
    { divisor: 86_400, label: t('CRM_DEAL_REPORTS.ACTIVITY.UNITS.DAYS') },
    { divisor: 3_600, label: t('CRM_DEAL_REPORTS.ACTIVITY.UNITS.HOURS') },
    { divisor: 60, label: t('CRM_DEAL_REPORTS.ACTIVITY.UNITS.MINUTES') },
    { divisor: 1, label: t('CRM_DEAL_REPORTS.ACTIVITY.UNITS.SECONDS') },
  ];
  const unit =
    units.find(candidate => maximumSeconds >= candidate.divisor) || units[3];
  const rawMaximum = maximumSeconds / unit.divisor;
  const targetStep = Math.max(rawMaximum / 4, 0.1);
  const magnitude = 10 ** Math.floor(Math.log10(targetStep));
  const normalizedStep = targetStep / magnitude;
  let stepFactor = 10;
  if (normalizedStep <= 1) stepFactor = 1;
  else if (normalizedStep <= 2) stepFactor = 2;
  else if (normalizedStep <= 5) stepFactor = 5;
  const step = stepFactor * magnitude;
  const maximum = Math.max(step, Math.ceil(rawMaximum / step) * step);

  return { ...unit, maximum };
});
const stageAxisTicks = computed(() =>
  Array.from(
    { length: 5 },
    (_, index) =>
      `${decimalNumber((stageScale.value.maximum * index) / 4)} ${stageScale.value.label}`
  )
);
const stageDurationInScale = value => {
  if (
    value === null ||
    value === undefined ||
    !Number.isFinite(Number(value))
  ) {
    return t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY_VALUE');
  }

  const scaled = Math.max(0, Number(value)) / stageScale.value.divisor;
  if (scaled > 0 && scaled < 0.05) {
    return `<${decimalNumber(0.1)} ${stageScale.value.label}`;
  }

  return `${decimalNumber(scaled)} ${stageScale.value.label}`;
};
const stageBarWidth = value => {
  if (
    value === null ||
    value === undefined ||
    !Number.isFinite(Number(value))
  ) {
    return '0%';
  }

  const scaleSeconds = stageScale.value.maximum * stageScale.value.divisor;
  const ratio = scaleSeconds > 0 ? Number(value) / scaleSeconds : 0;
  return `${Math.min(100, Math.max(0, ratio * 100)).toFixed(1)}%`;
};
const snapshotRows = computed(
  () => reports.dealsWithoutNextAction.data?.rows || []
);
const noActionCount = computed(() => {
  const value = snapshotRows.value[0]?.noActionCount;
  if (value === null || value === undefined || value === '') return null;

  const count = Number(value);
  return Number.isFinite(count) ? count : null;
});

const reportDates = computed(() => {
  if (!props.from || !props.to) return null;

  const dateFor = timestamp => {
    const date = new Date(Number(timestamp) * 1000);
    return Number.isNaN(date.getTime()) ? null : format(date, 'yyyy-MM-dd');
  };
  const fromDate = dateFor(props.from);
  const toDate = dateFor(props.to);

  if (!fromDate || !toDate) return null;

  return {
    as_of_date: toDate,
    from_date: fromDate,
    to_date: toDate,
  };
});

const dateTime = (value, timezone) => {
  if (!value) return t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY_VALUE');

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY_VALUE');
  }

  return new Intl.DateTimeFormat(localeCode.value, {
    dateStyle: 'medium',
    timeStyle: 'short',
    ...(timezone ? { timeZone: timezone } : {}),
  }).format(date);
};

const dateOnly = (value, timezone) => {
  if (!value) return t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY_VALUE');

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY_VALUE');
  }

  return new Intl.DateTimeFormat(localeCode.value, {
    dateStyle: 'medium',
    ...(timezone ? { timeZone: timezone } : {}),
  }).format(date);
};

const coverageLabel = (coverage, reliableSince, timezone) => {
  switch (coverage) {
    case 'exact':
      return t('CRM_DEAL_REPORTS.ACTIVITY.COVERAGE.EXACT');
    case 'estimated':
      return t('CRM_DEAL_REPORTS.ACTIVITY.COVERAGE.ESTIMATED');
    case 'unknown_before':
      return reliableSince
        ? t('CRM_DEAL_REPORTS.ACTIVITY.COVERAGE.UNKNOWN_BEFORE', {
            date: dateOnly(reliableSince, timezone),
          })
        : t('CRM_DEAL_REPORTS.ACTIVITY.COVERAGE.UNKNOWN');
    case 'unknown':
      return t('CRM_DEAL_REPORTS.ACTIVITY.COVERAGE.UNKNOWN');
    default:
      return t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY_VALUE');
  }
};

const errorMessage = error =>
  error === 'unavailable'
    ? t('CRM_DEAL_REPORTS.ACTIVITY.ERRORS.UNAVAILABLE')
    : t('CRM_DEAL_REPORTS.ACTIVITY.ERRORS.FAILED');

const loadReport = async (key, request) => {
  const report = reports[key];
  const requestId = report.requestId + 1;
  report.requestId = requestId;
  report.data = null;
  report.meta = {};
  report.error = null;
  report.loading = true;

  try {
    const response = await request();
    if (report.requestId !== requestId) return;

    const payload = normalizePayload(response?.data);
    const rows = payload?.rows;
    const validRows = Array.isArray(rows);
    const validSnapshot =
      key !== 'dealsWithoutNextAction' ||
      (validRows && rows.length > 0 && noActionCountFrom(rows) !== null);

    if (!validRows || !validSnapshot) {
      throw new Error('Unexpected CRM report response');
    }

    report.data = payload;
    report.meta = normalizeMeta(response?.data);
  } catch (error) {
    if (report.requestId !== requestId) return;
    const status = error?.response?.status;
    report.error = [404, 501].includes(status) ? 'unavailable' : 'failed';
  } finally {
    if (report.requestId === requestId) report.loading = false;
  }
};

const loadStageDurations = () => {
  if (!reportDates.value) return;

  loadReport('stageDurations', () =>
    CrmReportsAPI.stageDurations(reportDates.value)
  );
};

const loadTaskResults = () => {
  if (!reportDates.value) return;

  loadReport('taskResults', () => CrmReportsAPI.taskResults(reportDates.value));
};

const loadDealsWithoutNextAction = () =>
  loadReport('dealsWithoutNextAction', () =>
    CrmReportsAPI.dealsWithoutNextAction()
  );

const loadHistoricalReports = () => {
  if (!reportDates.value) return;

  loadStageDurations();
  loadTaskResults();
};

watch(() => [props.from, props.to], loadHistoricalReports, { immediate: true });

onMounted(loadDealsWithoutNextAction);
</script>

<template>
  <div class="activity-dashboard mt-5">
    <div class="activity-period-note">
      <i aria-hidden="true" />{{
        $t('CRM_DEAL_REPORTS.ACTIVITY.PERIOD_HELPER')
      }}
    </div>
    <section
      class="activity-kpis"
      :aria-label="$t('CRM_DEAL_REPORTS.ACTIVITY.KPI_GROUP_ARIA')"
    >
      <article
        class="activity-kpi activity-kpi--violet"
        data-testid="kpi-stage-passes"
      >
        <div class="activity-kpi-top">
          <div class="activity-kpi-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24">
              <path d="M4 17 10 11l4 4 6-8M14 7h6v6" />
            </svg>
          </div>
          <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_PERIOD_HINT') }}</span>
        </div>
        <strong class="activity-kpi-value">{{
          metricValue(stagePassCount)
        }}</strong>
        <span class="activity-kpi-label">{{
          $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_STAGE_PASSES')
        }}</span>
        <small>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_STAGE_NOTE') }}</small>
      </article>
      <article
        class="activity-kpi activity-kpi--teal"
        data-testid="kpi-completed-events"
      >
        <div class="activity-kpi-top">
          <div class="activity-kpi-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24">
              <path d="m5 12 4.2 4.2L19 6.5" />
              <circle cx="12" cy="12" r="9" />
            </svg>
          </div>
          <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_EVENT_HINT') }}</span>
        </div>
        <strong class="activity-kpi-value">{{
          metricValue(completedEventCount)
        }}</strong>
        <span class="activity-kpi-label">{{
          $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_COMPLETED_EVENTS')
        }}</span>
        <small>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_EVENT_NOTE') }}</small>
      </article>
      <article
        class="activity-kpi activity-kpi--coral"
        data-testid="kpi-cancelled-events"
      >
        <div class="activity-kpi-top">
          <div class="activity-kpi-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24">
              <path d="m8 8 8 8m0-8-8 8" />
              <circle cx="12" cy="12" r="9" />
            </svg>
          </div>
          <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_EVENT_HINT') }}</span>
        </div>
        <strong class="activity-kpi-value">{{
          metricValue(cancelledEventCount)
        }}</strong>
        <span class="activity-kpi-label">{{
          $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_CANCELLED_EVENTS')
        }}</span>
        <small>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_EVENT_NOTE') }}</small>
      </article>
      <article
        class="activity-kpi activity-kpi--amber"
        data-testid="kpi-no-action"
      >
        <div class="activity-kpi-top">
          <div class="activity-kpi-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24">
              <path d="M12 8v4m0 4h.01" />
              <circle cx="12" cy="12" r="9" />
            </svg>
          </div>
          <span class="activity-current-badge">
            {{ $t('CRM_DEAL_REPORTS.ACTIVITY.CURRENT_BADGE') }}
          </span>
        </div>
        <strong class="activity-kpi-value">{{
          metricValue(noActionCount)
        }}</strong>
        <span class="activity-kpi-label">{{
          $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_NO_ACTION')
        }}</span>
        <small>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_CURRENT_NOTE') }}</small>
      </article>
    </section>

    <div class="activity-analysis-grid">
      <section class="activity-panel" data-testid="stage-panel">
        <header class="activity-panel-header">
          <div>
            <div class="activity-title-line">
              <i class="activity-title-mark activity-title-mark--violet" />
              <h2>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.STAGES_TITLE') }}</h2>
            </div>
            <p class="activity-subtitle">
              {{ $t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_PLOT_TITLE') }}
            </p>
            <p
              v-if="
                reports.stageDurations.data &&
                reports.stageDurations.meta.reliableSince
              "
              class="activity-reliable-since"
            >
              {{
                $t('CRM_DEAL_REPORTS.ACTIVITY.RELIABLE_SINCE', {
                  date: dateOnly(
                    reports.stageDurations.meta.reliableSince,
                    reports.stageDurations.meta.timezone
                  ),
                })
              }}
            </p>
          </div>
          <span
            v-if="
              !reports.stageDurations.loading &&
              !reports.stageDurations.error &&
              reports.stageDurations.data
            "
            class="activity-coverage-pill"
            :data-coverage="coverageTone(reports.stageDurations.meta.coverage)"
          >
            {{
              coverageLabel(
                reports.stageDurations.meta.coverage,
                reports.stageDurations.meta.reliableSince,
                reports.stageDurations.meta.timezone
              )
            }}
          </span>
        </header>
        <details class="activity-help">
          <summary>
            {{ $t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_DEFINITION_LABEL') }}
          </summary>
          <p>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.STAGES_DESCRIPTION') }}</p>
        </details>

        <div
          v-if="reports.stageDurations.loading"
          class="activity-loading"
          role="status"
        >
          <i /><i /><i />
        </div>
        <div
          v-else-if="reports.stageDurations.error"
          class="activity-state activity-state--error"
        >
          <p>{{ errorMessage(reports.stageDurations.error) }}</p>
          <button
            type="button"
            class="activity-retry"
            @click="loadStageDurations"
          >
            {{ $t('CRM_DEAL_REPORTS.ACTIVITY.RETRY') }}
          </button>
        </div>
        <div v-else-if="!stageRows.length" class="activity-state">
          <p>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY') }}</p>
        </div>
        <div
          v-else
          class="activity-stage-plot"
          data-testid="stage-comparison-chart"
          :data-unit="stageScale.label"
        >
          <div class="activity-stage-axis">
            <span />
            <div
              :aria-label="
                $t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_AXIS_ARIA', {
                  unit: stageScale.label,
                })
              "
              data-testid="stage-time-axis"
            >
              <span v-for="(tick, index) in stageAxisTicks" :key="index">{{
                tick
              }}</span>
            </div>
          </div>
          <div class="activity-stage-rows">
            <article
              v-for="row in stageRows"
              :key="stageRowKey(row)"
              class="activity-stage-row"
              data-testid="stage-duration-row"
            >
              <div class="activity-stage-row-head">
                <div class="activity-stage-names">
                  <small>{{ row.pipelineName }}</small>
                  <strong>{{ row.stageName }}</strong>
                  <span>{{ stageOutcomeLabel(row.stageOutcome) }}</span>
                </div>
                <div class="activity-stage-meta">
                  <small>{{ stagePassLabel(row.totalCount) }}</small>
                  <span
                    class="activity-coverage-pill activity-coverage-pill--small"
                    :data-coverage="coverageTone(row.coverage)"
                  >
                    {{
                      coverageLabel(
                        row.coverage,
                        row.reliableSince,
                        reports.stageDurations.meta.timezone
                      )
                    }}
                  </span>
                </div>
              </div>
              <div class="activity-stage-measures">
                <div class="activity-stage-measure">
                  <span>{{
                    $t('CRM_DEAL_REPORTS.ACTIVITY.MEDIAN_SHORT')
                  }}</span>
                  <div class="activity-bar-track">
                    <i
                      v-if="
                        row.medianDurationSeconds !== null &&
                        row.medianDurationSeconds !== undefined &&
                        Number.isFinite(Number(row.medianDurationSeconds))
                      "
                      class="activity-bar-fill activity-bar-fill--median"
                      role="progressbar"
                      data-testid="stage-comparison-bar"
                      data-series="median"
                      :data-unit="stageScale.label"
                      :data-value="row.medianDurationSeconds"
                      :aria-label="
                        row.stageName +
                        ' ' +
                        $t('CRM_DEAL_REPORTS.ACTIVITY.MEDIAN')
                      "
                      aria-valuemin="0"
                      :aria-valuemax="stageScale.maximum"
                      :aria-valuenow="
                        Math.max(
                          0,
                          Number(row.medianDurationSeconds) / stageScale.divisor
                        )
                      "
                      :aria-valuetext="
                        stageDurationInScale(row.medianDurationSeconds)
                      "
                      :style="{
                        width: stageBarWidth(row.medianDurationSeconds),
                      }"
                    />
                  </div>
                  <strong>{{
                    stageDurationInScale(row.medianDurationSeconds)
                  }}</strong>
                </div>
                <div class="activity-stage-measure">
                  <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.P75_SHORT') }}</span>
                  <div class="activity-bar-track">
                    <i
                      v-if="
                        row.p75DurationSeconds !== null &&
                        row.p75DurationSeconds !== undefined &&
                        Number.isFinite(Number(row.p75DurationSeconds))
                      "
                      class="activity-bar-fill activity-bar-fill--p75"
                      role="progressbar"
                      data-testid="stage-comparison-bar"
                      data-series="p75"
                      :data-unit="stageScale.label"
                      :data-value="row.p75DurationSeconds"
                      :aria-label="
                        row.stageName +
                        ' ' +
                        $t('CRM_DEAL_REPORTS.ACTIVITY.P75')
                      "
                      aria-valuemin="0"
                      :aria-valuemax="stageScale.maximum"
                      :aria-valuenow="
                        Math.max(
                          0,
                          Number(row.p75DurationSeconds) / stageScale.divisor
                        )
                      "
                      :aria-valuetext="
                        stageDurationInScale(row.p75DurationSeconds)
                      "
                      :style="{ width: stageBarWidth(row.p75DurationSeconds) }"
                    />
                  </div>
                  <strong>{{
                    stageDurationInScale(row.p75DurationSeconds)
                  }}</strong>
                </div>
              </div>
              <details class="activity-row-help">
                <summary>
                  {{ $t('CRM_DEAL_REPORTS.ACTIVITY.COVERAGE_DETAILS') }}
                </summary>
                <div>
                  <span>{{
                    $t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_EXACT_COUNT', {
                      count: number(row.exactCount),
                    })
                  }}</span>
                  <span>{{
                    $t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_ESTIMATED_COUNT', {
                      count: number(row.estimatedCount),
                    })
                  }}</span>
                </div>
              </details>
            </article>
          </div>
          <div
            class="activity-legend"
            :aria-label="$t('CRM_DEAL_REPORTS.ACTIVITY.STAGE_SERIES_ARIA')"
          >
            <span>
              <i class="activity-legend-dot activity-legend-dot--median" />
              <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.MEDIAN_SHORT') }}</span>
            </span>
            <span>
              <i class="activity-legend-dot activity-legend-dot--p75" />
              <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.P75_SHORT') }}</span>
            </span>
            <span class="activity-unit">{{ stageScale.label }}</span>
          </div>
        </div>
      </section>
      <div class="activity-aside-column">
        <section class="activity-panel activity-task-mix">
          <header class="activity-panel-header">
            <div>
              <div class="activity-title-line">
                <i class="activity-title-mark activity-title-mark--teal" />
                <h2>
                  {{ $t('CRM_DEAL_REPORTS.ACTIVITY.TASK_DISTRIBUTION_TITLE') }}
                </h2>
              </div>
              <p class="activity-subtitle">
                {{ $t('CRM_DEAL_REPORTS.ACTIVITY.TASK_DISTRIBUTION_SUBTITLE') }}
              </p>
              <p
                v-if="
                  reports.taskResults.data &&
                  reports.taskResults.meta.reliableSince
                "
                class="activity-reliable-since"
              >
                {{
                  $t('CRM_DEAL_REPORTS.ACTIVITY.RELIABLE_SINCE', {
                    date: dateOnly(
                      reports.taskResults.meta.reliableSince,
                      reports.taskResults.meta.timezone
                    ),
                  })
                }}
              </p>
            </div>
            <span
              v-if="
                !reports.taskResults.loading &&
                !reports.taskResults.error &&
                reports.taskResults.data
              "
              class="activity-total-chip"
              data-testid="task-event-total"
            >
              {{ metricValue(taskEventCount) }}
            </span>
          </header>
          <div
            v-if="reports.taskResults.loading"
            class="activity-loading activity-loading--mix"
            role="status"
          >
            <i /><i />
          </div>
          <div
            v-else-if="reports.taskResults.error"
            class="activity-state activity-state--error"
          >
            <p>{{ errorMessage(reports.taskResults.error) }}</p>
            <button
              type="button"
              class="activity-retry"
              @click="loadTaskResults"
            >
              {{ $t('CRM_DEAL_REPORTS.ACTIVITY.RETRY') }}
            </button>
          </div>
          <div v-else-if="!taskEventCount" class="activity-state">
            <p>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.TASK_DISTRIBUTION_EMPTY') }}</p>
          </div>
          <div v-else class="activity-task-distribution">
            <div class="activity-donut-wrap">
              <svg
                class="activity-donut"
                viewBox="0 0 120 120"
                role="img"
                :aria-label="donutLabel"
                data-testid="task-event-donut"
              >
                <circle class="activity-donut-track" cx="60" cy="60" r="42" />
                <circle
                  v-for="segment in donutSegments"
                  :key="segment.key"
                  class="activity-donut-segment"
                  cx="60"
                  cy="60"
                  r="42"
                  :stroke="segment.color"
                  :stroke-dasharray="segment.dashArray"
                  :stroke-dashoffset="segment.dashOffset"
                />
              </svg>
              <div class="activity-donut-center" aria-hidden="true">
                <strong>{{ number(taskEventCount) }}</strong>
                <small>{{
                  $t('CRM_DEAL_REPORTS.ACTIVITY.LIFECYCLE_EVENTS')
                }}</small>
              </div>
            </div>
            <ul class="activity-donut-legend">
              <li>
                <span>
                  <i class="activity-dot activity-dot--completed" />
                  <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.COMPLETED') }}</span>
                </span>
                <strong>{{ number(taskLifecycleCounts.completed) }}</strong>
              </li>
              <li>
                <span>
                  <i class="activity-dot activity-dot--cancelled" />
                  <span>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.CANCELLED') }}</span>
                </span>
                <strong>{{ number(taskLifecycleCounts.cancelled) }}</strong>
              </li>
              <li>
                <span>
                  <i class="activity-dot activity-dot--other" />
                  <span>{{
                    $t('CRM_DEAL_REPORTS.ACTIVITY.OTHER_LIFECYCLE')
                  }}</span>
                </span>
                <strong>{{ number(taskLifecycleCounts.other) }}</strong>
              </li>
            </ul>
            <p class="activity-task-coverage">
              {{
                $t('CRM_DEAL_REPORTS.ACTIVITY.COVERAGE_LABEL', {
                  coverage: coverageLabel(
                    reports.taskResults.meta.coverage,
                    reports.taskResults.meta.reliableSince,
                    reports.taskResults.meta.timezone
                  ),
                })
              }}
            </p>
          </div>
        </section>
        <section
          class="activity-no-action-panel"
          data-testid="no-action-snapshot"
        >
          <div class="activity-no-action-main">
            <header class="activity-panel-header">
              <div>
                <div class="activity-title-line">
                  <i class="activity-title-mark activity-title-mark--coral" />
                  <h2>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.NO_ACTION_TITLE') }}</h2>
                  <span class="activity-current-badge">{{
                    $t('CRM_DEAL_REPORTS.ACTIVITY.CURRENT_BADGE')
                  }}</span>
                </div>
                <p class="activity-subtitle">
                  {{ $t('CRM_DEAL_REPORTS.ACTIVITY.NO_ACTION_SUBTITLE') }}
                </p>
              </div>
            </header>
            <div
              v-if="reports.dealsWithoutNextAction.loading"
              class="activity-no-action-loading"
              role="status"
            >
              <i /><i />
            </div>
            <div
              v-else-if="reports.dealsWithoutNextAction.error"
              class="activity-state activity-state--inline activity-state--error"
            >
              <p>{{ errorMessage(reports.dealsWithoutNextAction.error) }}</p>
              <button
                type="button"
                class="activity-retry activity-retry--coral"
                @click="loadDealsWithoutNextAction"
              >
                {{ $t('CRM_DEAL_REPORTS.ACTIVITY.RETRY') }}
              </button>
            </div>
            <div
              v-else-if="noActionCount !== null"
              class="activity-no-action-loaded"
            >
              <div class="activity-no-action-number">
                <strong>{{ number(noActionCount) }}</strong>
                <span>{{
                  $t('CRM_DEAL_REPORTS.ACTIVITY.NO_ACTION_COUNT_LABEL')
                }}</span>
              </div>
              <p
                v-if="noActionCount === 0"
                class="activity-no-action-clear activity-no-action-clear--success"
              >
                {{ $t('CRM_DEAL_REPORTS.ACTIVITY.NO_ACTION_EMPTY') }}
              </p>
              <p
                v-else
                class="activity-no-action-clear activity-no-action-clear--attention"
              >
                {{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_CURRENT_NOTE') }}
              </p>
              <p class="activity-snapshot-meta">
                {{
                  $t('CRM_DEAL_REPORTS.ACTIVITY.SNAPSHOT_META', {
                    reliability: coverageLabel(
                      reports.dealsWithoutNextAction.meta.reliability
                    ),
                    generatedAt: dateTime(
                      reports.dealsWithoutNextAction.meta.generatedAtLocal ||
                        reports.dealsWithoutNextAction.meta.generatedAt,
                      reports.dealsWithoutNextAction.meta.timezone
                    ),
                  })
                }}
              </p>
            </div>
          </div>
          <div class="activity-no-action-side">
            <details class="activity-help">
              <summary>
                {{ $t('CRM_DEAL_REPORTS.ACTIVITY.NO_ACTION_DEFINITION_LABEL') }}
              </summary>
              <p>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.NO_ACTION_DESCRIPTION') }}</p>
            </details>
            <div
              v-if="reports.dealsWithoutNextAction.data"
              class="activity-snapshot-coverage"
            >
              <span
                class="activity-coverage-pill"
                :data-coverage="
                  coverageTone(reports.dealsWithoutNextAction.meta.reliability)
                "
              >
                {{
                  coverageLabel(reports.dealsWithoutNextAction.meta.reliability)
                }}
              </span>
              <small>
                {{ $t('CRM_DEAL_REPORTS.ACTIVITY.KPI_CURRENT_NOTE') }}
              </small>
            </div>
          </div>
        </section>
      </div>
    </div>

    <section class="activity-panel">
      <header class="activity-panel-header">
        <div>
          <div class="activity-title-line">
            <i class="activity-title-mark activity-title-mark--violet" />
            <h2>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.TASKS_TITLE') }}</h2>
          </div>
          <p class="activity-subtitle">
            {{ $t('CRM_DEAL_REPORTS.ACTIVITY.TASK_RESULTS_SUBTITLE') }}
          </p>
        </div>
        <span
          v-if="
            !reports.taskResults.loading &&
            !reports.taskResults.error &&
            reports.taskResults.data
          "
          class="activity-total-chip activity-total-chip--violet"
        >
          {{ metricValue(taskEventCount) }}
        </span>
      </header>
      <div
        v-if="reports.taskResults.loading"
        class="activity-loading activity-loading--rows"
        role="status"
      >
        <i /><i />
      </div>
      <div
        v-else-if="reports.taskResults.error"
        class="activity-state activity-state--inline activity-state--error"
      >
        <p>{{ errorMessage(reports.taskResults.error) }}</p>
        <button type="button" class="activity-retry" @click="loadTaskResults">
          {{ $t('CRM_DEAL_REPORTS.ACTIVITY.RETRY') }}
        </button>
      </div>
      <div
        v-else-if="!taskRows.length"
        class="activity-state activity-state--inline"
      >
        <p>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.EMPTY') }}</p>
      </div>
      <div v-else class="activity-task-rows">
        <article
          v-for="row in taskRows"
          :key="row.key"
          class="activity-task-row"
          data-testid="task-result-row"
        >
          <div class="activity-task-row-head">
            <div class="activity-task-names">
              <strong>{{ row.taskTypeLabel }}</strong>
              <span>{{ row.taskOutcomeLabel }}</span>
            </div>
            <div class="activity-task-count">
              <strong data-testid="task-result-count">
                {{ number(row.occurrenceCount) }}
              </strong>
              <small>{{
                $t('CRM_DEAL_REPORTS.ACTIVITY.LIFECYCLE_EVENTS')
              }}</small>
            </div>
          </div>
          <div class="activity-task-meta">
            <span
              class="activity-lifecycle-pill"
              :data-lifecycle="row.lifecycleType"
            >
              {{ row.lifecycleTypeLabel }}
            </span>
            <span
              class="activity-coverage-pill activity-coverage-pill--small"
              :data-coverage="coverageTone(row.coverage)"
            >
              {{ coverageLabel(row.coverage) }}
            </span>
          </div>
          <div class="activity-task-track">
            <i
              role="progressbar"
              :aria-label="row.taskTypeLabel + ' ' + row.lifecycleTypeLabel"
              aria-valuemin="0"
              :aria-valuemax="Math.max(1, taskMaxOccurrenceCount)"
              :aria-valuenow="row.occurrenceCount"
              :aria-valuetext="number(row.occurrenceCount)"
              :style="{ width: taskBarWidth(row.occurrenceCount) }"
            />
          </div>
          <div class="activity-task-counts">
            <span>{{
              $t('CRM_DEAL_REPORTS.ACTIVITY.COUNT_EXACT', {
                count: number(row.exactCount),
              })
            }}</span>
            <span>{{
              $t('CRM_DEAL_REPORTS.ACTIVITY.COUNT_ESTIMATED', {
                count: number(row.estimatedCount),
              })
            }}</span>
            <span>{{
              $t('CRM_DEAL_REPORTS.ACTIVITY.COUNT_UNKNOWN', {
                count: number(row.unknownCount),
              })
            }}</span>
          </div>
        </article>
      </div>
      <details
        v-if="
          !reports.taskResults.loading &&
          !reports.taskResults.error &&
          reports.taskResults.data
        "
        class="activity-help activity-help--bottom"
      >
        <summary>
          {{ $t('CRM_DEAL_REPORTS.ACTIVITY.TASK_DEFINITION_LABEL') }}
        </summary>
        <p>{{ $t('CRM_DEAL_REPORTS.ACTIVITY.TASKS_DESCRIPTION') }}</p>
      </details>
    </section>
  </div>
</template>

<style scoped>
.activity-dashboard {
  --ink: #28243a;
  --muted: #777386;
  --line: #eceaf2;
  --violet: #6956df;
  --violet-soft: #f3f0ff;
  --teal: #168d80;
  --teal-soft: #e9f7f4;
  --coral: #e77868;
  --coral-soft: #fff0ed;
  --amber: #bb8618;
  --amber-soft: #fff7e4;
  color: var(--ink);
  display: flex;
  flex-direction: column;
  gap: 15px;
}
.activity-period-note {
  align-items: center;
  color: var(--muted);
  display: flex;
  font-size: 12px;
  gap: 10px;
  line-height: 1.45;
  margin: 0 2px;
}
.activity-period-note i {
  background: var(--violet);
  border-radius: 50%;
  box-shadow: 0 0 0 4px var(--violet-soft);
  flex: 0 0 7px;
  height: 7px;
}
.activity-period-note p {
  margin: 0;
}
.activity-kpis {
  display: grid;
  gap: 11px;
  grid-template-columns: repeat(4, minmax(0, 1fr));
}
.activity-kpi {
  background: #fff;
  border: 1px solid var(--line);
  border-radius: 15px;
  box-shadow: 0 5px 16px rgb(42 35 72 / 3%);
  min-width: 0;
  overflow: hidden;
  padding: 14px 15px;
  position: relative;
}
.activity-kpi:before {
  background: var(--accent);
  content: '';
  height: 3px;
  inset: 0 0 auto;
  position: absolute;
}
.activity-kpi--violet {
  --accent: var(--violet);
  --accent-soft: var(--violet-soft);
}
.activity-kpi--teal {
  --accent: var(--teal);
  --accent-soft: var(--teal-soft);
}
.activity-kpi--coral {
  --accent: var(--coral);
  --accent-soft: var(--coral-soft);
}
.activity-kpi--amber {
  --accent: var(--amber);
  --accent-soft: var(--amber-soft);
}
.activity-kpi-top {
  align-items: center;
  display: flex;
  gap: 7px;
  justify-content: space-between;
  min-height: 28px;
}
.activity-kpi-icon {
  align-items: center;
  background: var(--accent-soft);
  border-radius: 9px;
  color: var(--accent);
  display: inline-flex;
  font-size: 15px;
  font-weight: 700;
  height: 28px;
  justify-content: center;
  width: 28px;
}
.activity-kpi-icon svg {
  fill: none;
  height: 16px;
  stroke: currentColor;
  stroke-linecap: round;
  stroke-linejoin: round;
  stroke-width: 1.7;
  width: 16px;
}
.activity-kpi-top > span:last-child:not(.activity-kpi-icon) {
  color: #938fa1;
  font-size: 12px;
  font-weight: 650;
  text-align: right;
}
.activity-kpi-value {
  color: var(--accent);
  display: block;
  font-size: clamp(38px, 3.2vw, 44px);
  font-variant-numeric: tabular-nums;
  font-weight: 750;
  letter-spacing: -0.055em;
  line-height: 1;
  margin: 14px 0 7px;
}
.activity-kpi-label {
  display: block;
  font-size: 12px;
  font-weight: 720;
  line-height: 1.35;
}
.activity-kpi small {
  color: var(--muted);
  display: block;
  font-size: 12px;
  line-height: 1.4;
  margin-top: 5px;
}
.activity-current-badge {
  background: #fff0e7;
  border-radius: 99px;
  color: #b66d38;
  font-size: 12px;
  font-weight: 650;
  padding: 4px 7px;
}
.activity-analysis-grid {
  align-items: start;
  display: grid;
  gap: 13px;
  grid-template-columns: minmax(0, 1.65fr) minmax(270px, 0.8fr);
}
.activity-aside-column {
  display: flex;
  flex-direction: column;
  gap: 12px;
  min-width: 0;
}
.activity-panel,
.activity-no-action-panel {
  background: #fff;
  border: 1px solid var(--line);
  border-radius: 16px;
  box-shadow: 0 7px 22px rgb(42 35 72 / 3.5%);
  min-width: 0;
  padding: 17px;
}
.activity-panel-header {
  align-items: flex-start;
  display: flex;
  gap: 11px;
  justify-content: space-between;
}
.activity-title-line {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.activity-title-line h2 {
  color: var(--ink);
  font-size: 16px;
  font-weight: 740;
  letter-spacing: -0.018em;
  line-height: 1.3;
  margin: 0;
}
.activity-title-mark {
  border-radius: 4px;
  flex: 0 0 7px;
  height: 18px;
}
.activity-title-mark--violet {
  background: linear-gradient(180deg, #8d7bf4, var(--violet));
}
.activity-title-mark--teal {
  background: linear-gradient(180deg, #54c7b8, var(--teal));
}
.activity-title-mark--coral {
  background: linear-gradient(180deg, #f49c83, var(--coral));
}
.activity-subtitle {
  color: var(--muted);
  font-size: 12px;
  line-height: 1.45;
  margin: 5px 0 0 15px;
}
.activity-reliable-since {
  color: #9692a1;
  font-size: 12px;
  line-height: 1.4;
  margin: 3px 0 0 15px;
}
.activity-coverage-pill,
.activity-total-chip {
  align-items: center;
  border-radius: 99px;
  display: inline-flex;
  flex: 0 0 auto;
  font-size: 12px;
  font-weight: 650;
  line-height: 1.25;
  max-width: 100%;
  padding: 5px 7px;
}
.activity-coverage-pill {
  background: #f1f0f5;
  color: #777386;
}
.activity-coverage-pill[data-coverage='exact'] {
  background: var(--teal-soft);
  color: #16786e;
}
.activity-coverage-pill[data-coverage='estimated'] {
  background: var(--amber-soft);
  color: #926811;
}
.activity-coverage-pill[data-coverage='unknown'] {
  background: var(--coral-soft);
  color: #b65345;
}
.activity-coverage-pill--small {
  font-size: 12px;
  padding: 3px 5px;
}
.activity-total-chip {
  background: var(--teal-soft);
  color: #16786e;
  font-size: 12px;
  justify-content: center;
  min-width: 31px;
  padding: 6px 9px;
}
.activity-total-chip--violet {
  background: var(--violet-soft);
  color: #5543c8;
}
.activity-help {
  color: var(--muted);
  font-size: 12px;
  line-height: 1.5;
  margin-top: 10px;
}
.activity-help summary,
.activity-row-help summary {
  color: #777386;
  cursor: pointer;
  font-size: 12px;
  font-weight: 650;
  list-style-position: outside;
  margin-left: 12px;
  width: fit-content;
}
.activity-help p {
  margin: 5px 0 0 12px;
  max-width: 65ch;
}
.activity-stage-plot {
  margin-top: 15px;
}
.activity-stage-axis,
.activity-stage-measure {
  display: grid;
  gap: 8px;
  grid-template-columns: minmax(0, 116px) minmax(0, 1fr) 66px;
}
.activity-stage-axis {
  align-items: center;
  margin-bottom: 6px;
}
.activity-stage-axis > div {
  color: #9894a4;
  display: flex;
  font-size: 10px;
  grid-column: 2;
  justify-content: space-between;
  line-height: 1;
}
.activity-stage-rows {
  display: flex;
  flex-direction: column;
  gap: 7px;
}
.activity-stage-row {
  background: linear-gradient(120deg, #fbfaff, #fff 70%);
  border: 1px solid #f0edf7;
  border-radius: 11px;
  min-width: 0;
  padding: 9px 10px 7px;
}
.activity-stage-row-head {
  align-items: flex-start;
  display: flex;
  gap: 8px;
  justify-content: space-between;
  min-width: 0;
}
.activity-stage-names {
  align-items: baseline;
  display: flex;
  flex: 1 1 auto;
  flex-wrap: wrap;
  gap: 3px 7px;
  min-width: 0;
}
.activity-stage-names small {
  color: #898497;
  flex: 0 0 100%;
  font-size: 12px;
}
.activity-stage-names strong {
  color: var(--ink);
  font-size: 12px;
  font-weight: 700;
  overflow-wrap: anywhere;
}
.activity-stage-names > span {
  color: #7f7a8d;
  font-size: 12px;
}
.activity-stage-meta {
  align-items: flex-end;
  display: flex;
  flex: 0 0 auto;
  flex-direction: column;
  gap: 5px;
}
.activity-stage-meta > small {
  color: #777386;
  font-size: 12px;
  font-variant-numeric: tabular-nums;
  font-weight: 650;
}
.activity-stage-measures {
  display: flex;
  flex-direction: column;
  gap: 5px;
  margin-top: 9px;
}
.activity-stage-measure {
  align-items: center;
  min-height: 14px;
}
.activity-stage-measure > span:first-child {
  color: #817c90;
  font-size: 12px;
  line-height: 1.2;
}
.activity-bar-track,
.activity-task-track {
  background: #f0edf7;
  border-radius: 99px;
  height: 7px;
  min-width: 0;
  overflow: hidden;
  position: relative;
}
.activity-bar-fill {
  border-radius: inherit;
  display: block;
  height: 100%;
  transition: width 0.18s ease-out;
}
.activity-bar-fill--median {
  background: linear-gradient(90deg, #8775f0, #6551dc);
}
.activity-bar-fill--p75 {
  background: linear-gradient(90deg, #b1a4f7, #8e7be9);
}
.activity-stage-measure > strong {
  color: #4f4a60;
  font-size: 12px;
  font-variant-numeric: tabular-nums;
  font-weight: 700;
  text-align: right;
  white-space: nowrap;
}
.activity-row-help {
  border-top: 1px solid #f0edf7;
  margin-top: 7px;
  padding-top: 6px;
}
.activity-row-help > div {
  color: #777386;
  display: flex;
  flex-wrap: wrap;
  font-size: 12px;
  gap: 4px 10px;
  margin-top: 5px;
}
.activity-legend {
  align-items: center;
  color: #777386;
  display: flex;
  flex-wrap: wrap;
  font-size: 12px;
  gap: 7px 13px;
  margin: 11px 2px 0;
}
.activity-legend > span:not(.activity-unit) {
  align-items: center;
  display: inline-flex;
  gap: 5px;
}
.activity-legend-dot {
  border-radius: 99px;
  height: 6px;
  width: 13px;
}
.activity-legend-dot--median {
  background: var(--violet);
}
.activity-legend-dot--p75 {
  background: #a194ef;
}
.activity-unit {
  color: #9a96a7;
  margin-left: auto;
}
.activity-task-mix {
  display: flex;
  flex-direction: column;
}
.activity-task-distribution {
  align-items: center;
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  justify-content: center;
  margin-top: 11px;
}
.activity-donut-wrap {
  align-items: center;
  display: flex;
  height: 150px;
  justify-content: center;
  position: relative;
  width: 150px;
}
.activity-donut {
  height: 100%;
  overflow: visible;
  transform: rotate(-90deg);
  width: 100%;
}
.activity-donut circle {
  fill: none;
  stroke-width: 12;
}
.activity-donut-track {
  stroke: #f1eff6;
}
.activity-donut-segment {
  stroke-linecap: butt;
}
.activity-donut-center {
  align-items: center;
  display: flex;
  flex-direction: column;
  inset: 0;
  justify-content: center;
  pointer-events: none;
  position: absolute;
  text-align: center;
}
.activity-donut-center strong {
  color: var(--ink);
  font-size: 23px;
  font-variant-numeric: tabular-nums;
  font-weight: 750;
  letter-spacing: -0.05em;
  line-height: 1;
}
.activity-donut-center small {
  color: var(--muted);
  font-size: 12px;
  margin-top: 5px;
  max-width: 70px;
}
.activity-donut-legend {
  display: flex;
  flex-direction: column;
  gap: 7px;
  list-style: none;
  margin: 13px 0 0;
  padding: 0;
  width: min(100%, 230px);
}
.activity-donut-legend li,
.activity-donut-legend li > span {
  align-items: center;
  display: flex;
}
.activity-donut-legend li {
  color: #676276;
  font-size: 12px;
  gap: 10px;
  justify-content: space-between;
}
.activity-donut-legend li > span {
  gap: 7px;
}
.activity-donut-legend strong {
  color: var(--ink);
  font-variant-numeric: tabular-nums;
  font-weight: 700;
}
.activity-dot {
  border-radius: 50%;
  flex: 0 0 8px;
  height: 8px;
}
.activity-dot--completed {
  background: var(--teal);
}
.activity-dot--cancelled {
  background: var(--coral);
}
.activity-dot--other {
  background: #d9a340;
}
.activity-task-coverage {
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 12px;
  line-height: 1.4;
  margin: 14px 0 0;
  padding-top: 8px;
  text-align: center;
  width: 100%;
}
.activity-task-rows {
  display: grid;
  gap: 8px;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr));
  margin-top: 12px;
}
.activity-task-row {
  background: #fcfbfe;
  border: 1px solid #f0edf5;
  border-radius: 11px;
  min-width: 0;
  padding: 10px 11px;
}
.activity-task-row-head {
  align-items: flex-start;
  display: flex;
  gap: 9px;
  justify-content: space-between;
}
.activity-task-names {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}
.activity-task-names strong {
  color: var(--ink);
  font-size: 12px;
  font-weight: 700;
  overflow-wrap: anywhere;
}
.activity-task-names > span {
  color: var(--muted);
  font-size: 12px;
  overflow-wrap: anywhere;
}
.activity-task-count {
  align-items: flex-end;
  display: flex;
  flex: 0 0 auto;
  flex-direction: column;
  gap: 2px;
}
.activity-task-count strong {
  color: var(--violet);
  font-size: 18px;
  font-variant-numeric: tabular-nums;
  font-weight: 750;
  letter-spacing: -0.04em;
  line-height: 1;
}
.activity-task-count small {
  color: #9894a4;
  font-size: 12px;
}
.activity-task-meta {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
  margin-top: 7px;
}
.activity-lifecycle-pill {
  background: var(--teal-soft);
  border-radius: 99px;
  color: #16786e;
  font-size: 12px;
  font-weight: 650;
  padding: 4px 7px;
}
.activity-lifecycle-pill[data-lifecycle='cancelled'] {
  background: var(--coral-soft);
  color: #b65345;
}
.activity-lifecycle-pill[data-lifecycle]:not([data-lifecycle='completed']):not(
    [data-lifecycle='cancelled']
  ) {
  background: var(--amber-soft);
  color: #926811;
}
.activity-task-track {
  height: 5px;
  margin-top: 7px;
}
.activity-task-track > i {
  background: linear-gradient(90deg, #a99af5, var(--violet));
  border-radius: inherit;
  display: block;
  height: 100%;
}
.activity-task-counts {
  align-items: center;
  color: #777386;
  display: flex;
  flex-wrap: wrap;
  font-size: 12px;
  gap: 4px 9px;
  line-height: 1.4;
  margin-top: 7px;
}
.activity-help--bottom {
  border-top: 1px solid var(--line);
  margin-top: 12px;
  padding-top: 8px;
}
.activity-no-action-panel {
  background: radial-gradient(
      circle at 100% 0,
      rgb(246 171 146 / 15%),
      transparent 34%
    ),
    linear-gradient(115deg, #fff9f6, #fff 70%);
  border-color: #f4e5df;
  display: flex;
  flex-direction: column;
  gap: 11px;
  overflow: hidden;
  padding: 14px;
}
.activity-no-action-side {
  align-items: flex-start;
  border-top: 1px solid #f1e4df;
  display: flex;
  flex-direction: column;
  justify-content: center;
  padding: 10px 0 0 12px;
}
.activity-no-action-side .activity-help {
  margin-top: 0;
}
.activity-no-action-side .activity-help p {
  max-width: 40ch;
}
.activity-no-action-loaded {
  margin: 14px 0 0 15px;
}
.activity-no-action-number {
  align-items: baseline;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.activity-no-action-number strong {
  color: #d76856;
  font-size: clamp(34px, 5vw, 50px);
  font-variant-numeric: tabular-nums;
  font-weight: 760;
  letter-spacing: -0.06em;
  line-height: 0.95;
}
.activity-no-action-number span {
  color: #6e6570;
  font-size: 12px;
  font-weight: 650;
}
.activity-no-action-clear {
  color: #477d6e;
  font-size: 12px;
  line-height: 1.45;
  margin: 8px 0 0;
}
.activity-no-action-clear--attention {
  color: #a56d48;
}
.activity-snapshot-meta {
  color: #938b92;
  font-size: 12px;
  line-height: 1.45;
  margin: 7px 0 0;
}
.activity-snapshot-coverage {
  align-items: flex-start;
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin: 10px 0 0 12px;
}
.activity-snapshot-coverage small {
  color: #938b92;
  font-size: 12px;
}
.activity-retry {
  background: var(--violet-soft);
  border: 1px solid #e1dcfb;
  border-radius: 8px;
  color: #5543c8;
  cursor: pointer;
  font-size: 12px;
  font-weight: 700;
  padding: 6px 9px;
}
.activity-retry:hover {
  background: #eae6ff;
}
.activity-retry--coral {
  background: #fff0ed;
  border-color: #f5d8d2;
  color: #b65345;
}
.activity-retry--coral:hover {
  background: #ffe7e2;
}
.activity-state {
  align-items: center;
  color: var(--muted);
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 16px;
}
.activity-state p {
  flex: 1 1 100%;
  font-size: 12px;
  margin: 0;
}
.activity-state--error {
  color: #b65345;
}
.activity-state--inline {
  flex-wrap: nowrap;
}
.activity-state--inline p {
  flex: 1 1 auto;
}
.activity-loading {
  display: flex;
  flex-direction: column;
  gap: 9px;
  margin-top: 17px;
}
.activity-loading i,
.activity-no-action-loading i {
  animation: activity-pulse 1.5s ease-in-out infinite;
  background: #f1eff6;
  border-radius: 99px;
  display: block;
  height: 7px;
  width: 75%;
}
.activity-loading i:first-child {
  width: 92%;
}
.activity-loading i:last-child {
  width: 48%;
}
.activity-loading--mix {
  align-items: center;
  justify-content: center;
  min-height: 190px;
}
.activity-loading--mix i:first-child {
  border: 11px solid #f1eff6;
  border-radius: 50%;
  height: 112px;
  width: 112px;
}
.activity-loading--mix i:last-child {
  height: 6px;
}
.activity-no-action-loading {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin: 14px 0 0 15px;
}
.activity-no-action-loading i:first-child {
  border-radius: 8px;
  height: 38px;
  width: 105px;
}
.activity-no-action-loading i:last-child {
  width: 70%;
}
@keyframes activity-pulse {
  50% {
    opacity: 0.48;
  }
}
@media (max-width: 1120px) {
  .activity-kpis {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .activity-analysis-grid {
    grid-template-columns: minmax(0, 1fr);
  }
  .activity-task-distribution {
    flex-direction: row;
    gap: clamp(16px, 5vw, 44px);
  }
  .activity-donut-legend {
    margin: 0;
    max-width: 230px;
  }
  .activity-task-coverage {
    align-self: flex-end;
    border: 0;
    margin: 0 0 4px auto;
    padding: 0;
    text-align: right;
    width: auto;
  }
}
@media (max-width: 700px) {
  .activity-dashboard {
    gap: 10px;
  }
  .activity-kpis {
    gap: 7px;
  }
  .activity-kpi {
    border-radius: 12px;
    padding: 11px 10px;
  }
  .activity-kpi-value {
    font-size: clamp(32px, 8vw, 36px);
    margin-top: 11px;
  }
  .activity-kpi-top > span:last-child:not(.activity-kpi-icon) {
    font-size: 12px;
  }
  .activity-kpi-label {
    font-size: 12px;
  }
  .activity-kpi small {
    font-size: 12px;
  }
  .activity-panel,
  .activity-no-action-panel {
    border-radius: 13px;
    padding: 12px;
  }
  .activity-panel-header > .activity-coverage-pill {
    font-size: 12px;
    padding: 4px 5px;
  }
  .activity-subtitle {
    font-size: 12px;
  }
  .activity-stage-axis,
  .activity-stage-measure {
    gap: 5px;
    grid-template-columns: minmax(0, 60px) minmax(0, 1fr) 51px;
  }
  .activity-stage-axis > div {
    font-size: 12px;
  }
  .activity-stage-row {
    padding: 7px;
  }
  .activity-stage-row-head {
    flex-direction: column;
    gap: 5px;
  }
  .activity-stage-names {
    align-self: stretch;
    max-width: 100%;
    width: 100%;
  }
  .activity-stage-meta {
    align-items: flex-start;
    flex: 0 1 auto;
    flex-direction: row;
    flex-wrap: wrap;
    max-width: 100%;
    min-width: 0;
    width: 100%;
  }
  .activity-stage-meta > small,
  .activity-stage-meta > .activity-coverage-pill {
    max-width: 100%;
    min-width: 0;
  }
  .activity-stage-meta > .activity-coverage-pill {
    flex: 0 1 auto;
    overflow-wrap: anywhere;
    white-space: normal;
  }
  .activity-stage-names strong {
    font-size: 12px;
  }
  .activity-stage-meta > small {
    font-size: 12px;
  }
  .activity-stage-measure > span:first-child {
    font-size: 12px;
  }
  .activity-stage-measure > strong {
    font-size: 12px;
  }
  .activity-coverage-pill--small {
    font-size: 12px;
    padding: 3px 4px;
  }
  .activity-task-mix {
    min-height: 0;
  }
  .activity-task-distribution {
    flex-direction: column;
    gap: 12px;
  }
  .activity-donut-wrap {
    height: 132px;
    width: 132px;
  }
  .activity-donut-legend {
    max-width: 230px;
  }
  .activity-task-coverage {
    align-self: stretch;
    border-top: 1px solid var(--line);
    margin: 0;
    padding-top: 7px;
    text-align: center;
    width: 100%;
  }
  .activity-task-rows {
    grid-template-columns: minmax(0, 1fr);
  }
  .activity-no-action-panel {
    gap: 10px;
  }
  .activity-no-action-side {
    border-top: 1px solid #f1e4df;
    padding: 9px 0 0 12px;
  }
  .activity-panel-header {
    flex-wrap: wrap;
  }
  .activity-panel-header > div:first-child {
    flex: 1 1 100%;
    min-width: 0;
  }
  .activity-panel-header > .activity-coverage-pill {
    align-self: flex-start;
    margin-left: 15px;
    max-width: calc(100% - 15px);
    overflow-wrap: anywhere;
    white-space: normal;
  }
  .activity-stage-axis > div > span:nth-child(2),
  .activity-stage-axis > div > span:nth-child(4) {
    display: none;
  }
  .activity-no-action-number strong {
    font-size: 36px;
  }
  .activity-state--inline {
    align-items: flex-start;
    flex-wrap: wrap;
  }
  .activity-state--inline p {
    flex: 1 1 100%;
  }
}
@media (prefers-reduced-motion: reduce) {
  .activity-loading i,
  .activity-no-action-loading i {
    animation: none;
  }
  .activity-bar-fill {
    transition: none;
  }
}
</style>
