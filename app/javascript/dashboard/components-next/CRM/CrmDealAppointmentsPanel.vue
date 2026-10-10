<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import { formatCrmErrorMessage, normalizePayload } from 'dashboard/stores/crm/shared';

const props = defineProps({
  deal: { type: Object, required: true },
  canManage: { type: Boolean, default: false },
});
const emit = defineEmits(['dealUpdated']);
const { t, locale } = useI18n();
const route = useRoute();
const appointments = ref([]);
const timezone = ref('UTC');
const plan = ref([]);
const selectedId = ref(null);
const baseline = ref('');
const loading = ref(false);
const saving = ref(false);
const error = ref('');
let generation = 0;
const accountId = computed(() => String(route.params.accountId || ''));
const draftValue = () => JSON.stringify({ plan: plan.value, selectedId: selectedId.value });
const dirty = computed(() => baseline.value !== draftValue());
const paused = computed(() => props.deal.appointmentAutomationState?.pausedAt);
const automationError = computed(() => props.deal.appointmentAutomationState?.lastError);
const appointmentLabel = appointment => {
  const date = new Intl.DateTimeFormat(locale.value, { dateStyle: 'short', timeStyle: 'short', timeZone: timezone.value }).format(new Date(appointment.starts_at));
  return [date, appointment.patient_contact_name || appointment.client_name, appointment.service_name].filter(Boolean).join(' · ');
};
const options = computed(() => [
  { value: '', label: t('CRM.DEAL_APPOINTMENTS.UNASSIGNED') },
  ...appointments.value.map(appointment => ({ value: appointment.id, label: appointmentLabel(appointment) })),
]);
const attended = entry => appointments.value.some(appointment => Number(appointment.id) === Number(entry.appointmentId) && appointment.actual_attended === true);
const required = computed(() => plan.value.filter(entry => entry.required !== false));
const completedCount = computed(() => required.value.filter(attended).length);
const syncDraft = () => {
  plan.value = (props.deal.appointmentPlan || []).map(entry => ({ ...entry }));
  selectedId.value = props.deal.selectedAppointmentId || null;
  baseline.value = draftValue();
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
    if (token !== generation || account !== accountId.value || Number(props.deal.id) !== Number(dealId)) return;
    appointments.value = response.data?.payload || [];
    timezone.value = response.data?.meta?.timezone || 'UTC';
  } catch (failure) {
    if (token === generation && account === accountId.value) error.value = formatCrmErrorMessage(failure, t);
  } finally {
    if (token === generation) loading.value = false;
  }
};
watch(() => [accountId.value, props.deal.id], () => { saving.value = false; syncDraft(); load(); }, { immediate: true });
watch(() => props.deal.lockVersion, () => { if (!dirty.value) syncDraft(); load(); });
onBeforeUnmount(() => { generation += 1; });
const addVisit = () => plan.value.push({ id: crypto.randomUUID(), label: '', required: true, appointmentId: null });
const save = async () => {
  if (!props.canManage || saving.value || plan.value.some(entry => !entry.label.trim())) return;
  const account = accountId.value;
  const dealId = props.deal.id;
  saving.value = true;
  error.value = '';
  try {
    const response = await CrmDealsAPI.appointmentPlan(dealId, {
      lock_version: props.deal.lockVersion,
      selected_appointment_id: selectedId.value || null,
      appointment_plan: plan.value.map(entry => ({ id: entry.id, label: entry.label, required: entry.required !== false, appointment_id: entry.appointmentId || null })),
    });
    if (account !== accountId.value || Number(dealId) !== Number(props.deal.id)) return;
    baseline.value = draftValue();
    emit('dealUpdated', normalizePayload(response.data));
  } catch (failure) {
    if (account === accountId.value && Number(dealId) === Number(props.deal.id)) error.value = formatCrmErrorMessage(failure, t);
  } finally {
    if (account === accountId.value && Number(dealId) === Number(props.deal.id)) saving.value = false;
  }
};
const resume = async () => {
  saving.value = true;
  const account = accountId.value;
  const dealId = props.deal.id;
  try {
    const response = await CrmDealsAPI.resumeAppointmentAutomation(dealId, { lock_version: props.deal.lockVersion });
    if (account === accountId.value && Number(dealId) === Number(props.deal.id)) emit('dealUpdated', normalizePayload(response.data));
  } catch (failure) {
    if (account === accountId.value && Number(dealId) === Number(props.deal.id)) error.value = formatCrmErrorMessage(failure, t);
  } finally {
    if (account === accountId.value && Number(dealId) === Number(props.deal.id)) saving.value = false;
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
      <h3 class="m-0 text-sm font-semibold text-n-slate-12">{{ $t('CRM.DEAL_APPOINTMENTS.TITLE') }}</h3>
      <Button size="xs" color="slate" variant="ghost" icon="i-lucide-refresh-cw" :aria-label="$t('CRM.DEAL_APPOINTMENTS.REFRESH')" :is-loading="loading" @click="load" />
    </div>
    <p v-if="!loading && !appointments.length" class="m-0 text-xs text-n-slate-10">{{ $t('CRM.DEAL_APPOINTMENTS.EMPTY') }}</p>
    <div v-for="appointment in appointments" :key="appointment.id" class="grid gap-1 rounded-lg border border-n-weak p-3 text-xs">
      <span class="font-medium text-n-slate-12">{{ appointmentLabel(appointment) }}</span>
      <span class="text-n-slate-11">{{ statusLabel(appointment) }}</span>
      <span v-if="appointment.status === 'completed' && !appointment.actual_attended" class="text-n-slate-10">{{ $t('CRM.DEAL_APPOINTMENTS.ATTENDANCE_UNKNOWN') }}</span>
    </div>
    <p v-if="paused" class="m-0 text-xs text-n-slate-11">{{ $t('CRM.DEAL_APPOINTMENTS.PAUSED') }}</p>
    <Button v-if="paused && canManage" size="sm" color="slate" variant="faded" :label="$t('CRM.DEAL_APPOINTMENTS.RESUME')" :is-loading="saving" @click="resume" />
    <p v-if="automationError" class="m-0 text-xs text-n-ruby-10">{{ $t('CRM.DEAL_APPOINTMENTS.AUTOMATION_ERROR') }}</p>
    <details>
      <summary class="cursor-pointer text-xs font-medium text-n-slate-12">{{ $t('CRM.DEAL_APPOINTMENTS.PLAN_TITLE') }}</summary>
      <div class="mt-3 grid gap-3">
        <SchedulingSelectField v-model="selectedId" :label="$t('CRM.DEAL_APPOINTMENTS.SELECTED_TARGET')" :options="options" :disabled="!canManage || saving" />
        <p class="m-0 text-xs leading-5 text-n-slate-10">{{ $t('CRM.DEAL_APPOINTMENTS.PLAN_HELP') }}</p>
        <p v-if="required.length" class="m-0 text-xs font-medium text-n-slate-12">{{ $t('CRM.DEAL_APPOINTMENTS.PROGRESS', { completed: completedCount, total: required.length }) }}</p>
        <div v-for="(entry, index) in plan" :key="entry.id" class="grid gap-2 rounded-lg border border-n-weak p-3">
          <Input v-model="entry.label" :label="$t('CRM.DEAL_APPOINTMENTS.VISIT_LABEL')" :disabled="!canManage || saving" />
          <SchedulingSelectField v-model="entry.appointmentId" :label="$t('CRM.DEAL_APPOINTMENTS.LINKED_VISIT')" :options="options" :disabled="!canManage || saving" />
          <label class="flex items-center gap-2 text-xs text-n-slate-11">
            <input v-model="entry.required" type="checkbox" :disabled="!canManage || saving" />
            <span>{{ $t('CRM.DEAL_APPOINTMENTS.REQUIRED') }}</span>
          </label>
          <Button v-if="canManage" size="xs" color="slate" variant="ghost" icon="i-lucide-trash-2" :label="$t('CRM.DEAL_APPOINTMENTS.REMOVE_VISIT')" :disabled="saving" @click="plan.splice(index, 1)" />
        </div>
        <Button v-if="canManage" size="sm" color="slate" variant="faded" icon="i-lucide-plus" :label="$t('CRM.DEAL_APPOINTMENTS.ADD_VISIT')" :disabled="saving || plan.length >= 100" @click="addVisit" />
        <Button v-if="canManage" size="sm" :label="$t('CRM.GENERAL.SAVE')" :disabled="saving || !dirty || plan.some(entry => !entry.label.trim())" :is-loading="saving" @click="save" />
      </div>
    </details>
    <p v-if="error" role="alert" class="m-0 text-xs text-n-ruby-10">{{ error }}</p>
  </section>
</template>
