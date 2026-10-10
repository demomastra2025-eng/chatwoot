<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import ReportMetricCard from './ReportMetricCard.vue';

const props = defineProps({
  report: { type: Object, default: () => ({}) },
  loading: { type: Boolean, default: false },
});
const { t, locale } = useI18n();
const number = value =>
  new Intl.NumberFormat(locale.value).format(Number(value || 0));
const percent = value =>
  new Intl.NumberFormat(locale.value, {
    style: 'percent',
    maximumFractionDigits: 1,
  }).format(Number(value || 0) / 100);
const metrics = computed(() => [
  {
    key: 'leads',
    label: t('CRM.LEAD_CONVERSION.LEADS'),
    value: number(props.report.leads_count),
  },
  {
    key: 'booked',
    label: t('CRM.LEAD_CONVERSION.BOOKED_LEADS'),
    value: number(props.report.booked_leads_count),
  },
  {
    key: 'attended',
    label: t('CRM.LEAD_CONVERSION.ATTENDED_LEADS'),
    value: number(props.report.attended_leads_count),
  },
  {
    key: 'booking_conversion',
    label: t('CRM.LEAD_CONVERSION.BOOKING_CONVERSION'),
    value: percent(props.report.booking_conversion_percent),
  },
  {
    key: 'attendance_conversion',
    label: t('CRM.LEAD_CONVERSION.ATTENDANCE_CONVERSION'),
    value: percent(props.report.attendance_conversion_percent),
  },
]);
const counts = computed(() => [
  {
    key: 'appointments',
    label: t('CRM.LEAD_CONVERSION.APPOINTMENTS'),
    value: props.report.appointments_count,
  },
  {
    key: 'provider_booked',
    label: t('CRM.LEAD_CONVERSION.PROVIDER_BOOKED_APPOINTMENTS'),
    value: props.report.provider_booked_appointments_count,
  },
  {
    key: 'attended',
    label: t('CRM.LEAD_CONVERSION.ATTENDED_APPOINTMENTS'),
    value: props.report.attended_appointments_count,
  },
  {
    key: 'cancelled',
    label: t('CRM.LEAD_CONVERSION.CANCELLED'),
    value: props.report.cancelled_or_no_show_appointments_count,
  },
  {
    key: 'repeats',
    label: t('CRM.LEAD_CONVERSION.REPEATS'),
    value: props.report.repeat_contacts_count,
  },
  {
    key: 'deals',
    label: t('CRM.LEAD_CONVERSION.DEALS'),
    value: props.report.deals_count,
  },
  {
    key: 'won_deals',
    label: t('CRM.LEAD_CONVERSION.WON_DEALS'),
    value: props.report.won_deals_count,
  },
]);
const rows = computed(() => props.report.attribution_breakdown || []);
</script>

<template>
  <section
    class="rounded-xl border border-n-weak bg-n-surface-1 p-4"
    data-testid="lead-appointment-conversion"
  >
    <h2 class="mb-2 mt-0 text-sm font-semibold text-n-slate-12">
      {{ $t('CRM.LEAD_CONVERSION.TITLE') }}
    </h2>
    <p class="mb-4 mt-0 text-xs leading-5 text-n-slate-10">
      {{ $t('CRM.LEAD_CONVERSION.COHORT_HELP') }}
    </p>
    <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
      <div
        v-for="metric in metrics"
        :key="metric.key"
        class="rounded-lg border border-n-weak p-3"
      >
        <ReportMetricCard
          :label="metric.label"
          :value="metric.value"
          :info-text="$t('CRM.LEAD_CONVERSION.COHORT_HELP')"
          :disabled="loading"
        />
      </div>
    </div>
    <dl class="mb-0 mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
      <div
        v-for="count in counts"
        :key="count.key"
        class="flex items-center justify-between gap-3 text-xs"
      >
        <dt class="text-n-slate-11">{{ count.label }}</dt>
        <dd class="m-0 font-semibold text-n-slate-12">
          {{ number(count.value) }}
        </dd>
      </div>
    </dl>
    <p class="mb-0 mt-4 text-xs leading-5 text-n-slate-10">
      {{ $t('CRM.LEAD_CONVERSION.OUTCOMES_HELP') }}
    </p>
    <p
      v-if="report.unknown_attendance_appointments_count"
      class="mb-0 mt-2 text-xs text-n-slate-11"
    >
      {{
        $t('CRM.LEAD_CONVERSION.UNKNOWN_ATTENDANCE', {
          count: number(report.unknown_attendance_appointments_count),
        })
      }}
    </p>
    <p
      v-if="report.appointments_without_contact_count"
      class="mb-0 mt-2 text-xs text-n-slate-11"
    >
      {{
        $t('CRM.LEAD_CONVERSION.UNLINKED', {
          count: number(report.appointments_without_contact_count),
        })
      }}
    </p>
    <p
      v-if="report.scheduling_enabled === false"
      class="mb-0 mt-2 text-xs text-n-slate-11"
    >
      {{ $t('CRM.LEAD_CONVERSION.SCHEDULING_OFF') }}
    </p>
    <div v-if="rows.length" class="mt-4 overflow-x-auto">
      <table class="w-full text-left text-xs">
        <thead class="border-b border-n-weak text-n-slate-10">
          <tr>
            <th class="p-2 font-medium">
              {{ $t('CRM.LEAD_CONVERSION.ORIGIN') }}
            </th>
            <th class="p-2 font-medium">
              {{ $t('CRM.LEAD_CONVERSION.SOURCE') }}
            </th>
            <th class="p-2 text-right font-medium">
              {{ $t('CRM.LEAD_CONVERSION.LEADS') }}
            </th>
            <th class="p-2 text-right font-medium">
              {{ $t('CRM.LEAD_CONVERSION.BOOKED_LEADS') }}
            </th>
            <th class="p-2 text-right font-medium">
              {{ $t('CRM.LEAD_CONVERSION.ATTENDED_LEADS') }}
            </th>
            <th class="p-2 text-right font-medium">
              {{ $t('CRM.LEAD_CONVERSION.APPOINTMENTS') }}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak text-n-slate-11">
          <tr
            v-for="(row, index) in rows"
            :key="`${row.inbox_id}-${row.source}-${index}`"
          >
            <td class="p-2">{{ row.inbox_name }}</td>
            <td class="p-2">
              {{
                row.source === 'unknown'
                  ? $t('CRM.LEAD_CONVERSION.UNKNOWN_SOURCE')
                  : row.source
              }}
            </td>
            <td class="p-2 text-right">{{ number(row.leads_count) }}</td>
            <td class="p-2 text-right">{{ number(row.booked_leads_count) }}</td>
            <td class="p-2 text-right">
              {{ number(row.attended_leads_count) }}
            </td>
            <td class="p-2 text-right">{{ number(row.appointments_count) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>
