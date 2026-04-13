<script setup>
/* eslint-disable no-use-before-define */
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';

import CaptainObservabilityAPI from 'dashboard/api/captain/observability';
import CaptainPreferencesAPI from 'dashboard/api/captain/preferences';
import Button from 'dashboard/components-next/button/Button.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import BaseTable from 'dashboard/components-next/table/BaseTable.vue';
import LineChart from 'shared/components/charts/LineChart.vue';
import EventDetailsDialog from './EventDetailsDialog.vue';

const { t, locale } = useI18n();
const route = useRoute();
const router = useRouter();

const TABS = Object.freeze([
  { id: 'overview', labelKey: 'CAPTAIN.OBSERVABILITY.TABS.OVERVIEW' },
  { id: 'events', labelKey: 'CAPTAIN.OBSERVABILITY.TABS.EVENTS' },
  { id: 'traces', labelKey: 'CAPTAIN.OBSERVABILITY.TABS.TRACES' },
  { id: 'evaluations', labelKey: 'CAPTAIN.OBSERVABILITY.TABS.EVALUATIONS' },
]);

const STATUS_CLASSES = Object.freeze({
  pass: 'bg-n-teal-3 text-n-teal-11',
  pass_with_warnings: 'bg-n-amber-3 text-n-amber-11',
  fail: 'bg-n-ruby-3 text-n-ruby-11',
  alerting: 'bg-n-ruby-3 text-n-ruby-11',
  firing: 'bg-n-ruby-3 text-n-ruby-11',
  warning: 'bg-n-amber-3 text-n-amber-11',
  critical: 'bg-n-ruby-3 text-n-ruby-11',
  insufficient_data: 'bg-n-amber-3 text-n-amber-11',
  disabled: 'bg-n-alpha-2 text-n-slate-11',
  not_applicable: 'bg-n-alpha-2 text-n-slate-11',
  ok: 'bg-n-teal-3 text-n-teal-11',
  success: 'bg-n-teal-3 text-n-teal-11',
  completed: 'bg-n-teal-3 text-n-teal-11',
  allowed: 'bg-n-teal-3 text-n-teal-11',
  error: 'bg-n-ruby-3 text-n-ruby-11',
  failed: 'bg-n-ruby-3 text-n-ruby-11',
  blocked: 'bg-n-amber-3 text-n-amber-11',
  flagged: 'bg-n-amber-3 text-n-amber-11',
});
const ROUTE_QUERY_KEYS = Object.freeze({
  tab: 'tab',
  feature: 'feature',
  runtimeMode: 'runtime_mode',
  status: 'status',
  flag: 'flag',
  model: 'model',
  eventName: 'event_name',
  toolName: 'tool_name',
  schemaName: 'schema_name',
  traceId: 'trace_id',
  sessionId: 'session_id',
  conversationDisplayId: 'conversation_display_id',
  copilotThreadId: 'copilot_thread_id',
  assistantId: 'assistant_id',
  since: 'since',
  until: 'until',
  page: 'page',
  perPage: 'per_page',
});
const PRESET_DEFINITIONS = Object.freeze([
  {
    key: 'all',
    labelKey: 'CAPTAIN.OBSERVABILITY.PRESETS.ALL',
    filters: {},
    tab: 'overview',
  },
  {
    key: 'errors',
    labelKey: 'CAPTAIN.OBSERVABILITY.PRESETS.ERRORS',
    filters: { flag: 'error' },
    tab: 'events',
  },
  {
    key: 'blocked',
    labelKey: 'CAPTAIN.OBSERVABILITY.PRESETS.BLOCKED',
    filters: { flag: 'blocked' },
    tab: 'events',
  },
  {
    key: 'toolFailures',
    labelKey: 'CAPTAIN.OBSERVABILITY.PRESETS.TOOL_FAILURES',
    filters: { flag: 'tool_failure' },
    tab: 'events',
  },
  {
    key: 'schemaInvalid',
    labelKey: 'CAPTAIN.OBSERVABILITY.PRESETS.SCHEMA_INVALID',
    filters: { flag: 'schema_invalid' },
    tab: 'events',
  },
  {
    key: 'assistant',
    labelKey: 'CAPTAIN.OBSERVABILITY.PRESETS.ASSISTANT',
    filters: { feature: 'assistant' },
    tab: 'events',
  },
  {
    key: 'copilot',
    labelKey: 'CAPTAIN.OBSERVABILITY.PRESETS.COPILOT',
    filters: { feature: 'copilot' },
    tab: 'events',
  },
]);

const defaultObservabilityPreferences = () => ({
  default_lookback_days: 30,
  retention_days: 90,
  saved_views: [],
  alert_channels: {
    enabled: false,
    minimum_severity: 'warning',
    email_recipients: [],
    webhook_url: '',
    notify_on: ['operational_release_gate'],
  },
});

const activeTab = ref('overview');
const eventDetailsDialogRef = ref(null);
const overview = reactive({
  snapshot: {},
  timeSeries: {},
  releaseGate: {},
  alerts: {},
  alertDeliveryState: {},
  preferences: defaultObservabilityPreferences(),
  events: [],
  meta: {},
});
const releaseCheck = ref(null);
const savedViewName = ref('');
const observabilitySettings = reactive({
  defaultLookbackDays: 30,
  retentionDays: 90,
  alertChannelsEnabled: false,
  minimumSeverity: 'warning',
  emailRecipients: '',
  webhookUrl: '',
  notifyOn: 'operational_release_gate',
});

const uiState = reactive({
  loadingOverview: false,
  loadingReleaseCheck: false,
  savingPreferences: false,
  exporting: false,
});

const filters = reactive({
  feature: '',
  runtimeMode: '',
  status: '',
  flag: '',
  model: '',
  eventName: '',
  toolName: '',
  schemaName: '',
  traceId: '',
  sessionId: '',
  conversationDisplayId: '',
  copilotThreadId: '',
  assistantId: '',
  since: '',
  until: '',
  page: 1,
  perPage: 25,
});

const featureOptions = computed(() => [
  {
    value: '',
    label: t('CAPTAIN.OBSERVABILITY.FILTERS.ALL_FEATURES'),
  },
  {
    value: 'assistant',
    label: t('CAPTAIN_SETTINGS.RUNTIME.ASSISTANT.TITLE'),
  },
  {
    value: 'copilot',
    label: t('CAPTAIN_SETTINGS.RUNTIME.COPILOT.TITLE'),
  },
  {
    value: 'editor',
    label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.EDITOR.TITLE'),
  },
  {
    value: 'label_suggestion',
    label: t('CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.LABEL_SUGGESTION'),
  },
  {
    value: 'help_center_search',
    label: t(
      'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.HELP_CENTER_SEARCH'
    ),
  },
  {
    value: 'audio_transcription',
    label: t(
      'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.AUDIO_TRANSCRIPTION'
    ),
  },
]);

const runtimeModeOptions = computed(() => [
  {
    value: '',
    label: t('CAPTAIN.OBSERVABILITY.FILTERS.ALL_RUNTIME_MODES'),
  },
  {
    value: 'assistant',
    label: t('CAPTAIN_SETTINGS.RUNTIME.ASSISTANT.TITLE'),
  },
  {
    value: 'copilot',
    label: t('CAPTAIN_SETTINGS.RUNTIME.COPILOT.TITLE'),
  },
  {
    value: 'task',
    label: t('CAPTAIN.OBSERVABILITY.RUNTIME_MODES.TASK'),
  },
]);

const flagOptions = computed(() => [
  {
    value: '',
    label: t('CAPTAIN.OBSERVABILITY.FILTERS.ALL_FLAGS'),
  },
  {
    value: 'blocked',
    label: t('CAPTAIN.OBSERVABILITY.FLAGS.BLOCKED'),
  },
  {
    value: 'error',
    label: t('CAPTAIN.OBSERVABILITY.FLAGS.ERROR'),
  },
  {
    value: 'tool_failure',
    label: t('CAPTAIN.OBSERVABILITY.FLAGS.TOOL_FAILURE'),
  },
  {
    value: 'schema_invalid',
    label: t('CAPTAIN.OBSERVABILITY.FLAGS.SCHEMA_INVALID'),
  },
  {
    value: 'moderation_skipped',
    label: t('CAPTAIN.OBSERVABILITY.FLAGS.MODERATION_SKIPPED'),
  },
]);

const tabOptions = computed(() =>
  TABS.map(tab => ({ id: tab.id, label: tabLabel(tab.id) }))
);
const presets = computed(() =>
  PRESET_DEFINITIONS.map(preset => ({
    ...preset,
    label: presetLabel(preset.key),
  }))
);
const activeTabIndex = computed(() =>
  Math.max(
    0,
    TABS.findIndex(tab => tab.id === activeTab.value)
  )
);
const currentPage = computed(() => overview.meta.current_page || filters.page);
const totalCount = computed(() => overview.meta.count || 0);
const itemsPerPage = computed(() => filters.perPage);
const showPaginationFooter = computed(
  () =>
    ['events', 'traces'].includes(activeTab.value) &&
    totalCount.value > itemsPerPage.value
);
const isFetching = computed(
  () => uiState.loadingOverview || uiState.loadingReleaseCheck
);
const isEmpty = computed(() => {
  if (activeTab.value === 'events') {
    return !uiState.loadingOverview && overview.events.length === 0;
  }

  if (activeTab.value === 'traces') {
    return !uiState.loadingOverview && traceGroups.value.length === 0;
  }

  if (activeTab.value === 'evaluations') {
    return !uiState.loadingReleaseCheck && !releaseCheck.value;
  }

  return false;
});
const headerButtonLabel = computed(() =>
  activeTab.value === 'evaluations'
    ? t('CAPTAIN.OBSERVABILITY.ACTIONS.RUN_RELEASE_CHECK')
    : t('CAPTAIN.OBSERVABILITY.ACTIONS.REFRESH')
);

const topFeatureDistribution = computed(() =>
  buildDistribution(overview.snapshot.by_feature)
);
const topModelDistribution = computed(() =>
  buildDistribution(overview.snapshot.by_model)
);
const topProviderDistribution = computed(() =>
  buildDistribution(overview.snapshot.by_provider)
);
const moderationStageDistribution = computed(() =>
  buildDistribution(overview.snapshot.moderation_by_stage)
);
const moderationReasonDistribution = computed(() =>
  buildDistribution(overview.snapshot.moderation_by_reason)
);
const blockedReasonDistribution = computed(() =>
  buildDistribution(overview.snapshot.blocked_by_reason)
);
const flaggedCategoryDistribution = computed(() =>
  buildDistribution(overview.snapshot.flagged_categories)
);
const topFeatureCostDistribution = computed(() =>
  buildDistribution(overview.snapshot.cost_by_feature)
);
const topModelCostDistribution = computed(() =>
  buildDistribution(overview.snapshot.cost_by_model)
);
const topAssistantCostDistribution = computed(() =>
  buildDistribution(overview.snapshot.cost_by_assistant_id)
);
const activeAlerts = computed(() => Array(overview.alerts.alerts || []));
const releaseChecks = computed(() => Array(overview.releaseGate.checks || []));
const savedViews = computed(() =>
  Array(overview.preferences.saved_views || [])
);
const lastAlertDeliveryState = computed(
  () => overview.alertDeliveryState || {}
);
const hasAlertDeliveryState = computed(
  () =>
    Boolean(lastAlertDeliveryState.value.last_delivery_at) ||
    Boolean(lastAlertDeliveryState.value.last_resolved_at)
);
const overviewMetrics = computed(() => {
  const snapshot = overview.snapshot || {};

  return [
    {
      key: 'requests',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.REQUESTS'),
      value: formatInteger(snapshot.request_count),
      tone: 'text-n-brand',
    },
    {
      key: 'events',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.EVENTS'),
      value: formatInteger(snapshot.total_events),
      tone: 'text-n-slate-12',
    },
    {
      key: 'errors',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.ERRORS'),
      value: formatInteger(snapshot.error_count),
      tone: 'text-n-ruby-11',
    },
    {
      key: 'blocked',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.BLOCKED'),
      value: formatInteger(snapshot.blocked_count),
      tone: 'text-n-amber-11',
    },
    {
      key: 'latency',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.AVG_LATENCY'),
      value: formatDuration(snapshot.avg_duration_ms),
      tone: 'text-n-sky-11',
    },
    {
      key: 'tokens',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.ALL_TOKENS'),
      value: formatInteger(snapshot.all_total_tokens),
      tone: 'text-n-iris-11',
    },
    {
      key: 'cost',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.ALL_COST'),
      value: formatCurrency(snapshot.total_estimated_cost),
      tone: 'text-n-teal-11',
    },
    {
      key: 'moderation',
      label: t('CAPTAIN.OBSERVABILITY.METRICS.MODERATION'),
      value: formatInteger(snapshot.moderation_count),
      tone: 'text-n-slate-12',
    },
  ];
});
const timeSeriesPoints = computed(() =>
  Array(overview.timeSeries.points || [])
);
const trendCards = computed(() => [
  {
    key: 'latency',
    title: t('CAPTAIN.OBSERVABILITY.TRENDS.LATENCY_TITLE'),
    description: t('CAPTAIN.OBSERVABILITY.TRENDS.LATENCY_DESCRIPTION'),
    hasData: timeSeriesPoints.value.some(
      point =>
        point.avg_duration_ms !== null && point.avg_duration_ms !== undefined
    ),
    collection: buildTrendCollection({
      key: 'avg_duration_ms',
      label: t('CAPTAIN.OBSERVABILITY.TRENDS.LATENCY_TITLE'),
      color: '#0ea5e9',
    }),
    options: buildTrendChartOptions({
      metric: 'duration',
      bucket: overview.timeSeries.bucket,
    }),
  },
  {
    key: 'errors',
    title: t('CAPTAIN.OBSERVABILITY.TRENDS.ERROR_TITLE'),
    description: t('CAPTAIN.OBSERVABILITY.TRENDS.ERROR_DESCRIPTION'),
    hasData: timeSeriesPoints.value.some(
      point => Number(point.error_count) > 0
    ),
    collection: buildTrendCollection({
      key: 'error_count',
      label: t('CAPTAIN.OBSERVABILITY.TRENDS.ERROR_TITLE'),
      color: '#e5484d',
    }),
    options: buildTrendChartOptions({
      metric: 'integer',
      bucket: overview.timeSeries.bucket,
    }),
  },
  {
    key: 'cost',
    title: t('CAPTAIN.OBSERVABILITY.TRENDS.COST_TITLE'),
    description: t('CAPTAIN.OBSERVABILITY.TRENDS.COST_DESCRIPTION'),
    hasData: timeSeriesPoints.value.some(
      point => Number(point.estimated_cost) > 0
    ),
    collection: buildTrendCollection({
      key: 'estimated_cost',
      label: t('CAPTAIN.OBSERVABILITY.TRENDS.COST_TITLE'),
      color: '#10b981',
    }),
    options: buildTrendChartOptions({
      metric: 'currency',
      bucket: overview.timeSeries.bucket,
    }),
  },
]);
const activePresetKey = computed(() => {
  const matchedPreset = PRESET_DEFINITIONS.find(preset =>
    presetMatches(preset)
  );

  return matchedPreset?.key || null;
});
const eventHeaders = computed(() => [
  t('CAPTAIN.OBSERVABILITY.EVENTS.TABLE.TIME'),
  t('CAPTAIN.OBSERVABILITY.EVENTS.TABLE.EVENT'),
  t('CAPTAIN.OBSERVABILITY.EVENTS.TABLE.CONTEXT'),
  t('CAPTAIN.OBSERVABILITY.EVENTS.TABLE.MODEL'),
  t('CAPTAIN.OBSERVABILITY.EVENTS.TABLE.USAGE'),
  t('CAPTAIN.OBSERVABILITY.EVENTS.TABLE.FLAGS'),
]);
const releaseReportChecks = computed(() =>
  Array(releaseCheck.value?.checks || [])
);
const traceGroups = computed(() => {
  const groups = new Map();

  overview.events.forEach(event => {
    const descriptor = traceDescriptor(event);
    const existingGroup = groups.get(descriptor.key) || {
      id: descriptor.key,
      type: descriptor.type,
      label: descriptor.label,
      startedAt: event.created_at,
      latestAt: event.created_at,
      filterHint: descriptor.filterHint,
      eventCount: 0,
      errorCount: 0,
      blockedCount: 0,
      events: [],
    };

    existingGroup.eventCount += 1;
    existingGroup.errorCount += event.error ? 1 : 0;
    existingGroup.blockedCount += event.blocked ? 1 : 0;
    existingGroup.events.push(event);

    if (
      new Date(event.created_at).getTime() >
      new Date(existingGroup.latestAt).getTime()
    ) {
      existingGroup.latestAt = event.created_at;
    }

    if (
      new Date(event.created_at).getTime() <
      new Date(existingGroup.startedAt).getTime()
    ) {
      existingGroup.startedAt = event.created_at;
    }

    groups.set(descriptor.key, existingGroup);
  });

  return Array.from(groups.values())
    .map(group => {
      const events = group.events
        .slice()
        .sort(
          (left, right) =>
            new Date(left.created_at).getTime() -
            new Date(right.created_at).getTime()
        );
      const providerHops = uniqueValues(
        events.map(event => traceHopLabel(event))
      );

      return {
        ...group,
        durationMs: traceDuration(group.startedAt, group.latestAt),
        providerHops,
        providers: uniqueValues(events.map(event => event.provider)),
        models: uniqueValues(events.map(event => event.model)),
        traceId: events.find(event => event.trace_id)?.trace_id || null,
        rootSpanId:
          events.find(event => event.root_span_id)?.root_span_id || null,
        events: annotateTraceEvents(events),
      };
    })
    .sort(
      (left, right) =>
        new Date(right.latestAt).getTime() - new Date(left.latestAt).getTime()
    );
});
const deterministicSuites = computed(
  () => releaseCheck.value?.evals?.deterministic?.suites || []
);
const liveSuites = computed(
  () => releaseCheck.value?.evals?.live?.suites || []
);
const blockingFailures = computed(() =>
  Array(releaseCheck.value?.blocking_failures || [])
);
const focusedTraceGroup = computed(() => {
  const traceKey = traceKeyFromFilters();
  if (!traceKey) return traceGroups.value[0] || null;

  return (
    traceGroups.value.find(group => group.id === traceKey) ||
    traceGroups.value[0] ||
    null
  );
});
const metricsEndpoint = computed(() => {
  const query = new URLSearchParams(normalizedParams({ includePage: false }));
  return query.toString()
    ? `/api/v1/accounts/${route.params.accountId}/captain/observability/metrics?${query.toString()}`
    : `/api/v1/accounts/${route.params.accountId}/captain/observability/metrics`;
});

function normalizedParams({ includePage = true } = {}) {
  const params = {};
  [
    'feature',
    'runtimeMode',
    'status',
    'flag',
    'model',
    'eventName',
    'toolName',
    'schemaName',
    'traceId',
    'sessionId',
    'conversationDisplayId',
    'copilotThreadId',
    'assistantId',
    'since',
    'until',
  ].forEach(key => {
    const value =
      key === 'since' || key === 'until'
        ? normalizeDateParam(filters[key])
        : filters[key];
    if (value !== '' && value !== null && value !== undefined) {
      params[camelToSnake(key)] = value;
    }
  });

  if (includePage) {
    params.page = filters.page;
    params.per_page = filters.perPage;
  }

  return params;
}

function camelToSnake(value) {
  return value.replace(/[A-Z]/g, match => `_${match.toLowerCase()}`);
}

function normalizeDateParam(value) {
  if (!value) return '';
  if (/^\d+$/.test(String(value))) return String(value);

  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return '';
  }

  return String(Math.floor(parsed.getTime() / 1000));
}

function routeQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

function buildRouteQuery() {
  const query = {
    [ROUTE_QUERY_KEYS.tab]: activeTab.value,
    [ROUTE_QUERY_KEYS.page]: String(filters.page),
    [ROUTE_QUERY_KEYS.perPage]: String(filters.perPage),
  };

  Object.entries(ROUTE_QUERY_KEYS).forEach(([filterKey, queryKey]) => {
    if (['tab', 'page', 'perPage'].includes(filterKey)) {
      return;
    }

    const rawValue =
      filterKey === 'since' || filterKey === 'until'
        ? normalizeDateParam(filters[filterKey])
        : filters[filterKey];

    if (rawValue !== '' && rawValue !== null && rawValue !== undefined) {
      query[queryKey] = String(rawValue);
    }
  });

  return query;
}

function currentFilterState() {
  return {
    feature: filters.feature,
    runtimeMode: filters.runtimeMode,
    status: filters.status,
    flag: filters.flag,
    model: filters.model,
    eventName: filters.eventName,
    toolName: filters.toolName,
    schemaName: filters.schemaName,
    traceId: filters.traceId,
    sessionId: filters.sessionId,
    conversationDisplayId: filters.conversationDisplayId,
    copilotThreadId: filters.copilotThreadId,
    assistantId: filters.assistantId,
    since: normalizeDateParam(filters.since),
    until: normalizeDateParam(filters.until),
  };
}

function applyObservabilityPreferences(preferences = {}) {
  const payload = {
    ...defaultObservabilityPreferences(),
    ...(preferences || {}),
  };
  const alertChannels = {
    ...defaultObservabilityPreferences().alert_channels,
    ...(payload.alert_channels || {}),
  };

  overview.preferences = {
    ...payload,
    alert_channels: alertChannels,
  };
  observabilitySettings.defaultLookbackDays =
    payload.default_lookback_days || 30;
  observabilitySettings.retentionDays = payload.retention_days || 90;
  observabilitySettings.alertChannelsEnabled = alertChannels.enabled === true;
  observabilitySettings.minimumSeverity =
    alertChannels.minimum_severity || 'warning';
  observabilitySettings.emailRecipients = Array(
    alertChannels.email_recipients || []
  ).join(', ');
  observabilitySettings.webhookUrl = alertChannels.webhook_url || '';
  observabilitySettings.notifyOn =
    Array(alertChannels.notify_on || [])[0] || '';
}

function observabilityPreferencesPayload(partial = {}) {
  return {
    captain_observability: partial,
  };
}

async function persistObservabilityPreferences(partial, successMessage) {
  uiState.savingPreferences = true;

  try {
    const response = await CaptainPreferencesAPI.updatePreferences(
      observabilityPreferencesPayload(partial)
    );
    applyObservabilityPreferences(response.data.observability || {});
    if (successMessage) {
      useAlert(successMessage);
    }
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.API.PREFERENCES_ERROR'));
  } finally {
    uiState.savingPreferences = false;
  }
}

function normalizedSavedViewFilters() {
  return normalizedParams({ includePage: false });
}

function localFiltersFromSavedView(savedView) {
  const savedFilters = savedView?.filters || {};

  return {
    feature: savedFilters.feature || '',
    runtimeMode: savedFilters.runtime_mode || '',
    status: savedFilters.status || '',
    flag: savedFilters.flag || '',
    model: savedFilters.model || '',
    eventName: savedFilters.event_name || '',
    toolName: savedFilters.tool_name || '',
    schemaName: savedFilters.schema_name || '',
    traceId: savedFilters.trace_id || '',
    sessionId: savedFilters.session_id || '',
    conversationDisplayId: savedFilters.conversation_display_id || '',
    copilotThreadId: savedFilters.copilot_thread_id || '',
    assistantId: savedFilters.assistant_id || '',
    since: toDateTimeLocal(savedFilters.since),
    until: toDateTimeLocal(savedFilters.until),
  };
}

function buildSavedView(name, existingId = null) {
  return {
    id:
      existingId || window.crypto?.randomUUID?.() || `saved-view-${Date.now()}`,
    name: name.trim(),
    tab: activeTab.value,
    filters: normalizedSavedViewFilters(),
  };
}

function currentRouteQuery() {
  return Object.entries(route.query).reduce((result, [key, value]) => {
    const normalizedValue = routeQueryValue(value);
    if (
      normalizedValue !== undefined &&
      normalizedValue !== null &&
      normalizedValue !== ''
    ) {
      result[key] = String(normalizedValue);
    }

    return result;
  }, {});
}

function sameRouteQuery(left, right) {
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  if (leftKeys.length !== rightKeys.length) return false;

  return leftKeys.every(
    key => rightKeys.includes(key) && left[key] === right[key]
  );
}

function toInteger(value, fallback) {
  const parsed = Number.parseInt(routeQueryValue(value), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function toDateTimeLocal(value) {
  const normalized = routeQueryValue(value);
  if (!normalized) return '';

  const parsed = /^\d+$/.test(String(normalized))
    ? new Date(Number(normalized) * 1000)
    : new Date(normalized);
  if (Number.isNaN(parsed.getTime())) return '';

  const offset = parsed.getTimezoneOffset() * 60_000;
  return new Date(parsed.getTime() - offset).toISOString().slice(0, 16);
}

function applyRouteState(query = {}) {
  const tab = routeQueryValue(query[ROUTE_QUERY_KEYS.tab]);
  activeTab.value = TABS.some(item => item.id === tab) ? tab : 'overview';

  filters.feature = routeQueryValue(query[ROUTE_QUERY_KEYS.feature]) || '';
  filters.runtimeMode =
    routeQueryValue(query[ROUTE_QUERY_KEYS.runtimeMode]) || '';
  filters.status = routeQueryValue(query[ROUTE_QUERY_KEYS.status]) || '';
  filters.flag = routeQueryValue(query[ROUTE_QUERY_KEYS.flag]) || '';
  filters.model = routeQueryValue(query[ROUTE_QUERY_KEYS.model]) || '';
  filters.eventName = routeQueryValue(query[ROUTE_QUERY_KEYS.eventName]) || '';
  filters.toolName = routeQueryValue(query[ROUTE_QUERY_KEYS.toolName]) || '';
  filters.schemaName =
    routeQueryValue(query[ROUTE_QUERY_KEYS.schemaName]) || '';
  filters.traceId = routeQueryValue(query[ROUTE_QUERY_KEYS.traceId]) || '';
  filters.sessionId = routeQueryValue(query[ROUTE_QUERY_KEYS.sessionId]) || '';
  filters.conversationDisplayId =
    routeQueryValue(query[ROUTE_QUERY_KEYS.conversationDisplayId]) || '';
  filters.copilotThreadId =
    routeQueryValue(query[ROUTE_QUERY_KEYS.copilotThreadId]) || '';
  filters.assistantId =
    routeQueryValue(query[ROUTE_QUERY_KEYS.assistantId]) || '';
  filters.since = toDateTimeLocal(query[ROUTE_QUERY_KEYS.since]);
  filters.until = toDateTimeLocal(query[ROUTE_QUERY_KEYS.until]);
  filters.page = toInteger(query[ROUTE_QUERY_KEYS.page], 1);
  filters.perPage = [25, 50, 100].includes(
    toInteger(query[ROUTE_QUERY_KEYS.perPage], 25)
  )
    ? toInteger(query[ROUTE_QUERY_KEYS.perPage], 25)
    : 25;
}

function resetFilterState() {
  filters.feature = '';
  filters.runtimeMode = '';
  filters.status = '';
  filters.flag = '';
  filters.model = '';
  filters.eventName = '';
  filters.toolName = '';
  filters.schemaName = '';
  filters.traceId = '';
  filters.sessionId = '';
  filters.conversationDisplayId = '';
  filters.copilotThreadId = '';
  filters.assistantId = '';
  filters.since = '';
  filters.until = '';
}

async function updateRouteQuery() {
  const nextQuery = buildRouteQuery();

  if (sameRouteQuery(nextQuery, currentRouteQuery())) {
    await refreshCurrentTab();
    return;
  }

  await router.replace({
    name: route.name,
    params: route.params,
    query: nextQuery,
  });
}

async function loadOverview() {
  uiState.loadingOverview = true;

  try {
    const response = await CaptainObservabilityAPI.get(normalizedParams());
    overview.snapshot = response.data.snapshot || {};
    overview.timeSeries = response.data.time_series || {};
    overview.releaseGate = response.data.release_gate || {};
    overview.alerts = response.data.alerts || {};
    overview.alertDeliveryState = response.data.alert_delivery_state || {};
    applyObservabilityPreferences(response.data.preferences || {});
    overview.events = response.data.payload || [];
    overview.meta = response.data.meta || {};
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.OBSERVABILITY.API.OVERVIEW_ERROR'));
  } finally {
    uiState.loadingOverview = false;
  }
}

async function loadReleaseCheck() {
  uiState.loadingReleaseCheck = true;

  try {
    const response = await CaptainObservabilityAPI.releaseCheck({
      ...normalizedParams({ includePage: false }),
      include_live: true,
    });
    releaseCheck.value = response.data;
  } catch (error) {
    useAlert(
      error?.message || t('CAPTAIN.OBSERVABILITY.API.RELEASE_CHECK_ERROR')
    );
  } finally {
    uiState.loadingReleaseCheck = false;
  }
}

async function refreshCurrentTab() {
  if (activeTab.value === 'evaluations') {
    await loadReleaseCheck();
    return;
  }

  await loadOverview();
}

async function applyFilters() {
  filters.page = 1;
  await updateRouteQuery();
}

async function resetFilters() {
  resetFilterState();
  filters.page = 1;
  releaseCheck.value = null;
  await updateRouteQuery();
}

async function handlePageChange(page) {
  filters.page = page;
  await updateRouteQuery();
}

async function handleTabChange(tab) {
  activeTab.value = tab.id;
  filters.page = 1;
  await updateRouteQuery();
}

function statusLabel(status) {
  switch (status) {
    case 'pass':
      return t('CAPTAIN.OBSERVABILITY.STATUS.PASS');
    case 'pass_with_warnings':
      return t('CAPTAIN.OBSERVABILITY.STATUS.PASS_WITH_WARNINGS');
    case 'fail':
      return t('CAPTAIN.OBSERVABILITY.STATUS.FAIL');
    case 'insufficient_data':
      return t('CAPTAIN.OBSERVABILITY.STATUS.INSUFFICIENT_DATA');
    case 'disabled':
      return t('CAPTAIN.OBSERVABILITY.STATUS.DISABLED');
    case 'not_applicable':
      return t('CAPTAIN.OBSERVABILITY.STATUS.NOT_APPLICABLE');
    case 'alerting':
      return t('CAPTAIN.OBSERVABILITY.STATUS.ALERTING');
    case 'ok':
      return t('CAPTAIN.OBSERVABILITY.STATUS.OK');
    case 'success':
      return t('CAPTAIN.OBSERVABILITY.STATUS.SUCCESS');
    case 'completed':
      return t('CAPTAIN.OBSERVABILITY.STATUS.COMPLETED');
    case 'allowed':
      return t('CAPTAIN.OBSERVABILITY.STATUS.ALLOWED');
    case 'flagged':
      return t('CAPTAIN.OBSERVABILITY.STATUS.FLAGGED');
    case 'error':
      return t('CAPTAIN.OBSERVABILITY.STATUS.ERROR');
    case 'failed':
      return t('CAPTAIN.OBSERVABILITY.STATUS.FAILED');
    case 'blocked':
      return t('CAPTAIN.OBSERVABILITY.STATUS.BLOCKED');
    default:
      return status ? humanizeIdentifier(status) : t('GENERAL.NONE');
  }
}

function statusClass(status) {
  return STATUS_CLASSES[status] || 'bg-n-alpha-2 text-n-slate-11';
}

function tabLabel(tabId) {
  switch (tabId) {
    case 'overview':
      return t('CAPTAIN.OBSERVABILITY.TABS.OVERVIEW');
    case 'events':
      return t('CAPTAIN.OBSERVABILITY.TABS.EVENTS');
    case 'traces':
      return t('CAPTAIN.OBSERVABILITY.TABS.TRACES');
    case 'evaluations':
      return t('CAPTAIN.OBSERVABILITY.TABS.EVALUATIONS');
    default:
      return humanizeIdentifier(tabId);
  }
}

function presetLabel(presetKey) {
  switch (presetKey) {
    case 'all':
      return t('CAPTAIN.OBSERVABILITY.PRESETS.ALL');
    case 'errors':
      return t('CAPTAIN.OBSERVABILITY.PRESETS.ERRORS');
    case 'blocked':
      return t('CAPTAIN.OBSERVABILITY.PRESETS.BLOCKED');
    case 'toolFailures':
      return t('CAPTAIN.OBSERVABILITY.PRESETS.TOOL_FAILURES');
    case 'schemaInvalid':
      return t('CAPTAIN.OBSERVABILITY.PRESETS.SCHEMA_INVALID');
    case 'assistant':
      return t('CAPTAIN.OBSERVABILITY.PRESETS.ASSISTANT');
    case 'copilot':
      return t('CAPTAIN.OBSERVABILITY.PRESETS.COPILOT');
    default:
      return humanizeIdentifier(presetKey);
  }
}

function humanizeIdentifier(value) {
  if (!value) return t('GENERAL.NONE');

  return String(value)
    .replaceAll('_', ' ')
    .replace(/\b\w/g, char => char.toUpperCase());
}

function formatInteger(value) {
  return Number(value || 0).toLocaleString(locale.value || undefined);
}

function formatPercent(value) {
  if (value === null || value === undefined) {
    return t('GENERAL.NONE');
  }

  return `${(Number(value) * 100).toFixed(1)}%`;
}

function formatCurrency(value) {
  const amount = Number(value || 0);

  return new Intl.NumberFormat(locale.value || undefined, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  }).format(amount);
}

function formatDuration(value) {
  if (value === null || value === undefined) {
    return t('GENERAL.NONE');
  }

  return `${Math.round(Number(value))} ms`;
}

function formatDateTime(value) {
  if (!value) return t('GENERAL.NONE');

  try {
    return new Intl.DateTimeFormat(locale.value || undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
    }).format(new Date(value));
  } catch {
    return value;
  }
}

function buildDistribution(distribution) {
  return Object.entries(distribution || {})
    .sort(
      ([, leftValue], [, rightValue]) => Number(rightValue) - Number(leftValue)
    )
    .slice(0, 6);
}

function presetMatches(preset) {
  const currentState = currentFilterState();
  const presetFilters = preset.filters || {};
  const scopedKeys = [
    'feature',
    'runtimeMode',
    'status',
    'flag',
    'model',
    'eventName',
    'toolName',
    'schemaName',
    'traceId',
    'sessionId',
    'conversationDisplayId',
    'copilotThreadId',
    'assistantId',
    'since',
    'until',
  ];

  if (activeTab.value !== preset.tab) {
    return false;
  }

  return scopedKeys.every(key => {
    const currentValue = currentState[key] || '';
    const presetValue = presetFilters[key] || '';
    return currentValue === presetValue;
  });
}

async function applyPreset(preset) {
  resetFilterState();
  Object.entries(preset.filters || {}).forEach(([key, value]) => {
    filters[key] = value;
  });
  activeTab.value = preset.tab || 'events';
  filters.page = 1;
  await updateRouteQuery();
}

function formatTrendLabel(timestamp, bucket = 'day') {
  const date = new Date(Number(timestamp) * 1000);
  let options = { month: 'short', day: 'numeric' };

  if (bucket === 'hour') {
    options = { month: 'short', day: 'numeric', hour: 'numeric' };
  } else if (bucket === 'week') {
    options = { month: 'short', day: 'numeric' };
  }

  return new Intl.DateTimeFormat(locale.value || undefined, options).format(
    date
  );
}

function buildTrendCollection({ key, label, color }) {
  return {
    labels: timeSeriesPoints.value.map(point =>
      formatTrendLabel(point.timestamp, overview.timeSeries.bucket)
    ),
    datasets: [
      {
        label,
        data: timeSeriesPoints.value.map(point => point[key]),
        borderColor: color,
        backgroundColor: `${color}22`,
        pointBackgroundColor: color,
        pointBorderColor: color,
        fill: true,
      },
    ],
  };
}

function formatTrendValue(value, metric) {
  if (value === null || value === undefined) {
    return t('GENERAL.NONE');
  }

  switch (metric) {
    case 'duration':
      return formatDuration(value);
    case 'currency':
      return formatCurrency(value);
    default:
      return formatInteger(value);
  }
}

function buildTrendChartOptions({ metric, bucket }) {
  return {
    scales: {
      y: {
        beginAtZero: true,
      },
    },
    plugins: {
      tooltip: {
        callbacks: {
          label: context => formatTrendValue(context.raw, metric),
          title: items => {
            const point = timeSeriesPoints.value[items[0]?.dataIndex];
            return point ? formatTrendLabel(point.timestamp, bucket) : '';
          },
        },
      },
    },
  };
}

function operationalFilterForCheckName(checkName) {
  switch (String(checkName)) {
    case 'error_rate':
    case 'error_rate_regression':
      return { flag: 'error' };
    case 'moderation_skipped_rate':
      return { flag: 'moderation_skipped' };
    case 'schema_invalid_rate':
      return { flag: 'schema_invalid' };
    case 'tool_failure_rate':
      return { flag: 'tool_failure' };
    default:
      return null;
  }
}

async function focusOperationalCheck(checkName) {
  const mappedFilters = operationalFilterForCheckName(checkName);
  if (!mappedFilters) return;

  resetFilterState();
  Object.entries(mappedFilters).forEach(([key, value]) => {
    filters[key] = value;
  });
  filters.page = 1;
  activeTab.value = 'events';
  await updateRouteQuery();
}

async function copyCurrentViewLink() {
  const resolved = router.resolve({
    name: route.name,
    params: route.params,
    query: buildRouteQuery(),
  });
  const fullUrl = `${window.location.origin}${resolved.href}`;

  try {
    await navigator.clipboard.writeText(fullUrl);
    useAlert(t('CAPTAIN.OBSERVABILITY.ACTIONS.LINK_COPIED'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.ACTIONS.LINK_COPY_ERROR'));
  }
}

function parseEmailRecipients(value) {
  return value
    .split(',')
    .map(entry => entry.trim())
    .filter(Boolean);
}

async function saveCurrentView() {
  const name = savedViewName.value.trim();
  if (!name) {
    useAlert(t('CAPTAIN.OBSERVABILITY.SAVED_VIEWS.NAME_REQUIRED'));
    return;
  }

  const existing = savedViews.value.find(
    view => view.name.toLowerCase() === name.toLowerCase()
  );
  const nextViews = savedViews.value
    .filter(view => view.id !== existing?.id)
    .concat(buildSavedView(name, existing?.id));

  await persistObservabilityPreferences(
    { saved_views: nextViews },
    t('CAPTAIN.OBSERVABILITY.SAVED_VIEWS.SAVE_SUCCESS')
  );
  savedViewName.value = '';
}

async function applySavedView(savedView) {
  resetFilterState();
  Object.assign(filters, localFiltersFromSavedView(savedView));
  filters.page = 1;
  activeTab.value = savedView.tab || 'events';
  await updateRouteQuery();
}

async function deleteSavedView(savedViewId) {
  const nextViews = savedViews.value.filter(view => view.id !== savedViewId);

  await persistObservabilityPreferences(
    { saved_views: nextViews },
    t('CAPTAIN.OBSERVABILITY.SAVED_VIEWS.DELETE_SUCCESS')
  );
}

async function saveObservabilitySettings() {
  await persistObservabilityPreferences(
    {
      default_lookback_days: Number(observabilitySettings.defaultLookbackDays),
      retention_days: Number(observabilitySettings.retentionDays),
      alert_channels: {
        enabled: observabilitySettings.alertChannelsEnabled,
        minimum_severity: observabilitySettings.minimumSeverity,
        email_recipients: parseEmailRecipients(
          observabilitySettings.emailRecipients
        ),
        webhook_url: observabilitySettings.webhookUrl.trim() || null,
        notify_on: observabilitySettings.notifyOn
          ? [observabilitySettings.notifyOn]
          : [],
      },
    },
    t('CAPTAIN.OBSERVABILITY.SETTINGS.SAVE_SUCCESS')
  );
}

function fallbackExportFilename(format) {
  const timestamp = new Date().toISOString().replaceAll(':', '-');
  return `captain-observability-${route.params.accountId}-${activeTab.value}-${timestamp}.${format}`;
}

function exportFilenameFromHeaders(headers, format) {
  const headerValue =
    headers?.['content-disposition'] || headers?.['Content-Disposition'];
  const match = headerValue?.match(/filename="?([^"]+)"?/i);
  return match?.[1] || fallbackExportFilename(format);
}

function triggerBlobDownload(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

async function exportMatchingEvents(format = 'json') {
  uiState.exporting = true;

  try {
    const response = await CaptainObservabilityAPI.export(
      normalizedParams({ includePage: false }),
      format
    );
    triggerBlobDownload(
      response.data,
      exportFilenameFromHeaders(response.headers, format)
    );
    useAlert(t('CAPTAIN.OBSERVABILITY.ACTIONS.EXPORT_DONE'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.ACTIONS.EXPORT_ERROR'));
  } finally {
    uiState.exporting = false;
  }
}

function eventContext(event) {
  return [
    event.feature,
    event.runtime_mode,
    event.current_agent,
    event.conversation_display_id
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.CONTEXT.CONVERSATION')} #${event.conversation_display_id}`
      : null,
    event.tool_name
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.CONTEXT.TOOL')}: ${event.tool_name}`
      : null,
    event.schema_name
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.CONTEXT.SCHEMA')}: ${event.schema_name}`
      : null,
    event.trace_id
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.CONTEXT.TRACE')}: ${shortIdentifier(
          event.trace_id,
          12
        )}`
      : null,
    event.moderation_stage
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.CONTEXT.STAGE')}: ${humanizeIdentifier(
          event.moderation_stage
        )}`
      : null,
  ].filter(Boolean);
}

function eventUsage(event) {
  return [
    event.total_tokens
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.USAGE.TOKENS')}: ${formatInteger(
          event.total_tokens
        )}`
      : null,
    event.duration_ms
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.USAGE.LATENCY')}: ${formatDuration(
          event.duration_ms
        )}`
      : null,
    event.estimated_cost
      ? `${t('CAPTAIN.OBSERVABILITY.EVENTS.USAGE.COST')}: ${formatCurrency(
          event.estimated_cost
        )}`
      : null,
  ].filter(Boolean);
}

function eventFlags(event) {
  return [
    event.blocked ? t('CAPTAIN.OBSERVABILITY.FLAGS.BLOCKED') : null,
    event.tool_failure ? t('CAPTAIN.OBSERVABILITY.FLAGS.TOOL_FAILURE') : null,
    event.schema_invalid
      ? t('CAPTAIN.OBSERVABILITY.FLAGS.SCHEMA_INVALID')
      : null,
    event.moderation_skipped
      ? t('CAPTAIN.OBSERVABILITY.FLAGS.MODERATION_SKIPPED')
      : null,
    event.error ? t('CAPTAIN.OBSERVABILITY.FLAGS.ERROR') : null,
  ].filter(Boolean);
}

function eventReason(event) {
  if (!event.reason) return null;

  return humanizeIdentifier(event.reason);
}

function uniqueValues(values) {
  return [...new Set(values.filter(Boolean))];
}

function traceHopLabel(event) {
  const provider = event.provider || t('GENERAL.NONE');
  const model = event.model || t('GENERAL.NONE');

  return `${provider} / ${model}`;
}

function traceDuration(startedAt, endedAt) {
  if (!startedAt || !endedAt) return null;

  const duration = new Date(endedAt).getTime() - new Date(startedAt).getTime();
  return duration >= 0 ? duration : null;
}

function traceKeyFromFilters() {
  if (filters.traceId) return `trace:${filters.traceId}`;
  if (filters.sessionId) return `session:${filters.sessionId}`;
  if (filters.conversationDisplayId) {
    return `conversation:${filters.conversationDisplayId}`;
  }
  if (filters.copilotThreadId) return `copilot:${filters.copilotThreadId}`;
  if (filters.assistantId) return `assistant:${filters.assistantId}`;

  return null;
}

function suiteFailureCases(suite) {
  return Array(suite?.cases || []).filter(
    testCase => testCase.status === 'fail' || testCase.status === 'error'
  );
}

function suiteFocusFilters(suite) {
  switch (suite?.suite_id) {
    case 'captain.conversation_completion':
      return { feature: 'assistant' };
    case 'captain.tool_safety':
      return { flag: 'tool_failure' };
    case 'llm.moderation':
      return { flag: 'blocked' };
    default:
      return null;
  }
}

async function focusSuiteEvents(suite) {
  const mappedFilters = suiteFocusFilters(suite);
  if (!mappedFilters) return;

  resetFilterState();
  Object.entries(mappedFilters).forEach(([key, value]) => {
    filters[key] = value;
  });
  activeTab.value = 'events';
  filters.page = 1;
  await updateRouteQuery();
}

function openEventDetails(event) {
  eventDetailsDialogRef.value?.open(event);
}

function traceDescriptor(event) {
  if (event.trace_id) {
    return {
      key: `trace:${event.trace_id}`,
      type: 'trace',
      label: shortIdentifier(event.trace_id, 16),
      filterHint: {
        traceId: event.trace_id,
        sessionId: event.session_id,
        conversationDisplayId: event.conversation_display_id,
        copilotThreadId: event.copilot_thread_id,
        assistantId: event.assistant_id,
      },
    };
  }

  if (event.session_id) {
    return {
      key: `session:${event.session_id}`,
      type: 'session',
      label: event.session_id,
      filterHint: {
        sessionId: event.session_id,
      },
    };
  }

  if (event.conversation_display_id) {
    return {
      key: `conversation:${event.conversation_display_id}`,
      type: 'conversation',
      label: `#${event.conversation_display_id}`,
      filterHint: {
        conversationDisplayId: event.conversation_display_id,
      },
    };
  }

  if (event.copilot_thread_id) {
    return {
      key: `copilot:${event.copilot_thread_id}`,
      type: 'copilot',
      label: String(event.copilot_thread_id),
      filterHint: {
        copilotThreadId: event.copilot_thread_id,
      },
    };
  }

  if (event.assistant_id) {
    return {
      key: `assistant:${event.assistant_id}`,
      type: 'assistant',
      label: String(event.assistant_id),
      filterHint: {
        assistantId: event.assistant_id,
      },
    };
  }

  return {
    key: `event:${event.id}`,
    type: 'event',
    label: String(event.id),
    filterHint: {},
  };
}

function traceTypeLabel(type) {
  switch (type) {
    case 'trace':
      return t('CAPTAIN.OBSERVABILITY.TRACES.GROUP_TYPES.TRACE');
    case 'session':
      return t('CAPTAIN.OBSERVABILITY.TRACES.GROUP_TYPES.SESSION');
    case 'conversation':
      return t('CAPTAIN.OBSERVABILITY.TRACES.GROUP_TYPES.CONVERSATION');
    case 'copilot':
      return t('CAPTAIN.OBSERVABILITY.TRACES.GROUP_TYPES.COPILOT');
    case 'assistant':
      return t('CAPTAIN.OBSERVABILITY.TRACES.GROUP_TYPES.ASSISTANT');
    default:
      return t('CAPTAIN.OBSERVABILITY.TRACES.GROUP_TYPES.EVENT');
  }
}

async function applyTraceFocus(traceGroup) {
  filters.traceId = traceGroup.filterHint.traceId || '';
  filters.sessionId = traceGroup.filterHint.sessionId || '';
  filters.conversationDisplayId =
    traceGroup.filterHint.conversationDisplayId || '';
  filters.copilotThreadId = traceGroup.filterHint.copilotThreadId || '';
  filters.assistantId = traceGroup.filterHint.assistantId || '';
  filters.page = 1;
  activeTab.value = 'events';
  await updateRouteQuery();
}

async function focusTraceFromEvent(event) {
  filters.traceId = event.trace_id || '';
  filters.sessionId = event.session_id || '';
  filters.page = 1;
  activeTab.value = 'events';
  await updateRouteQuery();
}

function annotateTraceEvents(events) {
  const spanMap = new Map(
    events.filter(event => event.span_id).map(event => [event.span_id, event])
  );

  return events.map(event => ({
    ...event,
    traceDepth: traceDepth(event, spanMap),
  }));
}

function traceDepth(event, spanMap) {
  if (!event.parent_span_id) return fallbackTraceDepth(event);

  let depth = 0;
  let currentParent = event.parent_span_id;
  const visited = new Set();

  while (
    currentParent &&
    spanMap.has(currentParent) &&
    !visited.has(currentParent)
  ) {
    visited.add(currentParent);
    depth += 1;
    currentParent = spanMap.get(currentParent)?.parent_span_id;
  }

  return depth || fallbackTraceDepth(event);
}

function fallbackTraceDepth(event) {
  switch (event.span_kind) {
    case 'trace':
      return 0;
    case 'agent':
      return 1;
    case 'llm':
    case 'tool':
      return 2;
    default:
      return 0;
  }
}

function shortIdentifier(value, size = 10) {
  if (!value) return t('GENERAL.NONE');

  const normalized = String(value);
  return normalized.length > size
    ? `${normalized.slice(0, size)}...`
    : normalized;
}

function closeEventDetails() {
  eventDetailsDialogRef.value?.close();
}

async function openAssistantFromEvent(event) {
  closeEventDetails();
  await router.push({
    name: 'captain_assistants_settings_index',
    params: {
      accountId: route.params.accountId,
      assistantId: String(event.assistant_id),
    },
  });
}

async function openConversationFromEvent(event) {
  closeEventDetails();
  await router.push({
    name: 'inbox_conversation',
    params: {
      accountId: route.params.accountId,
      conversation_id: String(event.conversation_id),
    },
  });
}

async function openCopilotFromEvent(event) {
  closeEventDetails();
  const targetName = event.conversation_id ? 'inbox_conversation' : 'home';

  await router.push({
    name: targetName,
    params: {
      accountId: route.params.accountId,
      ...(event.conversation_id
        ? { conversation_id: String(event.conversation_id) }
        : {}),
    },
    query: {
      open_copilot: 'true',
      copilot_thread_id: String(event.copilot_thread_id),
      ...(event.assistant_id
        ? { assistant_id: String(event.assistant_id) }
        : {}),
    },
  });
}

watch(
  () => route.query,
  async query => {
    applyRouteState(query);
    await refreshCurrentTab();
  },
  { immediate: true, deep: true }
);

onMounted(async () => {
  if (Object.keys(route.query || {}).length === 0) {
    await updateRouteQuery();
  }
});
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.OBSERVABILITY.TITLE')"
    :show-assistant-switcher="false"
    :show-pagination-footer="showPaginationFooter"
    :current-page="currentPage"
    :items-per-page="itemsPerPage"
    :total-count="totalCount"
    :is-fetching="isFetching"
    :is-empty="isEmpty"
    :show-know-more="false"
    :button-label="headerButtonLabel"
    button-icon=""
    @click="refreshCurrentTab"
    @update:current-page="handlePageChange"
  >
    <template #subHeader>
      <div class="pb-4">
        <TabBar
          :tabs="tabOptions"
          :initial-active-tab="activeTabIndex"
          @tab-changed="handleTabChange"
        />
      </div>
    </template>

    <template #emptyState>
      <div
        class="rounded-2xl border border-dashed border-n-weak bg-n-alpha-2 px-6 py-12 text-center"
      >
        <div class="text-base font-medium text-n-slate-12">
          {{ t('CAPTAIN.OBSERVABILITY.EMPTY.TITLE') }}
        </div>
        <p class="mt-2 text-sm text-n-slate-11">
          {{ t('CAPTAIN.OBSERVABILITY.EMPTY.DESCRIPTION') }}
        </p>
      </div>
    </template>

    <template #controls>
      <div
        class="mb-6 rounded-2xl border border-n-weak bg-n-solid-1 p-4 md:p-5"
      >
        <div class="mb-4 flex flex-wrap gap-2">
          <Button
            v-for="preset in presets"
            :key="preset.key"
            :label="preset.label"
            :variant="activePresetKey === preset.key ? 'solid' : 'outline'"
            :color="activePresetKey === preset.key ? 'blue' : 'slate'"
            size="sm"
            @click="applyPreset(preset)"
          />
        </div>

        <div class="mb-4 rounded-xl bg-n-alpha-2 p-4">
          <div class="flex flex-wrap items-end gap-3">
            <Input
              v-model="savedViewName"
              :placeholder="
                t('CAPTAIN.OBSERVABILITY.SAVED_VIEWS.NAME_PLACEHOLDER')
              "
              class="min-w-[14rem] flex-1"
              size="sm"
            />
            <Button
              :label="t('CAPTAIN.OBSERVABILITY.SAVED_VIEWS.SAVE_ACTION')"
              size="sm"
              :is-loading="uiState.savingPreferences"
              @click="saveCurrentView"
            />
          </div>
          <div v-if="savedViews.length" class="mt-3 flex flex-wrap gap-2">
            <div
              v-for="savedView in savedViews"
              :key="savedView.id"
              class="flex items-center gap-2 rounded-full border border-n-weak bg-n-solid-1 px-2.5 py-1"
            >
              <button
                class="text-xs font-medium text-n-slate-12"
                @click="applySavedView(savedView)"
              >
                {{ savedView.name }}
              </button>
              <button
                class="text-[0.6875rem] text-n-ruby-11"
                @click="deleteSavedView(savedView.id)"
              >
                {{ t('CAPTAIN.OBSERVABILITY.SAVED_VIEWS.DELETE_ACTION') }}
              </button>
            </div>
          </div>
          <div v-else class="mt-3 text-xs text-n-slate-11">
            {{ t('CAPTAIN.OBSERVABILITY.SAVED_VIEWS.EMPTY') }}
          </div>
        </div>

        <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          <Select
            v-model="filters.feature"
            :options="featureOptions"
            class="w-full"
          />
          <Select
            v-model="filters.runtimeMode"
            :options="runtimeModeOptions"
            class="w-full"
          />
          <Input
            v-model="filters.status"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.STATUS')"
            size="sm"
          />
          <Select
            v-model="filters.flag"
            :options="flagOptions"
            class="w-full"
          />
          <Input
            v-model="filters.model"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.MODEL')"
            size="sm"
          />
          <Input
            v-model="filters.eventName"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.EVENT_NAME')"
            size="sm"
          />
          <Input
            v-model="filters.toolName"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.TOOL_NAME')"
            size="sm"
          />
          <Input
            v-model="filters.schemaName"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.SCHEMA_NAME')"
            size="sm"
          />
          <Input
            v-model="filters.traceId"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.TRACE_ID')"
            size="sm"
          />
          <Input
            v-model="filters.sessionId"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.SESSION_ID')"
            size="sm"
          />
          <Input
            v-model="filters.conversationDisplayId"
            :placeholder="
              t('CAPTAIN.OBSERVABILITY.FILTERS.CONVERSATION_DISPLAY_ID')
            "
            size="sm"
          />
          <Input
            v-model="filters.assistantId"
            :placeholder="t('CAPTAIN.OBSERVABILITY.FILTERS.ASSISTANT_ID')"
            size="sm"
          />
          <Input
            v-model="filters.since"
            type="datetime-local"
            :label="t('CAPTAIN.OBSERVABILITY.FILTERS.SINCE')"
            size="sm"
          />
          <Input
            v-model="filters.until"
            type="datetime-local"
            :label="t('CAPTAIN.OBSERVABILITY.FILTERS.UNTIL')"
            size="sm"
          />
          <Select
            v-model="filters.perPage"
            :options="[
              { value: 25, label: '25' },
              { value: 50, label: '50' },
              { value: 100, label: '100' },
            ]"
            :label="t('CAPTAIN.OBSERVABILITY.FILTERS.PER_PAGE')"
            class="w-full"
          />
        </div>

        <div class="mt-4 flex flex-wrap items-center gap-2">
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.APPLY_FILTERS')"
            size="sm"
            @click="applyFilters"
          />
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.RESET_FILTERS')"
            variant="outline"
            color="slate"
            size="sm"
            @click="resetFilters"
          />
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.COPY_LINK')"
            variant="outline"
            color="slate"
            size="sm"
            @click="copyCurrentViewLink"
          />
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.EXPORT_JSON')"
            variant="outline"
            color="slate"
            size="sm"
            :is-loading="uiState.exporting"
            @click="exportMatchingEvents('json')"
          />
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.EXPORT_CSV')"
            variant="outline"
            color="slate"
            size="sm"
            :is-loading="uiState.exporting"
            @click="exportMatchingEvents('csv')"
          />
          <a
            :href="metricsEndpoint"
            class="text-sm font-medium text-n-brand hover:underline"
            target="_blank"
            rel="noopener noreferrer"
          >
            {{ t('CAPTAIN.OBSERVABILITY.ACTIONS.OPEN_METRICS') }}
          </a>
        </div>
      </div>
    </template>

    <template #body>
      <div v-if="activeTab === 'overview'" class="grid gap-6">
        <section class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <article
            v-for="metric in overviewMetrics"
            :key="metric.key"
            class="rounded-2xl border border-n-weak bg-n-solid-1 p-4"
          >
            <div
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              {{ metric.label }}
            </div>
            <div class="mt-3 text-2xl font-semibold" :class="metric.tone">
              {{ metric.value }}
            </div>
          </article>
        </section>

        <section class="grid gap-4 xl:grid-cols-3">
          <article
            v-for="trend in trendCards"
            :key="trend.key"
            class="rounded-2xl border border-n-weak bg-n-solid-1 p-5"
          >
            <div>
              <h2 class="text-base font-medium text-n-slate-12">
                {{ trend.title }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{ trend.description }}
              </p>
            </div>
            <div class="mt-4 h-56">
              <LineChart
                v-if="trend.hasData"
                :collection="trend.collection"
                :chart-options="trend.options"
              />
              <div
                v-else
                class="flex h-full items-center justify-center rounded-xl bg-n-alpha-2 px-4 text-sm text-n-slate-11"
              >
                {{ t('CAPTAIN.OBSERVABILITY.TRENDS.NO_DATA') }}
              </div>
            </div>
          </article>
        </section>

        <section class="grid gap-6 lg:grid-cols-2">
          <article class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
            <h2 class="text-base font-medium text-n-slate-12">
              {{ t('CAPTAIN.OBSERVABILITY.SETTINGS.TITLE') }}
            </h2>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ t('CAPTAIN.OBSERVABILITY.SETTINGS.DESCRIPTION') }}
            </p>

            <div class="mt-4 grid gap-3 md:grid-cols-2">
              <Input
                v-model="observabilitySettings.defaultLookbackDays"
                type="number"
                min="1"
                max="365"
                :label="
                  t('CAPTAIN.OBSERVABILITY.SETTINGS.DEFAULT_LOOKBACK_LABEL')
                "
                size="sm"
              />
              <Input
                v-model="observabilitySettings.retentionDays"
                type="number"
                min="7"
                max="3650"
                :label="t('CAPTAIN.OBSERVABILITY.SETTINGS.RETENTION_LABEL')"
                size="sm"
              />
              <Select
                v-model="observabilitySettings.alertChannelsEnabled"
                :label="
                  t('CAPTAIN.OBSERVABILITY.SETTINGS.ALERT_CHANNELS_LABEL')
                "
                :options="[
                  {
                    value: false,
                    label: t('CAPTAIN.OBSERVABILITY.SETTINGS.DISABLED_OPTION'),
                  },
                  {
                    value: true,
                    label: t('CAPTAIN.OBSERVABILITY.SETTINGS.ENABLED_OPTION'),
                  },
                ]"
                class="w-full"
              />
              <Select
                v-model="observabilitySettings.minimumSeverity"
                :label="t('CAPTAIN.OBSERVABILITY.SETTINGS.MIN_SEVERITY_LABEL')"
                :options="[
                  {
                    value: 'warning',
                    label: t('CAPTAIN.OBSERVABILITY.STATUS.WARNING'),
                  },
                  {
                    value: 'critical',
                    label: t('CAPTAIN.OBSERVABILITY.STATUS.CRITICAL'),
                  },
                ]"
                class="w-full"
              />
              <Input
                v-model="observabilitySettings.emailRecipients"
                :label="
                  t('CAPTAIN.OBSERVABILITY.SETTINGS.EMAIL_RECIPIENTS_LABEL')
                "
                :placeholder="
                  t(
                    'CAPTAIN.OBSERVABILITY.SETTINGS.EMAIL_RECIPIENTS_PLACEHOLDER'
                  )
                "
                size="sm"
              />
              <Input
                v-model="observabilitySettings.webhookUrl"
                :label="t('CAPTAIN.OBSERVABILITY.SETTINGS.WEBHOOK_URL_LABEL')"
                :placeholder="
                  t('CAPTAIN.OBSERVABILITY.SETTINGS.WEBHOOK_URL_PLACEHOLDER')
                "
                size="sm"
              />
              <Select
                v-model="observabilitySettings.notifyOn"
                :label="t('CAPTAIN.OBSERVABILITY.SETTINGS.NOTIFY_ON_LABEL')"
                :options="[
                  {
                    value: 'operational_release_gate',
                    label: t(
                      'CAPTAIN.OBSERVABILITY.SETTINGS.NOTIFY_ON.OPERATIONAL'
                    ),
                  },
                  {
                    value: 'deterministic_evals',
                    label: t(
                      'CAPTAIN.OBSERVABILITY.SETTINGS.NOTIFY_ON.DETERMINISTIC'
                    ),
                  },
                  {
                    value: 'live_evals',
                    label: t('CAPTAIN.OBSERVABILITY.SETTINGS.NOTIFY_ON.LIVE'),
                  },
                ]"
                class="w-full"
              />
            </div>

            <div class="mt-4 flex justify-end">
              <Button
                :label="t('CAPTAIN.OBSERVABILITY.SETTINGS.SAVE_ACTION')"
                size="sm"
                :is-loading="uiState.savingPreferences"
                @click="saveObservabilitySettings"
              />
            </div>
          </article>

          <article class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
            <h2 class="text-base font-medium text-n-slate-12">
              {{ t('CAPTAIN.OBSERVABILITY.COST_BREAKDOWN.TITLE') }}
            </h2>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ t('CAPTAIN.OBSERVABILITY.COST_BREAKDOWN.DESCRIPTION') }}
            </p>

            <div class="mt-4 grid gap-4">
              <div>
                <div
                  class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                >
                  {{ t('CAPTAIN.OBSERVABILITY.COST_BREAKDOWN.FEATURES') }}
                </div>
                <div class="mt-2 flex flex-wrap gap-2">
                  <span
                    v-for="[name, amount] in topFeatureCostDistribution"
                    :key="`feature-cost-${name}`"
                    class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                  >
                    {{
                      `${name || t('GENERAL.NONE')} (${formatCurrency(amount)})`
                    }}
                  </span>
                </div>
              </div>

              <div>
                <div
                  class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                >
                  {{ t('CAPTAIN.OBSERVABILITY.COST_BREAKDOWN.MODELS') }}
                </div>
                <div class="mt-2 flex flex-wrap gap-2">
                  <span
                    v-for="[name, amount] in topModelCostDistribution"
                    :key="`model-cost-${name}`"
                    class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                  >
                    {{
                      `${name || t('GENERAL.NONE')} (${formatCurrency(amount)})`
                    }}
                  </span>
                </div>
              </div>

              <div>
                <div
                  class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                >
                  {{ t('CAPTAIN.OBSERVABILITY.COST_BREAKDOWN.ASSISTANTS') }}
                </div>
                <div class="mt-2 flex flex-wrap gap-2">
                  <span
                    v-for="[
                      assistantId,
                      amount,
                    ] in topAssistantCostDistribution"
                    :key="`assistant-cost-${assistantId}`"
                    class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                  >
                    {{
                      `${t(
                        'CAPTAIN.OBSERVABILITY.COST_BREAKDOWN.ASSISTANT_LABEL'
                      )} ${assistantId} (${formatCurrency(amount)})`
                    }}
                  </span>
                </div>
              </div>
            </div>
          </article>
        </section>

        <section
          class="grid gap-6 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)]"
        >
          <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="text-base font-medium text-n-slate-12">
                  {{ t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.TITLE') }}
                </h2>
                <p class="mt-1 text-sm text-n-slate-11">
                  {{ t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.DESCRIPTION') }}
                </p>
              </div>
              <span
                class="rounded-full px-2.5 py-1 text-xs font-medium"
                :class="statusClass(overview.releaseGate.status)"
              >
                {{ statusLabel(overview.releaseGate.status) }}
              </span>
            </div>

            <div class="mt-5 grid gap-3 md:grid-cols-2">
              <div class="rounded-xl bg-n-alpha-2 p-4">
                <div
                  class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                >
                  {{ t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.CURRENT_PERIOD') }}
                </div>
                <div class="mt-2 text-sm text-n-slate-11">
                  {{
                    t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.PERIOD_VALUE', {
                      since: formatDateTime(
                        overview.releaseGate.current_period?.started_at
                      ),
                      until: formatDateTime(
                        overview.releaseGate.current_period?.ended_at
                      ),
                    })
                  }}
                </div>
              </div>
              <div class="rounded-xl bg-n-alpha-2 p-4">
                <div
                  class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                >
                  {{ t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.BASELINE_PERIOD') }}
                </div>
                <div class="mt-2 text-sm text-n-slate-11">
                  {{
                    t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.PERIOD_VALUE', {
                      since: formatDateTime(
                        overview.releaseGate.baseline_period?.started_at
                      ),
                      until: formatDateTime(
                        overview.releaseGate.baseline_period?.ended_at
                      ),
                    })
                  }}
                </div>
              </div>
            </div>

            <div class="mt-5 grid gap-3">
              <div
                v-for="check in releaseChecks"
                :key="check.name"
                class="rounded-xl border border-n-weak bg-n-alpha-2 p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="text-sm font-medium text-n-slate-12">
                      {{ humanizeIdentifier(check.name) }}
                    </div>
                    <p
                      v-if="check.message"
                      class="mt-1 text-sm text-n-slate-11"
                    >
                      {{ check.message }}
                    </p>
                  </div>
                  <span
                    class="rounded-full px-2.5 py-1 text-xs font-medium"
                    :class="statusClass(check.status)"
                  >
                    {{ statusLabel(check.status) }}
                  </span>
                </div>
                <div
                  v-if="
                    check.actual !== undefined || check.expected !== undefined
                  "
                  class="mt-3 flex flex-wrap gap-2 text-xs text-n-slate-11"
                >
                  <span v-if="check.actual !== undefined">
                    {{
                      t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.ACTUAL', {
                        value:
                          String(check.name).includes('rate') ||
                          String(check.name).includes('regression')
                            ? formatPercent(check.actual)
                            : check.name === 'cost_per_request'
                              ? formatCurrency(check.actual)
                              : formatInteger(check.actual),
                      })
                    }}
                  </span>
                  <span v-if="check.expected !== undefined">
                    {{
                      t('CAPTAIN.OBSERVABILITY.RELEASE_GATE.EXPECTED', {
                        value:
                          String(check.name).includes('rate') ||
                          String(check.name).includes('regression')
                            ? formatPercent(check.expected)
                            : check.name === 'cost_per_request'
                              ? formatCurrency(check.expected)
                              : formatInteger(check.expected),
                      })
                    }}
                  </span>
                </div>
                <div
                  v-if="operationalFilterForCheckName(check.name)"
                  class="mt-3"
                >
                  <Button
                    :label="
                      t('CAPTAIN.OBSERVABILITY.ACTIONS.VIEW_MATCHING_EVENTS')
                    "
                    variant="outline"
                    color="slate"
                    size="sm"
                    @click="focusOperationalCheck(check.name)"
                  />
                </div>
              </div>
            </div>
          </div>

          <div class="grid gap-6">
            <section class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="text-base font-medium text-n-slate-12">
                    {{ t('CAPTAIN.OBSERVABILITY.ALERTS.TITLE') }}
                  </h2>
                  <p class="mt-1 text-sm text-n-slate-11">
                    {{ t('CAPTAIN.OBSERVABILITY.ALERTS.DESCRIPTION') }}
                  </p>
                </div>
                <span
                  class="rounded-full px-2.5 py-1 text-xs font-medium"
                  :class="statusClass(overview.alerts.status)"
                >
                  {{ statusLabel(overview.alerts.status) }}
                </span>
              </div>

              <div
                v-if="hasAlertDeliveryState"
                class="mt-4 rounded-xl border border-n-weak bg-n-alpha-2 p-4"
              >
                <div class="grid gap-2 text-sm text-n-slate-11">
                  <div class="flex items-start justify-between gap-3">
                    <span>{{
                      t('CAPTAIN.OBSERVABILITY.ALERTS.LAST_DELIVERY')
                    }}</span>
                    <span class="font-medium text-n-slate-12">
                      {{
                        lastAlertDeliveryState.last_delivery_at
                          ? formatDateTime(
                              lastAlertDeliveryState.last_delivery_at
                            )
                          : t('GENERAL.NONE')
                      }}
                    </span>
                  </div>
                  <div class="flex items-start justify-between gap-3">
                    <span>{{
                      t('CAPTAIN.OBSERVABILITY.ALERTS.LAST_RESOLVED')
                    }}</span>
                    <span class="font-medium text-n-slate-12">
                      {{
                        lastAlertDeliveryState.last_resolved_at
                          ? formatDateTime(
                              lastAlertDeliveryState.last_resolved_at
                            )
                          : t('GENERAL.NONE')
                      }}
                    </span>
                  </div>
                  <div class="flex items-start justify-between gap-3">
                    <span>{{
                      t('CAPTAIN.OBSERVABILITY.ALERTS.DELIVERY_CHANNELS')
                    }}</span>
                    <span class="font-medium text-n-slate-12">
                      {{
                        lastAlertDeliveryState.last_delivery_channels?.length
                          ? lastAlertDeliveryState.last_delivery_channels.join(
                              ', '
                            )
                          : t('GENERAL.NONE')
                      }}
                    </span>
                  </div>
                </div>
              </div>

              <div v-if="activeAlerts.length" class="mt-4 grid gap-3">
                <div
                  v-for="alert in activeAlerts"
                  :key="`${alert.name}-${alert.severity}`"
                  class="rounded-xl border border-n-weak bg-n-alpha-2 p-4"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="text-sm font-medium text-n-slate-12">
                      {{ humanizeIdentifier(alert.name) }}
                    </div>
                    <span
                      class="rounded-full px-2.5 py-1 text-xs font-medium"
                      :class="statusClass(alert.severity)"
                    >
                      {{ statusLabel(alert.severity) }}
                    </span>
                  </div>
                  <p class="mt-2 text-sm text-n-slate-11">
                    {{ alert.message }}
                  </p>
                  <div
                    v-if="operationalFilterForCheckName(alert.name)"
                    class="mt-3"
                  >
                    <Button
                      :label="
                        t('CAPTAIN.OBSERVABILITY.ACTIONS.VIEW_MATCHING_EVENTS')
                      "
                      variant="outline"
                      color="slate"
                      size="sm"
                      @click="focusOperationalCheck(alert.name)"
                    />
                  </div>
                </div>
              </div>
              <div
                v-else
                class="mt-4 rounded-xl bg-n-alpha-2 p-4 text-sm text-n-slate-11"
              >
                {{ t('CAPTAIN.OBSERVABILITY.ALERTS.EMPTY') }}
              </div>
            </section>

            <section class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
              <h2 class="text-base font-medium text-n-slate-12">
                {{ t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.TITLE') }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{ t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.DESCRIPTION') }}
              </p>

              <div class="mt-4 grid gap-4">
                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{ t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.FEATURES') }}
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <span
                      v-for="[name, count] in topFeatureDistribution"
                      :key="`feature-${name}`"
                      class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                    >
                      {{
                        `${name || t('GENERAL.NONE')} (${formatInteger(count)})`
                      }}
                    </span>
                  </div>
                </div>

                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{ t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.MODELS') }}
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <span
                      v-for="[name, count] in topModelDistribution"
                      :key="`model-${name}`"
                      class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                    >
                      {{
                        `${name || t('GENERAL.NONE')} (${formatInteger(count)})`
                      }}
                    </span>
                  </div>
                </div>

                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{ t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.PROVIDERS') }}
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <span
                      v-for="[name, count] in topProviderDistribution"
                      :key="`provider-${name}`"
                      class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                    >
                      {{
                        `${name || t('GENERAL.NONE')} (${formatInteger(count)})`
                      }}
                    </span>
                  </div>
                </div>

                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{
                      t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.MODERATION_STAGES')
                    }}
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <span
                      v-for="[name, count] in moderationStageDistribution"
                      :key="`moderation-stage-${name}`"
                      class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                    >
                      {{
                        `${humanizeIdentifier(name) || t('GENERAL.NONE')} (${formatInteger(count)})`
                      }}
                    </span>
                  </div>
                </div>

                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{ t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.BLOCK_REASONS') }}
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <span
                      v-for="[name, count] in blockedReasonDistribution"
                      :key="`blocked-reason-${name}`"
                      class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                    >
                      {{
                        `${humanizeIdentifier(name) || t('GENERAL.NONE')} (${formatInteger(count)})`
                      }}
                    </span>
                  </div>
                </div>

                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{
                      t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.FLAGGED_CATEGORIES')
                    }}
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <span
                      v-for="[name, count] in flaggedCategoryDistribution"
                      :key="`flagged-category-${name}`"
                      class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                    >
                      {{
                        `${humanizeIdentifier(name) || t('GENERAL.NONE')} (${formatInteger(count)})`
                      }}
                    </span>
                  </div>
                </div>

                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{
                      t('CAPTAIN.OBSERVABILITY.DISTRIBUTION.MODERATION_REASONS')
                    }}
                  </div>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <span
                      v-for="[name, count] in moderationReasonDistribution"
                      :key="`moderation-reason-${name}`"
                      class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
                    >
                      {{
                        `${humanizeIdentifier(name) || t('GENERAL.NONE')} (${formatInteger(count)})`
                      }}
                    </span>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </section>
      </div>

      <div
        v-else-if="activeTab === 'events'"
        class="rounded-2xl border border-n-weak bg-n-solid-1 p-5"
      >
        <div class="mb-4 flex items-start justify-between gap-4">
          <div>
            <h2 class="text-base font-medium text-n-slate-12">
              {{ t('CAPTAIN.OBSERVABILITY.EVENTS.TITLE') }}
            </h2>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ t('CAPTAIN.OBSERVABILITY.EVENTS.DESCRIPTION') }}
            </p>
          </div>
          <div class="text-xs text-n-slate-11">
            {{
              t('CAPTAIN.OBSERVABILITY.EVENTS.RESULT_COUNT', {
                count: formatInteger(totalCount),
              })
            }}
          </div>
        </div>

        <div class="overflow-x-auto">
          <BaseTable
            :headers="eventHeaders"
            :items="overview.events"
            :no-data-message="t('CAPTAIN.OBSERVABILITY.EMPTY.TITLE')"
            :loading="uiState.loadingOverview"
          >
            <template #row="{ items }">
              <tr v-for="event in items" :key="event.id" class="align-top">
                <td class="py-4 pr-4 text-sm text-n-slate-12 whitespace-nowrap">
                  <div>{{ formatDateTime(event.created_at) }}</div>
                  <div class="mt-1 text-xs text-n-slate-10">
                    {{ `ID ${event.id}` }}
                  </div>
                </td>
                <td class="py-4 pr-4 min-w-[13rem]">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-medium text-n-slate-12">
                      {{ event.event_name }}
                    </span>
                    <span
                      class="rounded-full px-2 py-0.5 text-[0.6875rem] font-medium"
                      :class="statusClass(event.status)"
                    >
                      {{ statusLabel(event.status) }}
                    </span>
                  </div>
                  <div
                    v-if="eventReason(event)"
                    class="mt-2 text-xs text-n-ruby-11"
                  >
                    {{ eventReason(event) }}
                  </div>
                </td>
                <td class="py-4 pr-4 min-w-[14rem]">
                  <div class="flex flex-wrap gap-1.5">
                    <span
                      v-for="item in eventContext(event)"
                      :key="item"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{ item }}
                    </span>
                  </div>
                </td>
                <td class="py-4 pr-4 min-w-[12rem]">
                  <div class="text-sm text-n-slate-12">
                    {{ event.model || t('GENERAL.NONE') }}
                  </div>
                  <div class="mt-1 text-xs text-n-slate-10">
                    {{ event.provider || t('GENERAL.NONE') }}
                  </div>
                </td>
                <td class="py-4 pr-4 min-w-[12rem]">
                  <div
                    v-for="item in eventUsage(event)"
                    :key="item"
                    class="text-xs text-n-slate-11"
                  >
                    {{ item }}
                  </div>
                </td>
                <td class="py-4 min-w-[12rem]">
                  <div class="flex flex-wrap gap-1.5">
                    <span
                      v-for="flag in eventFlags(event)"
                      :key="flag"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{ flag }}
                    </span>
                    <span
                      v-if="eventFlags(event).length === 0"
                      class="text-xs text-n-slate-10"
                    >
                      {{ t('CAPTAIN.OBSERVABILITY.FLAGS.NONE') }}
                    </span>
                  </div>
                  <Button
                    :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.VIEW_DETAILS')"
                    variant="link"
                    color="slate"
                    size="sm"
                    class="mt-2"
                    @click="openEventDetails(event)"
                  />
                </td>
              </tr>
            </template>
          </BaseTable>
        </div>
      </div>

      <div v-else-if="activeTab === 'traces'" class="grid gap-6">
        <section class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="text-base font-medium text-n-slate-12">
                {{ t('CAPTAIN.OBSERVABILITY.TRACES.TITLE') }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{ t('CAPTAIN.OBSERVABILITY.TRACES.DESCRIPTION') }}
              </p>
            </div>
            <div class="text-xs text-n-slate-11">
              {{
                t('CAPTAIN.OBSERVABILITY.TRACES.RESULT_COUNT', {
                  count: formatInteger(traceGroups.length),
                })
              }}
            </div>
          </div>

          <div
            v-if="focusedTraceGroup"
            class="mt-5 rounded-2xl border border-n-weak bg-n-alpha-2 p-5"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <div
                  class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                >
                  {{ t('CAPTAIN.OBSERVABILITY.TRACES.FOCUSED_TRACE') }}
                </div>
                <div class="mt-2 text-base font-medium text-n-slate-12">
                  {{ focusedTraceGroup.label }}
                </div>
                <div class="mt-1 text-sm text-n-slate-11">
                  {{
                    t('CAPTAIN.OBSERVABILITY.TRACES.FOCUSED_RANGE', {
                      startedAt: formatDateTime(focusedTraceGroup.startedAt),
                      endedAt: formatDateTime(focusedTraceGroup.latestAt),
                    })
                  }}
                </div>
                <div class="mt-2 flex flex-wrap gap-2 text-xs text-n-slate-11">
                  <span
                    v-if="focusedTraceGroup.traceId"
                    class="rounded-full bg-n-solid-1 px-2.5 py-1"
                  >
                    {{
                      `${t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.TRACE_ID')}: ${shortIdentifier(
                        focusedTraceGroup.traceId,
                        16
                      )}`
                    }}
                  </span>
                  <span
                    v-if="focusedTraceGroup.rootSpanId"
                    class="rounded-full bg-n-solid-1 px-2.5 py-1"
                  >
                    {{
                      `${t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.ROOT_SPAN_ID')}: ${shortIdentifier(
                        focusedTraceGroup.rootSpanId,
                        16
                      )}`
                    }}
                  </span>
                </div>
              </div>
              <Button
                :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.FOCUS_TRACE')"
                variant="outline"
                color="slate"
                size="sm"
                @click="applyTraceFocus(focusedTraceGroup)"
              />
            </div>

            <div class="mt-4 flex flex-wrap gap-2">
              <span
                class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
              >
                {{
                  t('CAPTAIN.OBSERVABILITY.TRACES.METRICS.EVENTS', {
                    count: formatInteger(focusedTraceGroup.eventCount),
                  })
                }}
              </span>
              <span
                class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
              >
                {{
                  t('CAPTAIN.OBSERVABILITY.TRACES.DURATION', {
                    duration: formatDuration(focusedTraceGroup.durationMs),
                  })
                }}
              </span>
              <span
                v-for="hop in focusedTraceGroup.providerHops"
                :key="`focused-hop-${hop}`"
                class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
              >
                {{ hop }}
              </span>
            </div>
          </div>

          <div class="mt-5 grid gap-4">
            <article
              v-for="group in traceGroups"
              :key="group.id"
              class="rounded-2xl border border-n-weak bg-n-alpha-2 p-5"
            >
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <div
                    class="text-xs uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{ traceTypeLabel(group.type) }}
                  </div>
                  <div class="mt-2 text-base font-medium text-n-slate-12">
                    {{ group.label }}
                  </div>
                  <div class="mt-1 text-sm text-n-slate-11">
                    {{
                      t('CAPTAIN.OBSERVABILITY.TRACES.LATEST_EVENT', {
                        time: formatDateTime(group.latestAt),
                      })
                    }}
                  </div>
                </div>

                <div class="flex flex-wrap items-center gap-2">
                  <span
                    v-if="group.traceId"
                    class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
                  >
                    {{
                      `${t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.TRACE_ID')}: ${shortIdentifier(
                        group.traceId,
                        16
                      )}`
                    }}
                  </span>
                  <span
                    class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
                  >
                    {{
                      t('CAPTAIN.OBSERVABILITY.TRACES.METRICS.EVENTS', {
                        count: formatInteger(group.eventCount),
                      })
                    }}
                  </span>
                  <span
                    class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-ruby-11"
                  >
                    {{
                      t('CAPTAIN.OBSERVABILITY.TRACES.METRICS.ERRORS', {
                        count: formatInteger(group.errorCount),
                      })
                    }}
                  </span>
                  <span
                    class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-amber-11"
                  >
                    {{
                      t('CAPTAIN.OBSERVABILITY.TRACES.METRICS.BLOCKED', {
                        count: formatInteger(group.blockedCount),
                      })
                    }}
                  </span>
                  <span
                    class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
                  >
                    {{
                      t('CAPTAIN.OBSERVABILITY.TRACES.DURATION', {
                        duration: formatDuration(group.durationMs),
                      })
                    }}
                  </span>
                  <Button
                    :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.FOCUS_TRACE')"
                    variant="outline"
                    color="slate"
                    size="sm"
                    @click="applyTraceFocus(group)"
                  />
                </div>
              </div>

              <div class="mt-5 grid gap-3">
                <div
                  v-for="event in group.events"
                  :key="event.id"
                  class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
                  :style="{
                    marginLeft: `${Math.min(event.traceDepth || 0, 4) * 16}px`,
                  }"
                >
                  <div class="flex flex-wrap items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="text-sm font-medium text-n-slate-12">
                        {{ event.event_name }}
                      </div>
                      <div class="mt-1 text-xs text-n-slate-10">
                        {{ formatDateTime(event.created_at) }}
                      </div>
                      <div
                        v-if="eventReason(event)"
                        class="mt-2 text-xs text-n-ruby-11"
                      >
                        {{ eventReason(event) }}
                      </div>
                    </div>

                    <div class="flex items-center gap-2">
                      <span
                        class="rounded-full px-2 py-0.5 text-[0.6875rem] font-medium"
                        :class="statusClass(event.status)"
                      >
                        {{ statusLabel(event.status) }}
                      </span>
                      <Button
                        :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.VIEW_DETAILS')"
                        variant="link"
                        color="slate"
                        size="sm"
                        @click="openEventDetails(event)"
                      />
                    </div>
                  </div>

                  <div class="mt-3 flex flex-wrap gap-1.5">
                    <span
                      v-if="event.span_kind"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{ humanizeIdentifier(event.span_kind) }}
                    </span>
                    <span
                      v-if="event.span_name"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{ event.span_name }}
                    </span>
                    <span
                      v-if="event.span_id"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{
                        `${t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.SPAN_ID')}: ${shortIdentifier(
                          event.span_id,
                          12
                        )}`
                      }}
                    </span>
                    <span
                      v-if="event.parent_span_id"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{
                        `${t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.PARENT_SPAN_ID')}: ${shortIdentifier(
                          event.parent_span_id,
                          12
                        )}`
                      }}
                    </span>
                    <span
                      v-for="hop in group.providerHops"
                      :key="`${group.id}-${hop}`"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{ hop }}
                    </span>
                    <span
                      v-for="item in eventContext(event)"
                      :key="`${event.id}-${item}`"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{ item }}
                    </span>
                    <span
                      v-for="flag in eventFlags(event)"
                      :key="`${event.id}-${flag}`"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] text-n-slate-11"
                    >
                      {{ flag }}
                    </span>
                  </div>
                </div>
              </div>
            </article>
          </div>
        </section>
      </div>

      <div v-else class="grid gap-6">
        <section class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <article class="rounded-2xl border border-n-weak bg-n-solid-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.STATUS') }}
            </div>
            <div class="mt-3 flex items-center gap-2">
              <span
                class="rounded-full px-2.5 py-1 text-xs font-medium"
                :class="statusClass(releaseCheck?.status)"
              >
                {{ statusLabel(releaseCheck?.status) }}
              </span>
            </div>
          </article>
          <article class="rounded-2xl border border-n-weak bg-n-solid-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.TOTAL_CHECKS') }}
            </div>
            <div class="mt-3 text-2xl font-semibold text-n-slate-12">
              {{ formatInteger(releaseReportChecks.length) }}
            </div>
          </article>
          <article class="rounded-2xl border border-n-weak bg-n-solid-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.DETERMINISTIC_SUITES') }}
            </div>
            <div class="mt-3 text-2xl font-semibold text-n-slate-12">
              {{ formatInteger(deterministicSuites.length) }}
            </div>
          </article>
          <article class="rounded-2xl border border-n-weak bg-n-solid-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.LIVE_SUITES') }}
            </div>
            <div class="mt-3 text-2xl font-semibold text-n-slate-12">
              {{ formatInteger(liveSuites.length) }}
            </div>
          </article>
        </section>

        <section class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="text-base font-medium text-n-slate-12">
                {{ t('CAPTAIN.OBSERVABILITY.EVALS.REPORT_TITLE') }}
              </h2>
              <p class="mt-1 text-sm text-n-slate-11">
                {{
                  t('CAPTAIN.OBSERVABILITY.EVALS.REPORT_DESCRIPTION', {
                    generatedAt: formatDateTime(releaseCheck?.generated_at),
                  })
                }}
              </p>
            </div>
            <span
              class="rounded-full px-2.5 py-1 text-xs font-medium"
              :class="statusClass(releaseCheck?.status)"
            >
              {{ statusLabel(releaseCheck?.status) }}
            </span>
          </div>

          <div
            v-if="blockingFailures.length"
            class="mt-4 rounded-xl border border-n-ruby-6 bg-n-ruby-2 p-4"
          >
            <div class="text-sm font-medium text-n-ruby-11">
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.BLOCKING_FAILURES') }}
            </div>
            <div class="mt-3 flex flex-wrap gap-2">
              <span
                v-for="failure in blockingFailures"
                :key="failure.name"
                class="rounded-full bg-n-ruby-3 px-2.5 py-1 text-xs font-medium text-n-ruby-11"
              >
                {{ failure.name }}
              </span>
            </div>
          </div>

          <div class="mt-5 grid gap-3">
            <div
              v-for="check in releaseReportChecks"
              :key="check.name"
              class="rounded-xl border border-n-weak bg-n-alpha-2 p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="text-sm font-medium text-n-slate-12">
                    {{ humanizeIdentifier(check.name) }}
                  </div>
                  <p v-if="check.message" class="mt-1 text-sm text-n-slate-11">
                    {{ check.message }}
                  </p>
                </div>
                <span
                  class="rounded-full px-2.5 py-1 text-xs font-medium"
                  :class="statusClass(check.status)"
                >
                  {{ statusLabel(check.status) }}
                </span>
              </div>
            </div>
          </div>
        </section>

        <section class="grid gap-6 lg:grid-cols-2">
          <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
            <h2 class="text-base font-medium text-n-slate-12">
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.DETERMINISTIC_TITLE') }}
            </h2>
            <div class="mt-4 grid gap-3">
              <div
                v-for="suite in deterministicSuites"
                :key="`${suite.suite_id}-${suite.prompt_sha}`"
                class="rounded-xl border border-n-weak bg-n-alpha-2 p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="text-sm font-medium text-n-slate-12">
                      {{ suite.suite_id }}
                    </div>
                    <div class="mt-1 text-xs text-n-slate-10">
                      {{ suite.model || t('GENERAL.NONE') }}
                    </div>
                  </div>
                  <span
                    class="rounded-full px-2.5 py-1 text-xs font-medium"
                    :class="statusClass(suite.status)"
                  >
                    {{ statusLabel(suite.status) }}
                  </span>
                </div>
                <div class="mt-3 text-xs text-n-slate-11">
                  {{
                    t('CAPTAIN.OBSERVABILITY.EVALS.SUITE_COUNTS', {
                      total: formatInteger(suite.total_count),
                      passed: formatInteger(suite.passed_count),
                      failed: formatInteger(suite.failed_count),
                      errors: formatInteger(suite.error_count),
                    })
                  }}
                </div>
                <div
                  v-if="suiteFailureCases(suite).length"
                  class="mt-4 grid gap-2"
                >
                  <article
                    v-for="testCase in suiteFailureCases(suite).slice(0, 3)"
                    :key="`${suite.suite_id}-${testCase.id}`"
                    class="rounded-xl bg-n-solid-1 p-3"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div>
                        <div class="text-sm font-medium text-n-slate-12">
                          {{ testCase.id }}
                        </div>
                        <div class="mt-1 text-xs text-n-slate-11">
                          {{ testCase.description || t('GENERAL.NONE') }}
                        </div>
                      </div>
                      <span
                        class="rounded-full px-2 py-0.5 text-[0.6875rem] font-medium"
                        :class="statusClass(testCase.status)"
                      >
                        {{ statusLabel(testCase.status) }}
                      </span>
                    </div>
                    <div
                      v-if="testCase.failures?.length"
                      class="mt-2 text-xs text-n-ruby-11"
                    >
                      {{ testCase.failures.join(' | ') }}
                    </div>
                  </article>
                </div>
                <div v-if="suiteFocusFilters(suite)" class="mt-4">
                  <Button
                    :label="
                      t('CAPTAIN.OBSERVABILITY.EVALS.OPEN_RELATED_EVENTS')
                    "
                    variant="outline"
                    color="slate"
                    size="sm"
                    @click="focusSuiteEvents(suite)"
                  />
                </div>
              </div>
            </div>
          </div>

          <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
            <h2 class="text-base font-medium text-n-slate-12">
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.LIVE_TITLE') }}
            </h2>
            <div v-if="liveSuites.length" class="mt-4 grid gap-3">
              <div
                v-for="suite in liveSuites"
                :key="`${suite.suite_id}-${suite.prompt_sha}`"
                class="rounded-xl border border-n-weak bg-n-alpha-2 p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="text-sm font-medium text-n-slate-12">
                      {{ suite.suite_id }}
                    </div>
                    <div class="mt-1 text-xs text-n-slate-10">
                      {{ suite.model || t('GENERAL.NONE') }}
                    </div>
                  </div>
                  <span
                    class="rounded-full px-2.5 py-1 text-xs font-medium"
                    :class="statusClass(suite.status)"
                  >
                    {{ statusLabel(suite.status) }}
                  </span>
                </div>
                <div class="mt-3 text-xs text-n-slate-11">
                  {{
                    t('CAPTAIN.OBSERVABILITY.EVALS.SUITE_COUNTS', {
                      total: formatInteger(suite.total_count),
                      passed: formatInteger(suite.passed_count),
                      failed: formatInteger(suite.failed_count),
                      errors: formatInteger(suite.error_count),
                    })
                  }}
                </div>
                <div
                  v-if="suiteFailureCases(suite).length"
                  class="mt-4 grid gap-2"
                >
                  <article
                    v-for="testCase in suiteFailureCases(suite).slice(0, 3)"
                    :key="`${suite.suite_id}-${testCase.id}`"
                    class="rounded-xl bg-n-solid-1 p-3"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div>
                        <div class="text-sm font-medium text-n-slate-12">
                          {{ testCase.id }}
                        </div>
                        <div class="mt-1 text-xs text-n-slate-11">
                          {{ testCase.description || t('GENERAL.NONE') }}
                        </div>
                      </div>
                      <span
                        class="rounded-full px-2 py-0.5 text-[0.6875rem] font-medium"
                        :class="statusClass(testCase.status)"
                      >
                        {{ statusLabel(testCase.status) }}
                      </span>
                    </div>
                    <div
                      v-if="testCase.failures?.length"
                      class="mt-2 text-xs text-n-ruby-11"
                    >
                      {{ testCase.failures.join(' | ') }}
                    </div>
                  </article>
                </div>
                <div v-if="suiteFocusFilters(suite)" class="mt-4">
                  <Button
                    :label="
                      t('CAPTAIN.OBSERVABILITY.EVALS.OPEN_RELATED_EVENTS')
                    "
                    variant="outline"
                    color="slate"
                    size="sm"
                    @click="focusSuiteEvents(suite)"
                  />
                </div>
              </div>
            </div>
            <div
              v-else
              class="mt-4 rounded-xl bg-n-alpha-2 p-4 text-sm text-n-slate-11"
            >
              {{ t('CAPTAIN.OBSERVABILITY.EVALS.NO_LIVE_SUITES') }}
            </div>
          </div>
        </section>
      </div>
    </template>
  </PageLayout>
  <EventDetailsDialog
    ref="eventDetailsDialogRef"
    @focus-trace="focusTraceFromEvent"
    @open-assistant="openAssistantFromEvent"
    @open-conversation="openConversationFromEvent"
    @open-copilot="openCopilotFromEvent"
  />
</template>
