<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import ReportMetricCard from './ReportMetricCard.vue';

const props = defineProps({
  report: { type: Object, required: true },
  loading: { type: Boolean, default: false },
});

const { t, locale } = useI18n();
const number = value =>
  new Intl.NumberFormat(locale.value).format(Number(value || 0));
const kzt = value =>
  `${new Intl.NumberFormat(locale.value).format(Number(value || 0))} ₸`;
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
  {
    key: 'net_attendance_rate',
    label: t('CRM.LEAD_CONVERSION.NET_ATTENDANCE_RATE'),
    value: percent(
      props.report.schedule_breakdown?.net_attendance_rate_percent ??
        props.report.net_attendance_rate_percent
    ),
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
    key: 'rescheduled',
    label: t('CRM.LEAD_CONVERSION.RESCHEDULED_APPOINTMENTS'),
    value: props.report.rescheduled_appointments_count,
  },
  {
    key: 'early_cancelled',
    label: t('CRM.LEAD_CONVERSION.EARLY_CANCELLED_APPOINTMENTS'),
    value: props.report.early_cancelled_appointments_count,
  },
  {
    key: 'true_no_show',
    label: t('CRM.LEAD_CONVERSION.TRUE_NO_SHOW_APPOINTMENTS'),
    value: props.report.true_no_show_appointments_count,
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

const allFunnel = computed(() => props.report.all_contacts_funnel || null);
const scheduleBreakdown = computed(
  () => props.report.schedule_breakdown || null
);
const whatsappTouches = computed(() => props.report.whatsapp_touches || null);
const rows = computed(() => props.report.attribution_breakdown || []);
</script>

<template>
  <section
    class="min-w-0 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 outline-n-container"
    data-testid="lead-appointment-conversion"
  >
    <h2 class="mb-2 mt-0 text-heading-2 text-n-slate-12">
      {{ $t('CRM.LEAD_CONVERSION.TITLE') }}
    </h2>
    <p class="mb-4 mt-0 text-xs leading-5 text-n-slate-10">
      {{ $t('CRM.LEAD_CONVERSION.COHORT_HELP') }}
    </p>
    <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 xl:grid-cols-3">
      <ReportMetricCard
        v-for="metric in metrics"
        :key="metric.key"
        :label="metric.label"
        :value="metric.value"
        :info-text="$t('CRM.LEAD_CONVERSION.COHORT_HELP')"
        :disabled="loading"
      />
    </div>
    <dl
      class="mb-0 mt-5 grid gap-2 border-t border-n-weak pt-4 sm:grid-cols-2 xl:grid-cols-3"
    >
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

    <div
      v-if="allFunnel || scheduleBreakdown || whatsappTouches"
      class="mt-5 grid grid-cols-1 gap-4 border-t border-n-weak pt-4 lg:grid-cols-3"
    >
      <div
        v-if="allFunnel"
        class="rounded-lg bg-n-solid-1 p-4 outline outline-1 outline-n-weak"
        data-testid="all-contacts-funnel"
      >
        <h3 class="m-0 mb-2 text-xs font-semibold uppercase tracking-wider text-n-slate-10">
          {{ $t('CRM.LEAD_CONVERSION.ALL_FUNNEL_TITLE') }}
        </h3>
        <dl class="m-0 flex flex-col gap-1.5 text-xs">
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.ALL_CONTACTS') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">{{ number(allFunnel.contacts_count) }}</dd>
          </div>
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.ALL_BOOKED') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">
              {{ number(allFunnel.booked_contacts_count) }} ({{ percent(allFunnel.booking_conversion_percent) }})
            </dd>
          </div>
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.ALL_ATTENDED') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">
              {{ number(allFunnel.attended_contacts_count) }} ({{ percent(allFunnel.attendance_conversion_percent) }})
            </dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-n-weak pt-1.5">
            <dt class="text-n-slate-10">{{ $t('CRM.LEAD_CONVERSION.PRIMARY_VS_REPEAT') }}</dt>
            <dd class="m-0 text-n-slate-11">
              {{ number(allFunnel.primary_contacts_count) }} / {{ number(allFunnel.repeat_contacts_count) }}
            </dd>
          </div>
        </dl>
      </div>

      <div
        v-if="scheduleBreakdown"
        class="rounded-lg bg-n-solid-1 p-4 outline outline-1 outline-n-weak"
        data-testid="schedule-finance-breakdown"
      >
        <h3 class="m-0 mb-2 text-xs font-semibold uppercase tracking-wider text-n-slate-10">
          {{ $t('CRM.LEAD_CONVERSION.FINANCE_TITLE') }}
        </h3>
        <dl class="m-0 flex flex-col gap-1.5 text-xs">
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.COMPLETED_REVENUE') }}</dt>
            <dd class="m-0 font-semibold text-n-teal-11">{{ kzt(scheduleBreakdown.completed_revenue_kzt) }}</dd>
          </div>
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.RESCHEDULED_REVENUE') }}</dt>
            <dd class="m-0 font-semibold text-n-blue-11">{{ kzt(scheduleBreakdown.rescheduled_saved_revenue_kzt) }}</dd>
          </div>
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.LOST_NO_SHOW_REVENUE') }}</dt>
            <dd class="m-0 font-semibold text-n-ruby-11">{{ kzt(scheduleBreakdown.true_no_show_lost_revenue_kzt) }}</dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-n-weak pt-1.5">
            <dt class="text-n-slate-10">{{ $t('CRM.LEAD_CONVERSION.NET_ATTENDANCE_RATE') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">{{ percent(scheduleBreakdown.net_attendance_rate_percent) }}</dd>
          </div>
        </dl>
      </div>

      <div
        v-if="whatsappTouches"
        class="rounded-lg bg-n-solid-1 p-4 outline outline-1 outline-n-weak"
        data-testid="whatsapp-touches-summary"
      >
        <h3 class="m-0 mb-2 text-xs font-semibold uppercase tracking-wider text-n-slate-10">
          {{ $t('CRM.LEAD_CONVERSION.TOUCHES_TITLE') }}
        </h3>
        <dl class="m-0 flex flex-col gap-1.5 text-xs">
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.REMINDER_1D') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">
              {{ number(whatsappTouches.reminder_1d_sent_count) }} ({{ percent(whatsappTouches.reminder_1d_confirmation_rate_percent) }})
            </dd>
          </div>
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.REMINDER_2H') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">{{ number(whatsappTouches.reminder_2h_sent_count) }}</dd>
          </div>
          <div class="flex items-center justify-between gap-2">
            <dt class="text-n-slate-11">{{ $t('CRM.LEAD_CONVERSION.REVIEW_REQUEST') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">{{ number(whatsappTouches.review_request_sent_count) }}</dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-n-weak pt-1.5">
            <dt class="text-n-slate-10">{{ $t('CRM.LEAD_CONVERSION.TOUCHES_TOTAL') }}</dt>
            <dd class="m-0 font-semibold text-n-slate-12">{{ number(whatsappTouches.total_sent_count) }}</dd>
          </div>
        </dl>
      </div>
    </div>

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
