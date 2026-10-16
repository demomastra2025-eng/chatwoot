<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  DsCard,
  DsChartFrame,
  DsSegmented,
  DsState,
  DsStatGroup,
  DsStatusDot,
  DsTable,
} from 'dashboard/components-next/ds';
import {
  chartSeries,
  filterAccounts,
  statusTone,
} from '../../helpers/healthMatrix';

// «Сводка»: the state of every clinic at a glance. The page title, the time of the data and the refresh
// button are drawn by the server (app/views/super_admin/dashboard/index.html.erb), this is the body.
const props = defineProps({
  componentData: {
    type: Object,
    default: () => ({}),
  },
});

const { t } = useI18n();

const searchQuery = ref('');
const view = ref('all');
const showChart = ref(false);

const healthAccounts = computed(() => props.componentData.healthAccounts || []);
const healthSummary = computed(() => props.componentData.healthSummary || {});
const incompleteSources = computed(
  () => healthSummary.value.incomplete_sources || []
);

const filteredAccounts = computed(() =>
  filterAccounts(healthAccounts.value, {
    query: searchQuery.value,
    onlyNeedsAttention: view.value === 'attention',
  })
);

const kpiItems = computed(() => [
  {
    key: 'clinics',
    label: t('DASHBOARD.KPI.CLINICS'),
    value: healthSummary.value.total_accounts ?? 0,
    note: t('DASHBOARD.KPI.CLINICS_NOTE'),
  },
  {
    key: 'attention',
    label: t('DASHBOARD.KPI.ATTENTION'),
    value: healthSummary.value.needs_attention ?? 0,
    note: t('DASHBOARD.KPI.ATTENTION_NOTE'),
  },
  {
    key: 'whatsapp',
    label: t('DASHBOARD.KPI.WHATSAPP'),
    value: healthSummary.value.whatsapp_healthy ?? 0,
    note: t('DASHBOARD.KPI.WHATSAPP_NOTE'),
  },
  {
    key: 'telephony',
    label: t('DASHBOARD.KPI.TELEPHONY'),
    value: healthSummary.value.telephony_healthy ?? 0,
    note: t('DASHBOARD.KPI.TELEPHONY_NOTE'),
  },
]);

const viewOptions = computed(() => [
  { value: 'all', label: t('DASHBOARD.TOOLBAR.VIEW_ALL') },
  { value: 'attention', label: t('DASHBOARD.TOOLBAR.VIEW_ATTENTION') },
]);

const columns = computed(() => [
  { key: 'name', label: t('DASHBOARD.TABLE.CLINIC') },
  { key: 'whatsapp', label: t('DASHBOARD.TABLE.WHATSAPP') },
  { key: 'telephony', label: t('DASHBOARD.TABLE.TELEPHONY') },
  { key: 'medelement', label: t('DASHBOARD.TABLE.MEDELEMENT') },
  { key: 'failed_messages', label: t('DASHBOARD.TABLE.STUCK') },
  { key: 'actions', label: t('DASHBOARD.TABLE.ACTIONS'), align: 'end' },
]);

const chart = computed(() => chartSeries(props.componentData.chartData));
const series = computed(() => [
  {
    key: 'conversations',
    label: t('DASHBOARD.CHART.SERIES'),
    values: chart.value.values,
  },
]);

const clinicUrl = account => `/super_admin/accounts/${account.id}`;
</script>

<template>
  <div class="flex min-w-0 flex-col gap-5" data-testid="health-dashboard">
    <div
      v-if="incompleteSources.length"
      class="admin-notice admin-notice--amber"
      role="status"
      data-testid="health-incomplete-sources"
    >
      {{
        t('DASHBOARD.INCOMPLETE', { sources: incompleteSources.join(', ') })
      }}
    </div>

    <DsStatGroup :items="kpiItems" data-testid="health-kpi">
      <template #value="{ item }">
        <span
          :class="
            item.key === 'attention' && item.value > 0 ? 'text-n-ruby-11' : ''
          "
          >{{ item.value }}</span
        >
      </template>
    </DsStatGroup>

    <DsCard
      :padded="false"
      :title="t('DASHBOARD.TABLE.TITLE')"
      :subtitle="
        t('DASHBOARD.TABLE.SHOWING', {
          shown: filteredAccounts.length,
          total: healthAccounts.length,
        })
      "
    >
      <div class="flex flex-wrap items-center gap-3 px-5 pb-4">
        <input
          v-model="searchQuery"
          type="search"
          class="min-w-0 flex-1 basis-64 sm:max-w-sm"
          :placeholder="t('DASHBOARD.TOOLBAR.SEARCH_PLACEHOLDER')"
          :aria-label="t('DASHBOARD.TOOLBAR.SEARCH_PLACEHOLDER')"
        />
        <DsSegmented
          v-model="view"
          :options="viewOptions"
          :label="t('DASHBOARD.TOOLBAR.VIEW')"
        />
      </div>

      <DsState
        v-if="!filteredAccounts.length"
        state="empty"
        compact
        :title="t('DASHBOARD.TABLE.EMPTY_TITLE')"
        :description="t('DASHBOARD.TABLE.EMPTY_HINT')"
      />
      <DsTable
        v-else
        :columns="columns"
        :rows="filteredAccounts"
        :caption="t('DASHBOARD.TABLE.TITLE')"
      >
        <template #cell-name="{ row }">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span class="text-xs tabular-nums text-n-slate-11">
              {{ `#${row.id}` }}
            </span>
            <a
              :href="clinicUrl(row)"
              class="font-medium text-n-slate-12 hover:text-n-brand hover:underline"
            >
              {{ row.name }}
            </a>
            <span
              v-if="row.status === 'suspended'"
              class="admin-badge admin-badge--amber"
            >
              {{ t('DASHBOARD.TABLE.SUSPENDED') }}
            </span>
          </div>
        </template>

        <template #cell-whatsapp="{ value }">
          <DsStatusDot
            :status="statusTone(value?.state)"
            :label="value?.label || ''"
          />
        </template>

        <template #cell-telephony="{ value }">
          <DsStatusDot
            :status="statusTone(value?.state)"
            :label="value?.label || ''"
          />
        </template>

        <template #cell-medelement="{ value }">
          <DsStatusDot
            :status="statusTone(value?.state)"
            :label="value?.label || ''"
          />
        </template>

        <template #cell-failed_messages="{ value }">
          <DsStatusDot
            v-if="value > 0"
            status="bad"
            :label="t('DASHBOARD.TABLE.STUCK_COUNT', { count: value })"
          />
          <span v-else class="text-n-slate-11">{{ 0 }}</span>
        </template>

        <template #cell-actions="{ row }">
          <a
            :href="clinicUrl(row)"
            class="text-sm font-medium text-n-brand hover:text-n-brand hover:underline"
          >
            {{ t('DASHBOARD.TABLE.OPEN') }}
          </a>
        </template>
      </DsTable>
    </DsCard>

    <div class="flex flex-col gap-3">
      <div>
        <button
          type="button"
          class="button button--secondary"
          :aria-expanded="showChart"
          data-testid="health-chart-toggle"
          @click="showChart = !showChart"
        >
          <span class="i-lucide-chart-column size-4" aria-hidden="true" />
          {{ showChart ? t('DASHBOARD.CHART.HIDE') : t('DASHBOARD.CHART.SHOW') }}
        </button>
      </div>
      <DsChartFrame
        v-if="showChart"
        :title="t('DASHBOARD.CHART.TITLE')"
        :subtitle="t('DASHBOARD.CHART.SUBTITLE')"
        :labels="chart.labels"
        :series="series"
        :category-label="t('DASHBOARD.CHART.CATEGORY')"
        :height="200"
      />
    </div>
  </div>
</template>
