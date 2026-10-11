<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import ReportsAPI from 'dashboard/api/standaloneReports';
import Button from 'dashboard/components-next/button/Button.vue';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import BarChart from 'shared/components/charts/BarChart.vue';
import ReportHeader from './components/ReportHeader.vue';
import ReportMetricCard from './components/ReportMetricCard.vue';
import ReportDateRange from './components/ReportDateRange.vue';

const { t, locale } = useI18n();
const route = useRoute();
const accountId = computed(() => String(route.params.accountId || ''));
const report = ref({});
const fromDate = ref('');
const toDate = ref('');
const timezone = ref('UTC');
const assistantId = ref('');
const maxRangeDays = ref(90);
const loading = ref(false);
const hasError = ref(false);
let generation = 0;

const formatNumber = value =>
  new Intl.NumberFormat(locale.value).format(Number(value || 0));
const label = key => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t('AI_REPORTS.' + key);
};
const agentName = agent =>
  agent?.name ||
  t('AI_REPORTS.DELETED_AGENT', { id: agent?.id ?? agent?.assistant_id });
const totals = computed(() => report.value.totals || {});
const agents = computed(() => report.value.agents || []);
const agentRows = computed(() => report.value.agent_breakdown || []);
const reasons = computed(() => report.value.reasons || []);
const series = computed(() => report.value.series || []);
const hasEvents = computed(
  () =>
    Number(totals.value.message_count || 0) +
      Number(totals.value.outcome_count || 0) >
    0
);
const agentOptions = computed(() => [
  { value: '', label: t('AI_REPORTS.ALL_AGENTS') },
  ...agents.value.map(agent => ({
    value: String(agent.id),
    label: agentName(agent),
  })),
]);
const metrics = [
  ['conversation_count', 'CONVERSATIONS', 'CONVERSATIONS_HELP'],
  ['message_count', 'MESSAGES', 'MESSAGES_HELP'],
  ['completion_count', 'COMPLETIONS', 'OUTCOMES_HELP'],
  ['handoff_count', 'HANDOFFS', 'OUTCOMES_HELP'],
];
const classificationRows = computed(() =>
  [
    'completed',
    'pending',
    'processing',
    'failed',
    'insufficient_context',
    'unclassified',
  ].map(state => ({
    state,
    label: label('STATES.' + state.toUpperCase()),
    count: totals.value.classification_counts?.[state] || 0,
  }))
);
const chartData = computed(() => ({
  labels: series.value.map(row =>
    new Intl.DateTimeFormat(locale.value, {
      day: 'numeric',
      month: 'short',
      timeZone: 'UTC',
    }).format(new Date(row.date + 'T12:00:00Z'))
  ),
  datasets: [
    ['message_count', 'MESSAGES', '#7455d4'],
    ['completion_count', 'COMPLETIONS', '#16a394'],
    ['handoff_count', 'HANDOFFS', '#df9b30'],
  ].map(([key, title, color]) => ({
    label: label(title),
    data: series.value.map(row => row[key] || 0),
    backgroundColor: color,
    borderRadius: 3,
    maxBarThickness: 20,
  })),
}));
const chartOptions = {
  plugins: { legend: { position: 'bottom' } },
  scales: {
    x: { grid: { display: false } },
    y: { beginAtZero: true, ticks: { precision: 0 } },
  },
};
const reasonAgent = row =>
  agentName(agents.value.find(agent => agent.id === row.assistant_id) || row);

const loadReport = async (range = {}) => {
  generation += 1;
  const request = generation;
  const account = accountId.value;
  loading.value = true;
  hasError.value = false;
  try {
    const response = await ReportsAPI.getAiAgents({
      ...range,
      assistantId: assistantId.value || undefined,
    });
    if (request !== generation || account !== accountId.value) return;
    report.value = response.data?.payload || {};
    const meta = response.data?.meta || {};
    fromDate.value = meta.from_date || range.fromDate || '';
    toDate.value = meta.to_date || range.toDate || '';
    timezone.value = meta.timezone || 'UTC';
    maxRangeDays.value = meta.max_range_days || 90;
  } catch {
    if (request !== generation || account !== accountId.value) return;
    report.value = {};
    hasError.value = true;
  } finally {
    if (request === generation) loading.value = false;
  }
};
const reload = () =>
  loadReport({ fromDate: fromDate.value, toDate: toDate.value });
const selectAgent = value => {
  assistantId.value = value;
  reload();
};
watch(
  accountId,
  () => {
    report.value = {};
    fromDate.value = '';
    toDate.value = '';
    assistantId.value = '';
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
    :header-title="t('AI_REPORTS.TITLE')"
    :header-description="t('AI_REPORTS.DESCRIPTION')"
  />
  <div class="flex min-w-0 flex-col gap-4 pb-8">
    <ReportDateRange
      v-model:from-date="fromDate"
      v-model:to-date="toDate"
      :timezone="timezone"
      :max-range-days="maxRangeDays"
      :is-loading="loading"
      @apply="loadReport"
    />
    <div class="flex flex-wrap items-center gap-3">
      <span class="text-sm font-medium text-n-slate-11">{{
        t('AI_REPORTS.AGENT')
      }}</span>
      <SelectMenu
        :model-value="assistantId"
        :options="agentOptions"
        :label="
          agentOptions.find(option => option.value === assistantId)?.label ||
          t('AI_REPORTS.ALL_AGENTS')
        "
        :trigger-aria-label="t('AI_REPORTS.AGENT')"
        :inert="loading"
        sub-menu-position="bottom"
        sub-menu-align="start"
        @update:model-value="selectAgent"
      />
    </div>
    <div
      v-if="loading"
      role="status"
      class="flex items-center justify-center gap-2 py-16 text-sm text-n-slate-11"
    >
      <Spinner />{{ t('AI_REPORTS.LOADING') }}
    </div>
    <div
      v-else-if="hasError"
      role="alert"
      class="flex items-center justify-between gap-3 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
    >
      <p class="m-0 text-sm text-n-slate-11">{{ t('AI_REPORTS.ERROR') }}</p>
      <Button :label="t('AI_REPORTS.RETRY')" size="sm" @click="reload" />
    </div>
    <template v-else>
      <div
        class="grid grid-cols-2 gap-5 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container xl:grid-cols-4"
        data-testid="ai-report-totals"
      >
        <ReportMetricCard
          v-for="[key, title, help] in metrics"
          :key="key"
          :label="label(title)"
          :value="formatNumber(totals[key])"
          :info-text="label(help)"
        />
      </div>
      <p class="m-0 text-xs leading-5 text-n-slate-10">
        {{ t('AI_REPORTS.COUNTING_NOTE') }}
        {{ t('AI_REPORTS.HISTORY_NOTE') }}
      </p>
      <p v-if="!hasEvents" class="m-0 py-8 text-center text-sm text-n-slate-11">
        {{ t('AI_REPORTS.EMPTY') }}
      </p>
      <section
        v-else
        class="min-w-0 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
      >
        <h2 class="mb-4 mt-0 text-heading-2 text-n-slate-12">
          {{ t('AI_REPORTS.DYNAMICS') }}
        </h2>
        <div class="h-64" role="img" :aria-label="t('AI_REPORTS.DYNAMICS')">
          <BarChart :collection="chartData" :chart-options="chartOptions" />
        </div>
      </section>
      <section
        class="min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
      >
        <h2
          class="m-0 border-b border-n-weak px-5 py-4 text-heading-2 text-n-slate-12"
        >
          {{ t('AI_REPORTS.BY_AGENT') }}
        </h2>
        <div class="overflow-x-auto">
          <table class="w-full text-left text-sm">
            <thead class="border-b border-n-weak text-xs text-n-slate-10">
              <tr>
                <th class="py-3 pl-5 pr-4 font-medium">
                  {{ t('AI_REPORTS.AGENT') }}
                </th>
                <th
                  v-for="[, title] in metrics"
                  :key="title"
                  class="px-3 py-3 text-right font-medium last:pr-5"
                >
                  {{ label(title) }}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-n-weak">
              <tr
                v-for="row in agentRows"
                :key="row.assistant_id"
                class="text-n-slate-11"
              >
                <td class="py-3 pl-5 pr-4">{{ agentName(row) }}</td>
                <td
                  v-for="[key] in metrics"
                  :key="key"
                  class="px-3 py-3 text-right tabular-nums last:pr-5"
                >
                  {{ formatNumber(row[key]) }}
                </td>
              </tr>
              <tr v-if="!agentRows.length">
                <td colspan="5" class="px-5 py-6 text-center text-n-slate-10">
                  {{ t('AI_REPORTS.EMPTY') }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      <section
        class="rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
      >
        <h2 class="mb-2 mt-0 text-heading-2 text-n-slate-12">
          {{ t('AI_REPORTS.CLASSIFICATION') }}
        </h2>
        <p class="mb-4 mt-0 text-xs leading-5 text-n-slate-10">
          {{ t('AI_REPORTS.CLASSIFICATION_HELP') }}
        </p>
        <dl
          class="m-0 grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-3 xl:grid-cols-6"
        >
          <div
            v-for="row in classificationRows"
            :key="row.state"
            :data-testid="'classification-' + row.state"
          >
            <dt class="text-xs text-n-slate-11">{{ row.label }}</dt>
            <dd
              class="m-0 mt-1 text-xl font-medium tabular-nums text-n-slate-12"
            >
              {{ formatNumber(row.count) }}
            </dd>
          </div>
        </dl>
      </section>
      <section
        class="rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
      >
        <h2 class="mb-3 mt-0 text-heading-2 text-n-slate-12">
          {{ t('AI_REPORTS.REASONS') }}
        </h2>
        <ul class="m-0 list-none divide-y divide-n-weak p-0">
          <li
            v-for="row in reasons"
            :key="[row.assistant_id, row.type, row.reason_id].join('-')"
            class="flex items-center justify-between gap-4 py-3 first:pt-0 last:pb-0"
          >
            <div class="min-w-0">
              <p class="m-0 break-words text-sm text-n-slate-12">
                {{ row.label }}
              </p>
              <p class="m-0 mt-1 text-xs text-n-slate-10">
                {{
                  t('AI_REPORTS.REASON_CONTEXT', {
                    agent: reasonAgent(row),
                    type:
                      row.type === 'handoff'
                        ? t('AI_REPORTS.HANDOFFS')
                        : t('AI_REPORTS.COMPLETIONS'),
                  })
                }}
              </p>
            </div>
            <span
              class="shrink-0 text-sm font-medium tabular-nums text-n-slate-12"
              >{{ formatNumber(row.count) }}</span
            >
          </li>
        </ul>
        <p v-if="!reasons.length" class="m-0 py-2 text-sm text-n-slate-10">
          {{ t('AI_REPORTS.NO_REASONS') }}
        </p>
      </section>
      <p class="m-0 text-xs leading-5 text-n-slate-10">
        {{ t('AI_REPORTS.UNAVAILABLE_NOTE') }}
      </p>
    </template>
  </div>
</template>
