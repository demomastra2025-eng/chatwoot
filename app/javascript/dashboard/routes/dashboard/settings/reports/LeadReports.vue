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

const referrals = computed(() => report.value.referrals || {});
const submissions = computed(() => report.value.form_submissions || {});
const processing = computed(() => report.value.processing || {});
const referralRows = computed(
  () => referrals.value.attribution_breakdown || []
);
const sourceStatusRows = computed(
  () => submissions.value.source_status_breakdown || []
);
const formRows = computed(() => submissions.value.form_breakdown || []);
const sourceRows = computed(() => submissions.value.utm_source_breakdown || []);
const campaignRows = computed(
  () => submissions.value.utm_campaign_breakdown || []
);

const numberFormatter = computed(() => new Intl.NumberFormat(locale.value));
const number = value => numberFormatter.value.format(Number(value || 0));
const seconds = value => {
  if (value === null || value === undefined) return '—';
  return new Intl.NumberFormat(locale.value, {
    maximumFractionDigits: 1,
    style: 'unit',
    unit: 'second',
    unitDisplay: 'short',
  }).format(Number(value));
};
const localizedValue = (namespace, value) => {
  const key = `${namespace}.${value || 'unknown'}`;
  return te(key) ? t(key) : value || t('REPORTS.LEADS.UNKNOWN');
};
const referralMetrics = computed(() => [
  {
    key: 'events',
    label: t('REPORTS.LEADS.REFERRAL_EVENTS'),
    value: number(referrals.value.event_count),
  },
  {
    key: 'contacts',
    label: t('REPORTS.LEADS.UNIQUE_REFERRAL_CONTACTS'),
    value: number(referrals.value.unique_contact_count),
  },
  {
    key: 'unlinked',
    label: t('REPORTS.LEADS.UNLINKED_REFERRALS'),
    value: number(referrals.value.events_without_contact_count),
  },
  {
    key: 'ads',
    label: t('REPORTS.LEADS.EXPLICIT_AD_EVENTS'),
    value: number(referrals.value.explicit_paid_ad_event_count),
  },
  {
    key: 'other',
    label: t('REPORTS.LEADS.OTHER_REFERRALS'),
    value: number(referrals.value.other_or_unknown_event_count),
  },
  {
    key: 'ctwa',
    label: t('REPORTS.LEADS.CTWA_IDS'),
    value: number(referrals.value.unique_ctwa_click_id_count),
  },
]);
const submissionMetrics = computed(() => [
  {
    key: 'events',
    label: t('REPORTS.LEADS.SUBMISSION_EVENTS'),
    value: number(submissions.value.event_count),
  },
  {
    key: 'contacts',
    label: t('REPORTS.LEADS.UNIQUE_SUBMISSION_CONTACTS'),
    value: number(submissions.value.unique_contact_count),
  },
  {
    key: 'unlinked',
    label: t('REPORTS.LEADS.UNLINKED_SUBMISSIONS'),
    value: number(submissions.value.events_without_contact_count),
  },
]);

const loadReport = async (range = {}) => {
  isLoading.value = true;
  hasError.value = false;

  try {
    const response = await ReportsAPI.getLeads(range);
    report.value = response.data?.payload || {};
    const meta = response.data?.meta || {};
    fromDate.value = meta.from_date || range.fromDate || '';
    toDate.value = meta.to_date || range.toDate || '';
    timezone.value = meta.timezone || timezone.value;
    maxRangeDays.value = meta.max_range_days || maxRangeDays.value;
  } catch {
    report.value = {};
    hasError.value = true;
    useAlert(t('REPORTS.LEADS.ERROR'));
  } finally {
    isLoading.value = false;
  }
};

const applyRange = range => loadReport(range);

onMounted(() => loadReport());
</script>

<template>
  <ReportHeader
    :header-title="t('REPORTS.LEADS.TITLE')"
    :header-description="t('REPORTS.LEADS.DESCRIPTION')"
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
      <p class="m-0 text-sm text-n-slate-11">{{ t('REPORTS.LEADS.ERROR') }}</p>
      <Button
        size="sm"
        :label="t('REPORTS.DATE_RANGE.APPLY')"
        @click="loadReport({ fromDate, toDate })"
      />
    </div>

    <p class="m-0 text-xs text-n-slate-10">
      {{ t('REPORTS.LEADS.EVENTS_NOTE') }}
    </p>

    <section class="rounded-xl border border-n-weak bg-n-surface-1 p-4">
      <h2 class="mb-3 mt-0 text-sm font-semibold text-n-slate-12">
        {{ t('REPORTS.LEADS.REFERRALS_TITLE') }}
      </h2>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
        <div
          v-for="metric in referralMetrics"
          :key="metric.key"
          class="rounded-lg border border-n-weak p-3"
        >
          <ReportMetricCard
            :label="metric.label"
            :value="metric.value"
            :info-text="t('REPORTS.LEADS.EVENTS_NOTE')"
            :disabled="isLoading"
          />
        </div>
      </div>
    </section>

    <section
      class="overflow-hidden rounded-xl border border-n-weak bg-n-surface-1"
    >
      <div class="border-b border-n-weak px-4 py-3">
        <h2 class="m-0 text-sm font-semibold text-n-slate-12">
          {{ t('REPORTS.LEADS.ATTRIBUTION_BREAKDOWN') }}
        </h2>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[42rem] text-left text-sm">
          <thead class="bg-n-surface-2 text-xs text-n-slate-10">
            <tr>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.LEADS.PROVIDER') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.LEADS.ATTRIBUTION') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.LEADS.SOURCE_TYPE') }}
              </th>
              <th class="px-4 py-2 font-medium">
                {{ t('REPORTS.LEADS.REFERRAL_TYPE') }}
              </th>
              <th class="px-4 py-2 text-right font-medium">
                {{ t('REPORTS.LEADS.EVENT_COUNT') }}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-n-weak">
            <tr
              v-for="(row, index) in referralRows"
              :key="`${row.provider}-${row.attribution_type}-${row.source_type}-${index}`"
              class="text-n-slate-11"
            >
              <td class="px-4 py-2.5">{{ row.provider }}</td>
              <td class="px-4 py-2.5">
                {{
                  localizedValue(
                    'REPORTS.LEADS.ATTRIBUTIONS',
                    row.attribution_type
                  )
                }}
              </td>
              <td class="px-4 py-2.5">{{ row.source_type }}</td>
              <td class="px-4 py-2.5">{{ row.referral_type }}</td>
              <td class="px-4 py-2.5 text-right">
                {{ number(row.event_count) }}
              </td>
            </tr>
            <tr v-if="!isLoading && !hasError && referralRows.length === 0">
              <td colspan="5" class="px-4 py-8 text-center text-n-slate-10">
                {{ t('REPORTS.LEADS.EMPTY') }}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p
        v-if="referrals.attribution_breakdown_omitted_event_count"
        class="m-0 border-t border-n-weak px-4 py-2 text-xs text-n-slate-10"
      >
        {{
          t('REPORTS.LEADS.OMITTED_ATTRIBUTION', {
            count: number(referrals.attribution_breakdown_omitted_event_count),
          })
        }}
      </p>
    </section>

    <section class="rounded-xl border border-n-weak bg-n-surface-1 p-4">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
        <h2 class="m-0 text-sm font-semibold text-n-slate-12">
          {{ t('REPORTS.LEADS.FORM_SUBMISSIONS_TITLE') }}
        </h2>
        <span class="text-xs text-n-slate-10">
          {{ t('REPORTS.LEADS.PROCESSED_IN_PERIOD') }}:
          {{ number(processing.submissions_processed_in_selected_period) }}
          <span
            v-if="
              processing.average_processing_seconds !== null &&
              processing.average_processing_seconds !== undefined
            "
          >
            · {{ seconds(processing.average_processing_seconds) }}
            {{ t('REPORTS.LEADS.AVERAGE_PROCESSING').toLowerCase() }}
          </span>
        </span>
      </div>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div
          v-for="metric in submissionMetrics"
          :key="metric.key"
          class="rounded-lg border border-n-weak p-3"
        >
          <ReportMetricCard
            :label="metric.label"
            :value="metric.value"
            :info-text="t('REPORTS.LEADS.EVENTS_NOTE')"
            :disabled="isLoading"
          />
        </div>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 xl:grid-cols-2">
        <div>
          <h3 class="mb-2 mt-0 text-xs font-semibold text-n-slate-11">
            {{ t('REPORTS.LEADS.SOURCE_STATUS') }}
          </h3>
          <ul
            class="m-0 divide-y divide-n-weak rounded-lg border border-n-weak p-0"
          >
            <li
              v-for="row in sourceStatusRows"
              :key="`${row.source_kind}-${row.status}`"
              class="flex items-center justify-between gap-3 px-3 py-2 text-sm"
            >
              <span class="text-n-slate-11">
                {{
                  localizedValue('REPORTS.LEADS.SOURCE_KINDS', row.source_kind)
                }}
                ·
                {{ localizedValue('REPORTS.LEADS.STATUSES', row.status) }}
              </span>
              <span class="font-medium text-n-slate-12">
                {{ number(row.event_count) }}
              </span>
            </li>
            <li
              v-if="!isLoading && !hasError && sourceStatusRows.length === 0"
              class="px-3 py-4 text-center text-sm text-n-slate-10"
            >
              {{ t('REPORTS.LEADS.EMPTY') }}
            </li>
          </ul>
        </div>
        <div>
          <h3 class="mb-2 mt-0 text-xs font-semibold text-n-slate-11">
            {{ t('REPORTS.LEADS.FORMS') }}
          </h3>
          <ul
            class="m-0 divide-y divide-n-weak rounded-lg border border-n-weak p-0"
          >
            <li
              v-for="row in formRows"
              :key="`${row.lead_form_id}-${row.source_kind}`"
              class="flex items-center justify-between gap-3 px-3 py-2 text-sm"
            >
              <span class="min-w-0 truncate text-n-slate-11">
                {{ row.lead_form_name }}
                ·
                {{
                  localizedValue('REPORTS.LEADS.SOURCE_KINDS', row.source_kind)
                }}
              </span>
              <span class="shrink-0 font-medium text-n-slate-12">
                {{ number(row.event_count) }}
              </span>
            </li>
            <li
              v-if="!isLoading && !hasError && formRows.length === 0"
              class="px-3 py-4 text-center text-sm text-n-slate-10"
            >
              {{ t('REPORTS.LEADS.EMPTY') }}
            </li>
          </ul>
          <p
            v-if="submissions.form_breakdown_omitted_event_count"
            class="mb-0 mt-2 text-xs text-n-slate-10"
          >
            {{
              t('REPORTS.LEADS.OMITTED_BREAKDOWN', {
                count: number(submissions.form_breakdown_omitted_event_count),
              })
            }}
          </p>
        </div>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-2">
        <div>
          <h3 class="mb-2 mt-0 text-xs font-semibold text-n-slate-11">
            {{ t('REPORTS.LEADS.UTM_SOURCES') }}
          </h3>
          <ul
            class="m-0 divide-y divide-n-weak rounded-lg border border-n-weak p-0"
          >
            <li
              v-for="row in sourceRows"
              :key="row.value"
              class="flex justify-between gap-3 px-3 py-2 text-sm"
            >
              <span class="truncate text-n-slate-11">{{ row.value }}</span>
              <span class="font-medium text-n-slate-12">
                {{ number(row.event_count) }}
              </span>
            </li>
            <li
              v-if="!isLoading && !hasError && sourceRows.length === 0"
              class="px-3 py-4 text-center text-sm text-n-slate-10"
            >
              {{ t('REPORTS.LEADS.EMPTY') }}
            </li>
          </ul>
          <p
            v-if="submissions.utm_source_breakdown_omitted_event_count"
            class="mb-0 mt-2 text-xs text-n-slate-10"
          >
            {{
              t('REPORTS.LEADS.OMITTED_BREAKDOWN', {
                count: number(
                  submissions.utm_source_breakdown_omitted_event_count
                ),
              })
            }}
          </p>
        </div>
        <div>
          <h3 class="mb-2 mt-0 text-xs font-semibold text-n-slate-11">
            {{ t('REPORTS.LEADS.UTM_CAMPAIGNS') }}
          </h3>
          <ul
            class="m-0 divide-y divide-n-weak rounded-lg border border-n-weak p-0"
          >
            <li
              v-for="row in campaignRows"
              :key="row.value"
              class="flex justify-between gap-3 px-3 py-2 text-sm"
            >
              <span class="truncate text-n-slate-11">{{ row.value }}</span>
              <span class="font-medium text-n-slate-12">
                {{ number(row.event_count) }}
              </span>
            </li>
            <li
              v-if="!isLoading && !hasError && campaignRows.length === 0"
              class="px-3 py-4 text-center text-sm text-n-slate-10"
            >
              {{ t('REPORTS.LEADS.EMPTY') }}
            </li>
          </ul>
          <p
            v-if="submissions.utm_campaign_breakdown_omitted_event_count"
            class="mb-0 mt-2 text-xs text-n-slate-10"
          >
            {{
              t('REPORTS.LEADS.OMITTED_BREAKDOWN', {
                count: number(
                  submissions.utm_campaign_breakdown_omitted_event_count
                ),
              })
            }}
          </p>
        </div>
      </div>
    </section>
  </div>
</template>
