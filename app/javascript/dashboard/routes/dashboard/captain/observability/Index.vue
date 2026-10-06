<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';

import CaptainObservabilityAPI from 'dashboard/api/captain/observability';
import Button from 'dashboard/components-next/button/Button.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import DatePicker from 'dashboard/components/ui/DatePicker/DatePicker.vue';
import EventDetailsDialog from './EventDetailsDialog.vue';

const { t, locale } = useI18n();
const route = useRoute();
const routeQueryValue = value => (Array.isArray(value) ? value[0] : value);
const traceQueryKeys = [
  'trace_id',
  'session_id',
  'conversation_display_id',
  'copilot_thread_id',
];
const hasTraceQueryContext = query =>
  traceQueryKeys.some(key => Boolean(routeQueryValue(query?.[key])));
const traceContextKey = query =>
  JSON.stringify(
    traceQueryKeys.map(key => routeQueryValue(query?.[key]) || '')
  );
let currentTraceContextKey = traceContextKey(route.query || {});

const events = ref([]);
const timeSeries = ref({ points: [], bucket: 'hour' });
const meta = ref({ count: 0, current_page: 1, per_page: 25 });
const isLoading = ref(false);
const hasError = ref(false);
const selectedRange = ref(
  hasTraceQueryContext(route.query) ? 'account_default' : '30d'
);
const hasManuallySelectedRange = ref(false);
const detailsDialogRef = ref(null);
const showFilters = ref(false);
const calendarKey = ref(0);
const filters = reactive({
  assistantId: '',
  conversationDisplayId: '',
  status: '',
  traceId: '',
  sessionId: '',
  copilotThreadId: '',
});
let latestFetchId = 0;

const rangeDurations = {
  '15m': 15 * 60 * 1000,
  '30m': 30 * 60 * 1000,
  '1h': 60 * 60 * 1000,
  '3h': 3 * 60 * 60 * 1000,
  '24h': 24 * 60 * 60 * 1000,
  '48h': 48 * 60 * 60 * 1000,
  '7d': 7 * 24 * 60 * 60 * 1000,
  '30d': 30 * 24 * 60 * 60 * 1000,
  '1y': 365 * 24 * 60 * 60 * 1000,
};

const customDateRange = ref([
  new Date(Date.now() - rangeDurations['30d']),
  new Date(),
]);
const customRangeType = ref('custom');

const rangeOptions = computed(() => [
  { value: '15m', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.15m') },
  { value: '30m', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.30m') },
  { value: '1h', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.1h') },
  { value: '3h', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.3h') },
  { value: '24h', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.24h') },
  { value: '48h', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.48h') },
  { value: '7d', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.7d') },
  { value: '30d', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.30d') },
  {
    value: 'account_default',
    label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.ACCOUNT_DEFAULT'),
  },
  { value: '1y', label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.1y') },
  {
    value: 'custom',
    label: t('CAPTAIN.OBSERVABILITY.LOGS.RANGES.CUSTOM'),
  },
]);
const statusOptions = computed(() => [
  { value: '', label: t('CAPTAIN.OBSERVABILITY.FILTERS.ALL_STATUSES') },
  { value: 'success', label: t('CAPTAIN.OBSERVABILITY.FILTERS.SUCCESS') },
  { value: 'error', label: t('CAPTAIN.OBSERVABILITY.FILTERS.ERROR') },
]);

const currentPage = computed(() => Number(meta.value.current_page || 1));
const totalCount = computed(() => Number(meta.value.count || 0));
const itemsPerPage = computed(() => Number(meta.value.per_page || 25));
const chartPoints = computed(() => timeSeries.value?.points || []);
const totalRequestCount = computed(() =>
  chartPoints.value.reduce(
    (total, point) => total + Number(point.request_count || 0),
    0
  )
);
const maxRequestCount = computed(() =>
  Math.max(
    1,
    ...chartPoints.value.map(point => Number(point.request_count || 0))
  )
);

const requestRange = () => {
  if (selectedRange.value === 'account_default') return {};

  if (selectedRange.value === 'custom') {
    const [since, until] = customDateRange.value;
    return {
      since: String(Math.floor(since.getTime() / 1000)),
      until: String(Math.floor(until.getTime() / 1000)),
    };
  }

  const until = new Date();
  const since = new Date(until.getTime() - rangeDurations[selectedRange.value]);
  return {
    since: String(Math.floor(since.getTime() / 1000)),
    until: String(Math.floor(until.getTime() / 1000)),
  };
};

const applyRouteFilters = query => {
  filters.assistantId = routeQueryValue(query?.assistant_id) || '';
  filters.conversationDisplayId =
    routeQueryValue(query?.conversation_display_id) || '';
  filters.status = routeQueryValue(query?.status) || '';
  filters.traceId = routeQueryValue(query?.trace_id) || '';
  filters.sessionId = routeQueryValue(query?.session_id) || '';
  filters.copilotThreadId = routeQueryValue(query?.copilot_thread_id) || '';
};
applyRouteFilters(route.query || {});
showFilters.value = Boolean(
  filters.assistantId || filters.conversationDisplayId || filters.status
);

const hasTraceContext = computed(
  () =>
    Boolean(filters.traceId) ||
    Boolean(filters.sessionId) ||
    Boolean(filters.conversationDisplayId) ||
    Boolean(filters.copilotThreadId)
);

const requestParams = page => {
  const params = {
    page,
    per_page: itemsPerPage.value,
    ...requestRange(),
  };

  if (!hasTraceContext.value) {
    params.features = ['assistant', 'captain_agent'];
    params.event_name = 'llm.chat.complete';
  }

  if (filters.assistantId) params.assistant_id = filters.assistantId;
  if (filters.status) params.status = filters.status;
  if (filters.conversationDisplayId) {
    params.conversation_display_id = filters.conversationDisplayId;
  }
  if (filters.traceId) params.trace_id = filters.traceId;
  if (filters.sessionId) params.session_id = filters.sessionId;
  if (filters.copilotThreadId) {
    params.copilot_thread_id = filters.copilotThreadId;
  }

  return params;
};

const fetchEvents = async (page = currentPage.value) => {
  latestFetchId += 1;
  const fetchId = latestFetchId;
  isLoading.value = true;
  hasError.value = false;
  try {
    const response = await CaptainObservabilityAPI.get(requestParams(page));
    if (fetchId !== latestFetchId) return;

    const data = response?.data || response || {};
    events.value = data.payload || [];
    timeSeries.value = data.time_series || { points: [], bucket: 'hour' };
    meta.value = data.meta || {
      count: 0,
      current_page: page,
      per_page: 25,
    };
  } catch {
    if (fetchId === latestFetchId) {
      events.value = [];
      timeSeries.value = { points: [], bucket: 'hour' };
      meta.value = { count: 0, current_page: page, per_page: 25 };
      hasError.value = true;
      useAlert(t('CAPTAIN.OBSERVABILITY.SIMPLE.LOAD_ERROR'));
    }
  } finally {
    if (fetchId === latestFetchId) isLoading.value = false;
  }
};

const applyFilters = () => fetchEvents(1);
const handleRangeSelection = value => {
  hasManuallySelectedRange.value = true;
  selectedRange.value = value;
};
const resetFilters = () => {
  filters.assistantId = '';
  filters.conversationDisplayId = '';
  filters.status = '';
  filters.traceId = '';
  filters.sessionId = '';
  filters.copilotThreadId = '';
  fetchEvents(1);
};

const handleCustomDateRangeChanged = ([since, until]) => {
  customDateRange.value = [since, until];
  calendarKey.value += 1;
  fetchEvents(1);
};

const formatTimestamp = value => {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'medium',
    timeStyle: 'medium',
  }).format(date);
};

const formatChartTimestamp = timestamp => {
  const date = new Date(Number(timestamp) * 1000);
  const isHourly = timeSeries.value?.bucket === 'hour';
  return new Intl.DateTimeFormat(
    locale.value,
    isHourly
      ? { hour: '2-digit', minute: '2-digit' }
      : { month: 'short', day: 'numeric' }
  ).format(date);
};

const formatTokens = value => {
  if (value === null || value === undefined || value === '') return '—';
  return new Intl.NumberFormat(locale.value).format(Number(value));
};
const formatCost = value => {
  if (value === null || value === undefined || value === '') return '—';
  const cost = Number(value);
  return Number.isFinite(cost) ? `$${cost.toFixed(6)}` : '—';
};
const formatDuration = value => {
  if (value === null || value === undefined || value === '') return '—';
  const milliseconds = Number(value);
  if (!Number.isFinite(milliseconds)) return '—';
  return milliseconds < 1000
    ? `${Math.round(milliseconds)} ${t('CAPTAIN.OBSERVABILITY.LOGS.MILLISECONDS')}`
    : `${(milliseconds / 1000).toFixed(2)} ${t('CAPTAIN.OBSERVABILITY.LOGS.SECONDS')}`;
};

const barHeight = point =>
  `${Math.max(
    3,
    (Number(point.request_count || 0) / maxRequestCount.value) * 100
  )}%`;
const barTitle = point =>
  `${formatChartTimestamp(point.timestamp)} · ${t(
    'CAPTAIN.OBSERVABILITY.LOGS.REQUESTS',
    {
      count: Number(point.request_count || 0),
    }
  )}`;

watch(selectedRange, value => {
  if (value !== 'custom') fetchEvents(1);
});
watch(
  () => route.query,
  query => {
    applyRouteFilters(query);
    if (
      filters.assistantId ||
      filters.conversationDisplayId ||
      filters.status
    ) {
      showFilters.value = true;
    }
    const nextTraceContextKey = traceContextKey(query);
    const hasNewSharedTraceLink =
      hasTraceQueryContext(query) &&
      nextTraceContextKey !== currentTraceContextKey &&
      !routeQueryValue(query?.since) &&
      !routeQueryValue(query?.until);
    currentTraceContextKey = nextTraceContextKey;
    if (hasNewSharedTraceLink) hasManuallySelectedRange.value = false;

    if (!hasManuallySelectedRange.value) {
      const nextRange = hasTraceQueryContext(query) ? 'account_default' : '30d';
      if (selectedRange.value !== nextRange) {
        selectedRange.value = nextRange;
        return;
      }
    }
    fetchEvents(1);
  },
  { deep: true }
);
onMounted(() => fetchEvents(1));
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.OBSERVABILITY.LOGS.TITLE')"
    :is-fetching="isLoading"
    :is-empty="!isLoading && !events.length"
    :current-page="currentPage"
    :total-count="totalCount"
    :items-per-page="itemsPerPage"
    :show-assistant-switcher="false"
    :show-know-more="false"
    @update:current-page="fetchEvents"
  >
    <template #subHeader>
      <div class="border-t border-n-weak py-4">
        <div class="flex flex-wrap items-end gap-3">
          <div class="relative min-w-48 flex-1 sm:flex-none">
            <label
              for="observability-range"
              class="mb-1 block text-xs text-n-slate-11"
            >
              {{ t('CAPTAIN.OBSERVABILITY.FILTERS.PERIOD') }}
            </label>
            <Select
              id="observability-range"
              :model-value="selectedRange"
              :options="rangeOptions"
              class="w-full"
              @update:model-value="handleRangeSelection"
            />
            <DatePicker
              v-if="selectedRange === 'custom'"
              :key="calendarKey"
              v-model:date-range="customDateRange"
              v-model:range-type="customRangeType"
              calendar-only
              compact
              force-open
              hide-trigger
              @date-range-changed="handleCustomDateRangeChanged"
            />
          </div>
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.FILTERS')"
            icon="i-lucide-list-filter"
            variant="outline"
            color="slate"
            size="sm"
            :aria-expanded="showFilters"
            @click="showFilters = !showFilters"
          />
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.SIMPLE.REFRESH')"
            icon="i-lucide-refresh-cw"
            variant="outline"
            color="slate"
            size="sm"
            :disabled="isLoading"
            @click="fetchEvents()"
          />
        </div>
        <div v-if="showFilters" class="mt-3 flex flex-wrap items-end gap-3">
          <label
            class="flex min-w-44 flex-1 flex-col gap-1 text-xs text-n-slate-11"
          >
            <span>
              {{ t('CAPTAIN.OBSERVABILITY.FILTERS.CONVERSATION_DISPLAY_ID') }}
            </span>
            <input
              v-model.trim="filters.conversationDisplayId"
              class="h-9 rounded-lg border border-n-weak bg-n-solid-1 px-3 text-sm text-n-slate-12 outline-none focus:ring-1 focus:ring-n-brand"
              type="text"
              inputmode="numeric"
              :aria-label="
                t('CAPTAIN.OBSERVABILITY.FILTERS.CONVERSATION_DISPLAY_ID')
              "
              @keyup.enter="applyFilters"
            />
          </label>
          <label
            class="flex min-w-44 flex-1 flex-col gap-1 text-xs text-n-slate-11"
          >
            <span>{{ t('CAPTAIN.OBSERVABILITY.FILTERS.ASSISTANT_ID') }}</span>
            <input
              v-model.trim="filters.assistantId"
              class="h-9 rounded-lg border border-n-weak bg-n-solid-1 px-3 text-sm text-n-slate-12 outline-none focus:ring-1 focus:ring-n-brand"
              type="text"
              inputmode="numeric"
              :aria-label="t('CAPTAIN.OBSERVABILITY.FILTERS.ASSISTANT_ID')"
              @keyup.enter="applyFilters"
            />
          </label>
          <div class="min-w-44 flex-1">
            <label
              for="observability-status"
              class="mb-1 block text-xs text-n-slate-11"
            >
              {{ t('CAPTAIN.OBSERVABILITY.FILTERS.STATUS') }}
            </label>
            <Select
              id="observability-status"
              v-model="filters.status"
              :options="statusOptions"
              class="w-full"
            />
          </div>
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.APPLY_FILTERS')"
            size="sm"
            :disabled="isLoading"
            @click="applyFilters"
          />
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.ACTIONS.RESET_FILTERS')"
            variant="outline"
            color="slate"
            size="sm"
            :disabled="isLoading"
            @click="resetFilters"
          />
        </div>
      </div>
    </template>

    <template #emptyState>
      <div
        v-if="hasError"
        class="flex h-full min-h-80 flex-col items-center justify-center gap-3 text-center"
        role="alert"
      >
        <p class="text-sm text-n-slate-11">
          {{ t('CAPTAIN.OBSERVABILITY.SIMPLE.LOAD_ERROR') }}
        </p>
        <Button
          :label="t('CAPTAIN.OBSERVABILITY.SIMPLE.REFRESH')"
          variant="outline"
          color="slate"
          size="sm"
          @click="fetchEvents(1)"
        />
      </div>
      <div
        v-else
        class="flex h-full min-h-80 flex-col items-center justify-center gap-3 text-center"
      >
        <span class="i-lucide-chart-no-axes-column size-8 text-n-slate-9" />
        <div>
          <h2 class="text-base font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.LOGS.EMPTY_TITLE') }}
          </h2>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ t('CAPTAIN.OBSERVABILITY.LOGS.EMPTY_DESCRIPTION') }}
          </p>
        </div>
      </div>
    </template>

    <template #body>
      <div class="flex flex-col gap-6">
        <section class="rounded-xl border border-n-weak bg-n-alpha-1 p-4">
          <div class="mb-4 flex items-center justify-between gap-4">
            <div>
              <h2 class="text-sm font-medium text-n-slate-12">
                {{ t('CAPTAIN.OBSERVABILITY.LOGS.TIMELINE_TITLE') }}
              </h2>
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.OBSERVABILITY.LOGS.TIMELINE_DESCRIPTION') }}
              </p>
            </div>
            <span class="text-xs text-n-slate-10">
              {{
                t('CAPTAIN.OBSERVABILITY.LOGS.TOTAL_REQUESTS', {
                  count: totalRequestCount,
                })
              }}
            </span>
          </div>
          <div
            class="flex h-48 items-end gap-1 border-b border-n-weak px-1 pt-4"
          >
            <div
              v-for="point in chartPoints"
              :key="point.timestamp"
              class="group relative flex h-full min-w-1 flex-1 items-end"
              :title="barTitle(point)"
            >
              <div
                class="w-full rounded-t bg-n-blue-9 transition-colors group-hover:bg-n-blue-10"
                :style="{ height: barHeight(point) }"
              />
            </div>
          </div>
          <div
            v-if="chartPoints.length"
            class="mt-2 flex justify-between text-xxs text-n-slate-9"
          >
            <span>{{ formatChartTimestamp(chartPoints[0].timestamp) }}</span>
            <span>{{
              formatChartTimestamp(chartPoints.at(-1).timestamp)
            }}</span>
          </div>
        </section>

        <section
          class="overflow-x-auto rounded-xl border border-n-weak bg-n-alpha-1"
        >
          <table class="w-full min-w-[1200px] border-collapse text-left">
            <thead
              class="border-b border-n-weak bg-n-alpha-2 text-xs font-medium text-n-slate-11"
            >
              <tr>
                <th class="px-4 py-3">
                  {{ t('CAPTAIN.OBSERVABILITY.LOGS.COLUMNS.DATETIME') }}
                </th>
                <th class="px-4 py-3">
                  {{ t('CAPTAIN.OBSERVABILITY.SIMPLE.EVENT') }}
                </th>
                <th class="px-4 py-3">
                  {{ t('CAPTAIN.OBSERVABILITY.FILTERS.ASSISTANT_ID') }}
                </th>
                <th class="px-4 py-3">
                  {{
                    t('CAPTAIN.OBSERVABILITY.FILTERS.CONVERSATION_DISPLAY_ID')
                  }}
                </th>
                <th class="px-4 py-3">
                  {{ t('CAPTAIN.OBSERVABILITY.LOGS.COLUMNS.MODEL') }}
                </th>
                <th class="px-4 py-3 text-right">
                  {{ t('CAPTAIN.OBSERVABILITY.LOGS.COLUMNS.INPUT_TOKENS') }}
                </th>
                <th class="px-4 py-3 text-right">
                  {{ t('CAPTAIN.OBSERVABILITY.LOGS.COLUMNS.OUTPUT_TOKENS') }}
                </th>
                <th class="px-4 py-3 text-right">
                  {{ t('CAPTAIN.OBSERVABILITY.LOGS.COLUMNS.COST') }}
                </th>
                <th class="px-4 py-3 text-right">
                  {{ t('CAPTAIN.OBSERVABILITY.LOGS.COLUMNS.DURATION') }}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-n-weak text-sm text-n-slate-12">
              <tr
                v-for="event in events"
                :key="event.id"
                class="cursor-pointer hover:bg-n-alpha-2"
                @click="detailsDialogRef?.open(event)"
              >
                <td class="whitespace-nowrap px-4 py-3">
                  {{ formatTimestamp(event.created_at) }}
                </td>
                <td class="max-w-72 truncate px-4 py-3">
                  {{ event.event_name || '—' }}
                </td>
                <td class="px-4 py-3 tabular-nums">
                  {{ event.assistant_id ?? '—' }}
                </td>
                <td class="px-4 py-3 tabular-nums">
                  {{ event.conversation_display_id ?? '—' }}
                </td>
                <td class="max-w-72 truncate px-4 py-3 font-medium">
                  {{ event.model || '—' }}
                </td>
                <td class="px-4 py-3 text-right tabular-nums">
                  {{ formatTokens(event.prompt_tokens) }}
                </td>
                <td class="px-4 py-3 text-right tabular-nums">
                  {{ formatTokens(event.completion_tokens) }}
                </td>
                <td class="px-4 py-3 text-right tabular-nums">
                  {{ formatCost(event.estimated_cost) }}
                </td>
                <td class="px-4 py-3 text-right tabular-nums">
                  {{ formatDuration(event.duration_ms) }}
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </template>
  </PageLayout>

  <EventDetailsDialog ref="detailsDialogRef" />
</template>
