<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import { normalizePayload } from 'dashboard/stores/scheduling/shared';
import { formatSchedulingErrorMessage } from 'dashboard/stores/scheduling/shared';
import {
  formatPatientBirthDate,
  canEditLocalPatient,
  hasProviderPatientIdentity,
  maskedPatientIin,
  normalizePatientGender,
  patientBirthDate,
  patientDisplayName,
  patientAgeLabel,
  useConversationPatientContextStore,
} from 'dashboard/stores/scheduling/patientContext';

const props = defineProps({
  patient: { type: Object, required: true },
  contextKey: { type: String, default: '' },
  showName: { type: Boolean, default: true },
  summary: { type: Boolean, default: false },
});
const { t, locale } = useI18n();
const patientStore = useConversationPatientContextStore();
const isEditing = ref(false);
const error = ref('');
const nearestAppointment = ref(null);
let appointmentRequestId = 0;
let editSnapshot = null;
const saving = computed(() =>
  Boolean(patientStore.contexts[props.contextKey]?.saving)
);
const canEdit = computed(
  () => Boolean(props.contextKey) && canEditLocalPatient(props.patient)
);
const form = reactive({
  first_name: '',
  last_name: '',
  middle_name: '',
  iin: '',
  birth_date: '',
  gender: 'unknown',
});
const genderOptions = computed(() =>
  ['unknown', 'male', 'female', 'other'].map(value => ({
    value,
    label: t(`SCHEDULING.CONTACT.GENDER.${value.toUpperCase()}`),
  }))
);
const invalid = computed(
  () =>
    !form.first_name.trim() ||
    !form.last_name.trim() ||
    (form.iin && !/^\d{12}$/.test(form.iin))
);
const startEdit = () => {
  if (!canEdit.value || saving.value) return;
  Object.assign(form, {
    first_name: String(props.patient.first_name || '').trim(),
    last_name: String(props.patient.last_name || '').trim(),
    middle_name: String(props.patient.middle_name || '').trim(),
    iin: String(
      props.patient.identifier || props.patient.custom_attributes?.iin || ''
    ).trim(),
    birth_date: patientBirthDate(props.patient),
    gender: normalizePatientGender(props.patient.gender),
  });
  editSnapshot = { ...form };
  error.value = '';
  isEditing.value = true;
};
const save = async () => {
  if (!canEdit.value || !editSnapshot || invalid.value || saving.value) return;
  const key = props.contextKey;
  const id = props.patient.id;
  error.value = '';
  try {
    const values = {
      ...form,
      first_name: form.first_name.trim(),
      last_name: form.last_name.trim(),
      middle_name: form.middle_name.trim(),
    };
    const changes = Object.fromEntries(
      Object.entries(values).filter(
        ([field, value]) => value !== editSnapshot[field]
      )
    );
    const updated = await patientStore.updatePatient(key, id, changes);
    if (key === props.contextKey && id === props.patient.id && updated)
      isEditing.value = false;
  } catch (failure) {
    if (key === props.contextKey && id === props.patient.id)
      error.value = formatSchedulingErrorMessage(failure, t);
  }
};
watch(
  () => [props.contextKey, props.patient.id],
  () => {
    isEditing.value = false;
    editSnapshot = null;
    error.value = '';
  }
);
watch(
  () => props.patient.id,
  async id => {
    appointmentRequestId += 1;
    const currentRequest = appointmentRequestId;
    nearestAppointment.value = null;
    if (!id) return;
    try {
      const { data } = await SchedulingAppointmentsAPI.get({
        patient_contact_ids: id,
        from: new Date().toISOString(),
      });
      if (currentRequest !== appointmentRequestId) return;
      nearestAppointment.value =
        normalizePayload(data)
          .filter(item => item.status !== 'cancelled')
          .sort((left, right) =>
            String(left.startsAt).localeCompare(String(right.startsAt))
          )[0] || null;
    } catch {
      // Clinical details remain readable if appointment history is unavailable.
    }
  },
  { immediate: true }
);
const nearestAppointmentLabel = computed(() => {
  if (!nearestAppointment.value?.startsAt) return '';
  return new Intl.DateTimeFormat('ru', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(nearestAppointment.value.startsAt));
});
const attributes = computed(
  () => props.patient.custom_attributes || props.patient.customAttributes || {}
);
const rows = computed(() => [
  [t('SCHEDULING.CONTACT.BIRTH_DATE'), formatPatientBirthDate(props.patient)],
  [t('SCHEDULING.CONTACT.IIN'), maskedPatientIin(props.patient)],
  [
    t('SCHEDULING.PATIENT_CONTEXT.MEDELEMENT_CARD'),
    (hasProviderPatientIdentity(props.patient) ||
      attributes.value.medelement_patient_card) &&
      t('SCHEDULING.PATIENT_CONTEXT.CARD_LINKED'),
  ],
  [t('CONTACT_PANEL.NEAREST_APPOINTMENT'), nearestAppointmentLabel.value],
]);
const summaryParts = computed(() => {
  const parts = [patientAgeLabel(props.patient, t, locale.value || 'ru')];
  const iin = maskedPatientIin(props.patient);
  if (iin) parts.push(`${t('SCHEDULING.CONTACT.IIN')} ${iin}`);
  if (nearestAppointmentLabel.value)
    parts.push(
      `${t('CONTACT_PANEL.NEAREST_APPOINTMENT')} ${nearestAppointmentLabel.value}`
    );
  return parts.filter(Boolean);
});
</script>

<template>
  <p
    v-if="summary && summaryParts.length"
    class="m-0 min-w-0 break-words text-xs text-n-slate-11"
    data-test="patient-summary"
  >
    {{ summaryParts.join(' · ') }}
  </p>
  <section v-else-if="!summary" class="px-4 pb-3" data-test="patient-details">
    <h3 v-if="showName" class="m-0 mb-2 text-sm font-semibold text-n-slate-12">
      {{ patientDisplayName(patient) }}
    </h3>
    <dl class="m-0 grid gap-2 text-xs">
      <template v-for="[label, value] in rows" :key="label">
        <div v-if="value" class="flex min-w-0 justify-between gap-3">
          <dt class="text-n-slate-11">{{ label }}</dt>
          <dd class="m-0 break-words text-right text-n-slate-12">
            {{ value }}
          </dd>
        </div>
      </template>
    </dl>
    <Button
      v-if="!isEditing && canEdit"
      size="sm"
      variant="ghost"
      :label="t('SCHEDULING.PATIENT_CONTEXT.EDIT_PATIENT')"
      @click="startEdit"
    />
    <form v-if="isEditing && canEdit" class="grid gap-3" @submit.prevent="save">
      <Input
        v-model="form.first_name"
        :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')"
        :disabled="saving"
      />
      <Input
        v-model="form.last_name"
        :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')"
        :disabled="saving"
      />
      <Input
        v-model="form.middle_name"
        :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')"
        :disabled="saving"
      />
      <Input
        v-model="form.iin"
        :label="t('SCHEDULING.CONTACT.IIN')"
        :disabled="saving"
      />
      <Input
        v-model="form.birth_date"
        type="date"
        :label="t('SCHEDULING.CONTACT.BIRTH_DATE')"
        :disabled="saving"
      />
      <label class="grid gap-2 text-xs text-n-slate-11">
        {{ t('SCHEDULING.CONTACT.GENDER_LABEL') }}
        <Select
          v-model="form.gender"
          :options="genderOptions"
          :disabled="saving"
          class="w-full"
        />
      </label>
      <p v-if="error" role="alert" class="m-0 text-xs text-n-ruby-9">
        {{ error }}
      </p>
      <div class="flex justify-end gap-2">
        <Button
          type="button"
          size="sm"
          variant="ghost"
          :disabled="saving"
          :label="t('SCHEDULING.GENERAL.CANCEL')"
          @click="isEditing = false"
        />
        <Button
          type="submit"
          size="sm"
          :disabled="invalid || saving"
          :is-loading="saving"
          :label="t('SCHEDULING.GENERAL.SAVE')"
        />
      </div>
    </form>
  </section>
</template>
