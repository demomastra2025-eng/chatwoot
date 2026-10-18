<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';

import ReportsAPI from 'dashboard/api/standaloneReports';
import Button from 'dashboard/components-next/button/Button.vue';
import { useAlert } from 'dashboard/composables';
import {
  downloadCsvFile,
  downloadExcelFile,
  generateFileName,
} from 'dashboard/helper/downloadHelper';
import ReportHeader from './components/ReportHeader.vue';
import ReportMetricCard from './components/ReportMetricCard.vue';
import ReportDateRange from './components/ReportDateRange.vue';
import LeadAppointmentConversionReport from './components/LeadAppointmentConversionReport.vue';

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

const referrals = computed(() => report.value.referrals || {});
const metaAdsSummary = computed(() => referrals.value.meta_ads_summary || {});
const creativesRows = computed(() => referrals.value.creatives_breakdown || []);
const referralConversations = computed(
  () => referrals.value.referral_conversations || []
);
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

const localeCode = computed(() => {
  const raw = String(locale.value || 'ru').replace('_', '-');
  try {
    return Intl.getCanonicalLocales(raw)[0] || 'ru-RU';
  } catch {
    return 'ru-RU';
  }
});

const numberFormatter = computed(() => new Intl.NumberFormat(localeCode.value));
const number = value => numberFormatter.value.format(Number(value || 0));

const dateTimeFormatter = computed(
  () =>
    new Intl.DateTimeFormat(localeCode.value, {
      dateStyle: 'short',
      timeStyle: 'short',
      timeZone: timezone.value || 'Asia/Almaty',
    })
);

const formatDateTime = value => {
  if (!value) return '—';
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime())
    ? String(value)
    : dateTimeFormatter.value.format(parsed);
};

const seconds = value => {
  if (value === null || value === undefined) return '—';
  const num = Number(value);
  if (!Number.isFinite(num)) return '—';
  if (num >= 60) {
    const mins = Math.floor(num / 60);
    const rem = Math.round(num % 60);
    const minText = new Intl.NumberFormat(localeCode.value, {
      style: 'unit',
      unit: 'minute',
      unitDisplay: 'short',
    }).format(mins);
    if (rem === 0) return minText;
    const secText = new Intl.NumberFormat(localeCode.value, {
      style: 'unit',
      unit: 'second',
      unitDisplay: 'short',
    }).format(rem);
    return `${minText} ${secText}`;
  }
  return new Intl.NumberFormat(localeCode.value, {
    maximumFractionDigits: 1,
    style: 'unit',
    unit: 'second',
    unitDisplay: 'short',
  }).format(num);
};

const localizedValue = (namespace, value) => {
  const normalized = String(value || 'unknown').trim();
  const key = `${namespace}.${normalized}`;
  if (te(key)) return t(key);
  if (normalized.toLowerCase() === 'unknown') return t('REPORTS.LEADS.UNKNOWN');
  return normalized || t('REPORTS.LEADS.UNKNOWN');
};

const formatMediaType = value => {
  const key = `REPORTS.LEADS.META_ADS.MEDIA_TYPES.${String(value || '').toLowerCase()}`;
  return te(key) ? t(key) : value || '—';
};

const formatConversationStatus = status => {
  const key = `REPORTS.LEADS.META_ADS.CHAT_STATUSES.${String(status || '').toLowerCase()}`;
  return te(key) ? t(key) : status || '—';
};

const conversationUrl = row => {
  const chatId = row?.display_id || row?.conversation_id;
  if (!chatId || !accountId.value) return '';
  return `/app/accounts/${accountId.value}/conversations/${chatId}`;
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
    key: 'chats',
    label: t('REPORTS.LEADS.META_ADS.UNIQUE_CHATS'),
    value: number(metaAdsSummary.value.chats_count),
  },
  {
    key: 'ads',
    label: t('REPORTS.LEADS.EXPLICIT_AD_EVENTS'),
    value: number(referrals.value.explicit_paid_ad_event_count),
  },
  {
    key: 'ad_ids',
    label: t('REPORTS.LEADS.META_ADS.UNIQUE_AD_IDS'),
    value: number(metaAdsSummary.value.ad_ids_count),
  },
  {
    key: 'answered',
    label: t('REPORTS.LEADS.META_ADS.ANSWERED_CHATS'),
    value: `${number(metaAdsSummary.value.answered_chats_count)} / ${number(metaAdsSummary.value.chats_count)}`,
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

const exportHeaders = computed(() => [
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.FIRST_AT'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.LAST_AT'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.CONTACT'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.PHONE'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.AD_ID'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.CREATIVE'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.FORMAT'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.SOURCE_URLS'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.EVENTS'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.INCOMING'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.OUTGOING'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.ANSWERED'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.RESPONSE_MINUTES'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.STATUS'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.CHAT_ID'),
  t('REPORTS.LEADS.META_ADS.EXPORT_COLUMNS.CHAT_URL'),
]);

const exportRows = computed(() =>
  referralConversations.value.map(row => [
    formatDateTime(row.first_at),
    formatDateTime(row.last_at),
    row.contact_name || '—',
    row.phone || '',
    (row.ad_ids || []).join(' | '),
    (row.headlines || []).join(' | '),
    (row.media_types || []).map(formatMediaType).join(' | '),
    (row.source_urls || []).join(' | '),
    Number(row.event_count || 0),
    Number(row.incoming_count || 0),
    Number(row.outgoing_count || 0),
    row.answered
      ? t('REPORTS.LEADS.META_ADS.YES')
      : t('REPORTS.LEADS.META_ADS.NO'),
    row.response_minutes ?? '',
    formatConversationStatus(row.status),
    row.display_id || row.conversation_id || '',
    conversationUrl(row)
      ? `${window.location.origin}${conversationUrl(row)}`
      : '',
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

const downloadMetaAdsCsv = () => {
  if (!referralConversations.value.length) return;
  const lines = [exportHeaders.value, ...exportRows.value].map(line =>
    line.map(csvCell).join(',')
  );
  const fileName = generateFileName({
    type: 'meta-ads-leads',
    to: Math.floor(Date.now() / 1000),
    extension: 'csv',
  });
  downloadCsvFile(fileName, `\uFEFF${lines.join('\n')}`);
};

const downloadMetaAdsExcel = () => {
  if (!referralConversations.value.length) return;
  const headerHtml = `<tr>${exportHeaders.value.map(h => htmlCell(h, 'th')).join('')}</tr>`;
  const bodyHtml = exportRows.value
    .map(r => `<tr>${r.map(c => htmlCell(c, 'td')).join('')}</tr>`)
    .join('');
  const content = `<!doctype html><html><head><meta charset="utf-8" /></head><body><table border="1">${headerHtml}${bodyHtml}</table></body></html>`;
  const fileName = generateFileName({
    type: 'meta-ads-leads',
    to: Math.floor(Date.now() / 1000),
    extension: 'xls',
  });
  downloadExcelFile(fileName, `\uFEFF${content}`);
};

const loadReport = async (range = {}) => {
  generation += 1;
  const request = generation;
  const account = accountId.value;
  isLoading.value = true;
  hasError.value = false;

  try {
    const response = await ReportsAPI.getLeads(range);
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
    useAlert(t('REPORTS.LEADS.ERROR'));
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
      class="flex items-center justify-between gap-3 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
      role="alert"
    >
      <p class="m-0 text-sm text-n-slate-11">{{ t('REPORTS.LEADS.ERROR') }}</p>
      <Button
        size="sm"
        :label="t('REPORTS.DATE_RANGE.APPLY')"
        @click="loadReport({ fromDate, toDate })"
      />
    </div>

    <LeadAppointmentConversionReport
      v-if="report.appointment_conversion"
      :report="report.appointment_conversion"
      :loading="isLoading"
    />

    <p class="m-0 text-xs text-n-slate-10">
      {{ t('REPORTS.LEADS.EVENTS_NOTE') }}
    </p>

    <section
      class="rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
    >
      <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h2 class="m-0 text-heading-2 text-n-slate-12">
          {{ t('REPORTS.LEADS.REFERRALS_TITLE') }}
        </h2>
        <div class="flex flex-wrap items-center gap-2">
          <Button
            size="sm"
            variant="faded"
            color="slate"
            icon="i-lucide-file-spreadsheet"
            :label="t('REPORTS.LEADS.META_ADS.EXPORT_EXCEL')"
            :disabled="isLoading || !referralConversations.length"
            @click="downloadMetaAdsExcel"
          />
          <Button
            size="sm"
            variant="faded"
            color="slate"
            icon="i-lucide-download"
            :label="t('REPORTS.LEADS.META_ADS.EXPORT_CSV')"
            :disabled="isLoading || !referralConversations.length"
            @click="downloadMetaAdsCsv"
          />
        </div>
      </div>
      <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 xl:grid-cols-3">
        <ReportMetricCard
          v-for="metric in referralMetrics"
          :key="metric.key"
          :label="metric.label"
          :value="metric.value"
          :info-text="t('REPORTS.LEADS.EVENTS_NOTE')"
          :disabled="isLoading"
        />
      </div>
    </section>

    <section
      class="min-w-0 overflow-hidden rounded-xl bg-n-solid-2 p-0 shadow outline outline-1 outline-n-container"
    >
      <div class="border-b border-n-weak px-5 py-4">
        <h2 class="m-0 text-heading-2 text-n-slate-12">
          {{ t('REPORTS.LEADS.META_ADS.CREATIVES_TITLE') }}
        </h2>
        <p class="mb-0 mt-1 text-xs text-n-slate-10">
          {{ t('REPORTS.LEADS.META_ADS.CREATIVES_DESC') }}
        </p>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[46rem] text-left text-sm">
          <thead class="bg-n-surface-2 text-xs text-n-slate-10">
            <tr>
              <th class="px-5 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.META_ADS.CREATIVE') }}
              </th>
              <th class="px-4 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.META_ADS.FORMAT') }}
              </th>
              <th class="px-4 py-2.5 text-right font-medium">
                {{ t('REPORTS.LEADS.META_ADS.CHATS') }}
              </th>
              <th class="px-4 py-2.5 text-right font-medium">
                {{ t('REPORTS.LEADS.EVENT_COUNT') }}
              </th>
              <th class="px-5 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.META_ADS.SOURCES') }}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-n-weak">
            <tr
              v-for="creative in creativesRows"
              :key="creative.ad_id"
              class="text-n-slate-11"
            >
              <td class="px-5 py-2.5">
                <div class="flex flex-col gap-0.5">
                  <span class="font-medium text-n-slate-12">
                    {{ (creative.headlines || []).join(' / ') || '—' }}
                  </span>
                  <span
                    v-if="creative.ad_id && creative.ad_id !== 'unknown'"
                    class="text-xs tabular-nums text-n-slate-10"
                  >
                    Ad ID: {{ creative.ad_id }}
                  </span>
                </div>
              </td>
              <td class="px-4 py-2.5">
                {{
                  (creative.media_types || [])
                    .map(formatMediaType)
                    .join(' / ') || '—'
                }}
              </td>
              <td class="px-4 py-2.5 text-right font-medium text-n-slate-12 tabular-nums">
                {{ number(creative.chats_count) }}
              </td>
              <td class="px-4 py-2.5 text-right tabular-nums">
                {{ number(creative.event_count) }}
              </td>
              <td class="px-5 py-2.5">
                <div
                  v-if="creative.source_urls && creative.source_urls.length"
                  class="flex flex-wrap gap-2"
                >
                  <a
                    v-for="(url, idx) in creative.source_urls"
                    :key="url"
                    :href="url"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="text-xs font-medium text-n-brand hover:underline"
                  >
                    {{ t('REPORTS.LEADS.META_ADS.SOURCE_LINK', { n: idx + 1 }) }}
                  </a>
                </div>
                <span v-else class="text-n-slate-10">—</span>
              </td>
            </tr>
            <tr v-if="!isLoading && !hasError && creativesRows.length === 0">
              <td colspan="5" class="px-5 py-8 text-center text-n-slate-10">
                {{ t('REPORTS.LEADS.EMPTY') }}
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
          {{ t('REPORTS.LEADS.META_ADS.CONVERSATIONS_TITLE') }}
        </h2>
        <p class="mb-0 mt-1 text-xs text-n-slate-10">
          {{ t('REPORTS.LEADS.META_ADS.CONVERSATIONS_DESC') }}
        </p>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[60rem] text-left text-sm">
          <thead class="bg-n-surface-2 text-xs text-n-slate-10">
            <tr>
              <th class="px-5 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.META_ADS.FIRST_CONTACT') }}
              </th>
              <th class="px-4 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.META_ADS.CONTACT') }}
              </th>
              <th class="px-4 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.META_ADS.CREATIVE') }}
              </th>
              <th class="px-4 py-2.5 text-right font-medium">
                {{ t('REPORTS.LEADS.EVENT_COUNT') }}
              </th>
              <th class="px-4 py-2.5 text-right font-medium">
                {{ t('REPORTS.LEADS.META_ADS.IN_OUT_MESSAGES') }}
              </th>
              <th class="px-4 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.META_ADS.ANSWERED') }}
              </th>
              <th class="px-4 py-2.5 font-medium">
                {{ t('REPORTS.LEADS.STATUS') }}
              </th>
              <th class="px-5 py-2.5 text-right font-medium">
                {{ t('REPORTS.LEADS.META_ADS.CONVERSATION') }}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-n-weak">
            <tr
              v-for="chat in referralConversations"
              :key="chat.conversation_id"
              class="text-n-slate-11"
            >
              <td class="whitespace-nowrap px-5 py-2.5 tabular-nums">
                {{ formatDateTime(chat.first_at) }}
              </td>
              <td class="px-4 py-2.5">
                <div class="flex flex-col gap-0.5">
                  <span class="font-medium text-n-slate-12">
                    {{ chat.contact_name || '—' }}
                  </span>
                  <span
                    v-if="chat.phone"
                    class="text-xs tabular-nums text-n-slate-10"
                  >
                    {{ chat.phone }}
                  </span>
                </div>
              </td>
              <td class="px-4 py-2.5">
                <div class="flex flex-col gap-0.5">
                  <span class="text-n-slate-12">
                    {{ (chat.headlines || []).join(' / ') || '—' }}
                  </span>
                  <span
                    v-if="chat.ad_ids && chat.ad_ids.length"
                    class="text-xs tabular-nums text-n-slate-10"
                  >
                    {{ chat.ad_ids.join(', ') }}
                  </span>
                </div>
              </td>
              <td class="px-4 py-2.5 text-right tabular-nums">
                {{ number(chat.event_count) }}
              </td>
              <td class="whitespace-nowrap px-4 py-2.5 text-right tabular-nums">
                {{ number(chat.incoming_count) }} /
                {{ number(chat.outgoing_count) }}
              </td>
              <td class="whitespace-nowrap px-4 py-2.5">
                <span
                  class="inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium"
                  :class="
                    chat.answered
                      ? 'bg-n-teal-3 text-n-teal-11'
                      : 'bg-n-amber-3 text-n-amber-11'
                  "
                >
                  {{
                    chat.answered
                      ? t('REPORTS.LEADS.META_ADS.YES')
                      : t('REPORTS.LEADS.META_ADS.NO')
                  }}
                </span>
                <span
                  v-if="
                    chat.response_minutes !== null &&
                    chat.response_minutes !== undefined
                  "
                  class="ml-1.5 text-xs tabular-nums text-n-slate-10"
                >
                  ({{ chat.response_minutes }}
                  {{ t('REPORT.DAILY_RESPONSE.UNIT_MIN') }})
                </span>
              </td>
              <td class="whitespace-nowrap px-4 py-2.5">
                {{ formatConversationStatus(chat.status) }}
              </td>
              <td class="whitespace-nowrap px-5 py-2.5 text-right">
                <router-link
                  v-if="conversationUrl(chat)"
                  :to="conversationUrl(chat)"
                  class="font-medium text-n-brand hover:underline"
                >
                  #{{ chat.display_id || chat.conversation_id }}
                </router-link>
                <span v-else>—</span>
              </td>
            </tr>
            <tr
              v-if="
                !isLoading && !hasError && referralConversations.length === 0
              "
            >
              <td colspan="8" class="px-5 py-8 text-center text-n-slate-10">
                {{ t('REPORTS.LEADS.EMPTY') }}
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
          {{ t('REPORTS.LEADS.ATTRIBUTION_BREAKDOWN') }}
        </h2>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[42rem] text-left text-sm">
          <thead class="bg-n-surface-2 text-xs text-n-slate-10">
            <tr>
              <th class="px-5 py-2 font-medium">
                {{ t('REPORTS.LEADS.PROVIDER') }}
              </th>
              <th class="px-5 py-2 font-medium">
                {{ t('REPORTS.LEADS.ATTRIBUTION') }}
              </th>
              <th class="px-5 py-2 font-medium">
                {{ t('REPORTS.LEADS.SOURCE_TYPE') }}
              </th>
              <th class="px-5 py-2 font-medium">
                {{ t('REPORTS.LEADS.REFERRAL_TYPE') }}
              </th>
              <th class="px-5 py-2 text-right font-medium">
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
              <td class="px-5 py-2.5">
                {{ localizedValue('REPORTS.LEADS.PROVIDERS', row.provider) }}
              </td>
              <td class="px-5 py-2.5">
                {{
                  localizedValue(
                    'REPORTS.LEADS.ATTRIBUTIONS',
                    row.attribution_type
                  )
                }}
              </td>
              <td class="px-5 py-2.5">
                {{
                  localizedValue('REPORTS.LEADS.SOURCE_TYPES', row.source_type)
                }}
              </td>
              <td class="px-5 py-2.5">
                {{
                  localizedValue(
                    'REPORTS.LEADS.REFERRAL_TYPES',
                    row.referral_type
                  )
                }}
              </td>
              <td class="px-5 py-2.5 text-right">
                {{ number(row.event_count) }}
              </td>
            </tr>
            <tr v-if="!isLoading && !hasError && referralRows.length === 0">
              <td colspan="5" class="px-5 py-8 text-center text-n-slate-10">
                {{ t('REPORTS.LEADS.EMPTY') }}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p
        v-if="referrals.attribution_breakdown_omitted_event_count"
        class="m-0 border-t border-n-weak px-5 py-2 text-xs text-n-slate-10"
      >
        {{
          t('REPORTS.LEADS.OMITTED_ATTRIBUTION', {
            count: number(referrals.attribution_breakdown_omitted_event_count),
          })
        }}
      </p>
    </section>

    <section
      class="rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
    >
      <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h2 class="m-0 text-heading-2 text-n-slate-12">
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
      <div class="grid grid-cols-1 gap-5 sm:grid-cols-3">
        <ReportMetricCard
          v-for="metric in submissionMetrics"
          :key="metric.key"
          :label="metric.label"
          :value="metric.value"
          :info-text="t('REPORTS.LEADS.EVENTS_NOTE')"
          :disabled="isLoading"
        />
      </div>

      <div
        class="mt-5 grid grid-cols-1 gap-5 border-t border-n-weak pt-5 xl:grid-cols-2"
      >
        <div>
          <h3 class="mb-2 mt-0 text-heading-3 text-n-slate-12">
            {{ t('REPORTS.LEADS.SOURCE_STATUS') }}
          </h3>
          <ul class="m-0 list-none divide-y divide-n-weak p-0">
            <li
              v-for="row in sourceStatusRows"
              :key="`${row.source_kind}-${row.status}`"
              class="flex items-center justify-between gap-3 py-2 text-sm"
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
              class="py-4 text-center text-sm text-n-slate-10"
            >
              {{ t('REPORTS.LEADS.EMPTY') }}
            </li>
          </ul>
        </div>
        <div>
          <h3 class="mb-2 mt-0 text-heading-3 text-n-slate-12">
            {{ t('REPORTS.LEADS.FORMS') }}
          </h3>
          <ul class="m-0 list-none divide-y divide-n-weak p-0">
            <li
              v-for="row in formRows"
              :key="`${row.lead_form_id}-${row.source_kind}`"
              class="flex items-center justify-between gap-3 py-2 text-sm"
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
              class="py-4 text-center text-sm text-n-slate-10"
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

      <div
        class="mt-5 grid grid-cols-1 gap-5 border-t border-n-weak pt-5 lg:grid-cols-2"
      >
        <div>
          <h3 class="mb-2 mt-0 text-heading-3 text-n-slate-12">
            {{ t('REPORTS.LEADS.UTM_SOURCES') }}
          </h3>
          <ul class="m-0 list-none divide-y divide-n-weak p-0">
            <li
              v-for="row in sourceRows"
              :key="row.value"
              class="flex justify-between gap-3 py-2 text-sm"
            >
              <span class="truncate text-n-slate-11">{{ row.value }}</span>
              <span class="font-medium text-n-slate-12">
                {{ number(row.event_count) }}
              </span>
            </li>
            <li
              v-if="!isLoading && !hasError && sourceRows.length === 0"
              class="py-4 text-center text-sm text-n-slate-10"
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
          <h3 class="mb-2 mt-0 text-heading-3 text-n-slate-12">
            {{ t('REPORTS.LEADS.UTM_CAMPAIGNS') }}
          </h3>
          <ul class="m-0 list-none divide-y divide-n-weak p-0">
            <li
              v-for="row in campaignRows"
              :key="row.value"
              class="flex justify-between gap-3 py-2 text-sm"
            >
              <span class="truncate text-n-slate-11">{{ row.value }}</span>
              <span class="font-medium text-n-slate-12">
                {{ number(row.event_count) }}
              </span>
            </li>
            <li
              v-if="!isLoading && !hasError && campaignRows.length === 0"
              class="py-4 text-center text-sm text-n-slate-10"
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
