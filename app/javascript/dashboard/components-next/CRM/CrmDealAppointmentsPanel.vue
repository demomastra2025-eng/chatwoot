<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';

const props = defineProps({
  deal: { type: Object, required: true },
  canManage: { type: Boolean, default: false },
});
const emit = defineEmits(['dealUpdated']);
const { t, locale } = useI18n();
const route = useRoute();
const appointments = ref([]);
const timezone = ref('UTC');
const loading = ref(false);
const saving = ref(false);
const error = ref('');
let generation = 0;

const accountId = computed(() => String(route.params.accountId || ''));
const paused = computed(() => props.deal.appointmentAutomationState?.pausedAt);
const automationError = computed(
  () => props.deal.appointmentAutomationState?.lastError
);

const appointmentLabel = appointment => {
  const date = new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'short',
    timeStyle: 'short',
    timeZone: timezone.value,
  }).format(new Date(appointment.starts_at));
  return [
    date,
    appointment.patient_contact_name || appointment.client_name,
    appointment.service_name,
  ]
    .filter(Boolean)
    .join(' · ');
};

const load = async () => {
  generation += 1;
  const token = generation;
  const account = accountId.value;
  const dealId = props.deal.id;
  loading.value = true;
  error.value = '';
  appointments.value = [];
  try {
    const response = await CrmDealsAPI.appointments(dealId);
    if (
      token !== generation ||
      account !== accountId.value ||
      Number(props.deal.id) !== Number(dealId)
    )
      return;
    appointments.value = response.data?.payload || [];
    timezone.value = response.data?.meta?.timezone || 'UTC';
  } catch (failure) {
    if (token === generation && account === accountId.value)
      error.value = formatCrmErrorMessage(failure, t);
  } finally {
    if (token === generation) loading.value = false;
  }
};

watch(
  () => [accountId.value, props.deal.id, props.deal.lockVersion],
  () => {
    saving.value = false;
    load();
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  generation += 1;
});

const resume = async () => {
  saving.value = true;
  const account = accountId.value;
  const dealId = props.deal.id;
  try {
    const response = await CrmDealsAPI.resumeAppointmentAutomation(dealId, {
      lock_version: props.deal.lockVersion,
    });
    if (account === accountId.value && Number(dealId) === Number(props.deal.id))
      emit('dealUpdated', normalizePayload(response.data));
  } catch (failure) {
    if (account === accountId.value && Number(dealId) === Number(props.deal.id))
      error.value = formatCrmErrorMessage(failure, t);
  } finally {
    if (account === accountId.value && Number(dealId) === Number(props.deal.id))
      saving.value = false;
  }
};

const statusLabel = appointment => {
  const key = `CRM.DEAL_APPOINTMENTS.STATUSES.${appointment.status.toUpperCase()}`;
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(key);
};
</script>

<template>
  <section class="grid gap-3" data-testid="crm-deal-appointments">
    <div class="flex items-center justify-between gap-2">
      <h3 class="m-0 text-sm font-semibold text-n-slate-12">
        {{ $t('CRM.DEAL_APPOINTMENTS.TITLE') }}
      </h3>
      <Button
        size="xs"
        color="slate"
        variant="ghost"
        icon="i-lucide-refresh-cw"
        :aria-label="$t('CRM.DEAL_APPOINTMENTS.REFRESH')"
        :is-loading="loading"
        @click="load"
      />
    </div>
    <p
      v-if="!loading && !appointments.length"
      class="m-0 text-xs text-n-slate-10"
    >
      {{ $t('CRM.DEAL_APPOINTMENTS.EMPTY') }}
    </p>
    <div v-if="appointments.length" class="divide-y divide-n-weak">
      <div
        v-for="appointment in appointments"
        :key="appointment.id"
        class="grid gap-1 py-2 text-xs"
      >
        <span class="font-medium text-n-slate-12">{{
          appointmentLabel(appointment)
        }}</span>
        <span class="text-n-slate-11">{{ statusLabel(appointment) }}</span>
        <span
          v-if="
            appointment.status === 'completed' && !appointment.actual_attended
          "
          class="text-n-slate-10"
          >{{ $t('CRM.DEAL_APPOINTMENTS.ATTENDANCE_UNKNOWN') }}</span
        >
      </div>
    </div>
    <p v-if="paused" class="m-0 text-xs text-n-slate-11">
      {{ $t('CRM.DEAL_APPOINTMENTS.PAUSED') }}
    </p>
    <Button
      v-if="paused && canManage"
      size="sm"
      color="slate"
      variant="faded"
      :label="$t('CRM.DEAL_APPOINTMENTS.RESUME')"
      :is-loading="saving"
      @click="resume"
    />
    <p v-if="automationError" class="m-0 text-xs text-n-ruby-10">
      {{ $t('CRM.DEAL_APPOINTMENTS.AUTOMATION_ERROR') }}
    </p>
    <p v-if="error" class="m-0 text-xs text-n-ruby-10">{{ error }}</p>
  </section>
</template>
