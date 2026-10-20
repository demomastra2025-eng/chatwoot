<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  DsChartFrame,
  DsState,
  DsStatusDot,
  DsTable,
} from 'dashboard/components-next/ds';
import {
  chartSeries,
  filterAccounts,
  statusTone,
} from '../../helpers/healthMatrix';

// «Сводка»: the part of the page that needs a script. The page title, the headline tiles, the list «Нужно проверить» and the
// reminder about two-factor sign-in are drawn by the server (app/views/super_admin/dashboard/index.html.erb). This is the
// detail: the table «Подробно по каналам» (every account with its WhatsApp, telephony and MedElement), folded away because the
// list «Нужно проверить» already names what is wrong, and the chart of conversations.
const props = defineProps({
  componentData: {
    type: Object,
    default: () => ({}),
  },
});

const { t } = useI18n();

const searchQuery = ref('');
const view = ref('all');
const showDetails = ref(false);
const showChart = ref(false);

const healthAccounts = computed(() => props.componentData.healthAccounts || []);
const healthSummary = computed(() => props.componentData.healthSummary || {});
const incompleteSources = computed(
  () => healthSummary.value.incomplete_sources || []
);
const attentionCount = computed(
  () => healthAccounts.value.filter(account => account.needs_attention).length
);

const filteredAccounts = computed(() =>
  filterAccounts(healthAccounts.value, {
    query: searchQuery.value,
    onlyNeedsAttention: view.value === 'attention',
  })
);

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
    <section class="admin-collapse" data-testid="health-details">
      <button
        type="button"
        class="reset-base flex w-full cursor-pointer items-center justify-between gap-3 rounded-xl border-0 bg-transparent px-5 py-4 text-start"
        :aria-expanded="showDetails"
        aria-controls="health-details-body"
        data-testid="health-details-toggle"
        @click="showDetails = !showDetails"
      >
        <span class="flex min-w-0 flex-col gap-0.5">
          <span class="text-heading-2 text-n-slate-12">
            {{ t('DASHBOARD.DETAILS.TITLE') }}
          </span>
          <span class="text-body-main text-n-slate-11">
            {{
              attentionCount
                ? t('DASHBOARD.DETAILS.HINT_ATTENTION', {
                    count: attentionCount,
                    total: healthAccounts.length,
                  })
                : t('DASHBOARD.DETAILS.HINT', { total: healthAccounts.length })
            }}
          </span>
        </span>
        <span
          class="i-lucide-chevron-down size-4 shrink-0 text-n-slate-11 transition-transform"
          :class="{ 'rotate-180': showDetails }"
          aria-hidden="true"
        />
      </button>

      <div
        v-if="showDetails"
        id="health-details-body"
        class="flex flex-col gap-4 border-0 border-t border-solid border-n-weak pb-2 pt-4"
        data-testid="health-details-body"
      >
        <div
          v-if="incompleteSources.length"
          class="admin-notice admin-notice--amber mx-5"
          role="status"
          data-testid="health-incomplete-sources"
        >
          {{
            t('DASHBOARD.INCOMPLETE', { sources: incompleteSources.join(', ') })
          }}
        </div>

        <div class="flex flex-wrap items-center gap-3 px-5">
          <input
            v-model="searchQuery"
            type="search"
            class="min-w-0 flex-1 basis-64 sm:max-w-sm"
            :placeholder="t('DASHBOARD.TOOLBAR.SEARCH_PLACEHOLDER')"
            :aria-label="t('DASHBOARD.TOOLBAR.SEARCH_PLACEHOLDER')"
          />
          <div
            class="segmented"
            role="group"
            :aria-label="t('DASHBOARD.TOOLBAR.VIEW')"
          >
            <button
              v-for="option in viewOptions"
              :key="option.value"
              type="button"
              class="segmented__item reset-base"
              :aria-current="view === option.value ? 'true' : null"
              @click="view = option.value"
            >
              {{ option.label }}
            </button>
          </div>
          <span class="text-xs tabular-nums text-n-slate-11">
            {{
              t('DASHBOARD.TABLE.SHOWING', {
                shown: filteredAccounts.length,
                total: healthAccounts.length,
              })
            }}
          </span>
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
          :caption="t('DASHBOARD.DETAILS.TITLE')"
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
            <span v-else class="text-n-slate-11">{{ value || 0 }}</span>
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
      </div>
    </section>

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
          {{
            showChart ? t('DASHBOARD.CHART.HIDE') : t('DASHBOARD.CHART.SHOW')
          }}
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
        class="max-w-3xl"
      />
    </div>
  </div>
</template>
