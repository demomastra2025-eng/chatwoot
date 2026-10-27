<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';

const props = defineProps({ appointmentId: { type: Number, required: true } });
const { t, locale } = useI18n();
const items = ref([]);
const loading = ref(false);
const knownReasons = new Set([
  'appointment_started',
  'appointment_closed',
  'missed_due_to_late_automation_event',
  'appointment_notice_after_start',
  'appointment_notice_late_import',
  'contact_excluded',
  'automation_rule_inactive',
  'automation_rule_deleted',
  'automation_action_removed',
  'missed_due_to_reschedule',
]);
const stateKey = item => {
  if (item.status === 'cancelled' || item.status === 'skipped')
    return 'SKIPPED';
  if (
    item.status === 'failed' ||
    item.delivery_stage === 'failed' ||
    item.delivery_stage === 'template_rejected'
  )
    return 'NOT_DELIVERED';
  if (item.status === 'completed') return 'SENT';
  return 'PLANNED';
};
const reason = item => {
  if (!item.reason) return '';
  return knownReasons.has(item.reason)
    ? t(`SCHEDULING.NOTIFICATIONS.REASONS.${item.reason.toUpperCase()}`)
    : t('SCHEDULING.NOTIFICATIONS.REASONS.OTHER');
};
const formatDate = value =>
  value
    ? new Intl.DateTimeFormat(locale.value, {
        dateStyle: 'short',
        timeStyle: 'short',
      }).format(new Date(value))
    : '';
watch(
  () => props.appointmentId,
  async id => {
    items.value = [];
    if (!id) return;
    loading.value = true;
    try {
      const response = await SchedulingAppointmentsAPI.notifications(id);
      items.value = response.data.payload || [];
    } catch {
      items.value = [];
    } finally {
      loading.value = false;
    }
  },
  { immediate: true }
);
</script>

<template>
  <section
    class="appointment-drawer-section rounded-xl border border-n-weak p-3"
    data-testid="appointment-notifications"
  >
    <h3 class="mb-2 text-sm font-semibold">
      {{ $t('SCHEDULING.NOTIFICATIONS.PATIENT_TITLE') }}
    </h3>
    <p v-if="!loading && !items.length" class="m-0 text-sm text-n-slate-11">
      {{ $t('SCHEDULING.NOTIFICATIONS.NO_ITEMS') }}
    </p>
    <ul v-else class="m-0 space-y-2 p-0 list-none">
      <li
        v-for="item in items"
        :key="item.id"
        class="flex flex-wrap justify-between gap-2 text-sm"
      >
        <span
          >{{ $t(`SCHEDULING.NOTIFICATIONS.${stateKey(item)}`)
          }}<span v-if="reason(item)"> · {{ reason(item) }}</span></span
        >
        <time v-if="item.scheduled_at" :datetime="item.scheduled_at">{{
          formatDate(item.scheduled_at)
        }}</time>
      </li>
    </ul>
  </section>
</template>
