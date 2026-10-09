<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import { formatSchedulingErrorMessage } from 'dashboard/stores/scheduling/shared';
import {
  formatPatientBirthDate,
  patientBirthDate,
  patientDisplayName,
  useConversationPatientContextStore,
} from 'dashboard/stores/scheduling/patientContext';

const props = defineProps({
  patient: { type: Object, required: true },
  contextKey: { type: String, default: '' },
});
const { t } = useI18n();
const patientStore = useConversationPatientContextStore();
const isEditing = ref(false);
const error = ref('');
const saving = computed(() => Boolean(patientStore.contexts[props.contextKey]?.saving));
const form = reactive({ first_name: '', last_name: '', middle_name: '', iin: '', birth_date: '', gender: 'unknown' });
const genderOptions = computed(() => ['unknown', 'male', 'female', 'other'].map(value => ({
  value, label: t(`SCHEDULING.CONTACT.GENDER.${value.toUpperCase()}`),
})));
const invalid = computed(() => !form.first_name.trim() || !form.last_name.trim() ||
  (form.iin && !/^\d{12}$/.test(form.iin)));
const startEdit = () => {
  Object.assign(form, {
    first_name: props.patient.first_name || '',
    last_name: props.patient.last_name || '',
    middle_name: props.patient.middle_name || '',
    iin: props.patient.identifier || props.patient.custom_attributes?.iin || '',
    birth_date: patientBirthDate(props.patient),
    gender: props.patient.gender || 'unknown',
  });
  error.value = '';
  isEditing.value = true;
};
const save = async () => {
  if (invalid.value || saving.value) return;
  const key = props.contextKey;
  const id = props.patient.id;
  error.value = '';
  try {
    const updated = await patientStore.updatePatient(key, id, {
      ...form,
      first_name: form.first_name.trim(),
      last_name: form.last_name.trim(),
      middle_name: form.middle_name.trim(),
    });
    if (key === props.contextKey && id === props.patient.id && updated) isEditing.value = false;
  } catch (failure) {
    if (key === props.contextKey && id === props.patient.id) error.value = formatSchedulingErrorMessage(failure, t);
  }
};
const attributes = computed(
  () => props.patient.custom_attributes || props.patient.customAttributes || {}
);
const rows = computed(() => [
  [t('SCHEDULING.CONTACT.BIRTH_DATE'), formatPatientBirthDate(props.patient)],
  [t('SCHEDULING.CONTACT.IIN'), props.patient.identifier || attributes.value.iin],
  [t('SCHEDULING.CONTACT.GENDER_LABEL'), props.patient.gender &&
    t(`SCHEDULING.CONTACT.GENDER.${props.patient.gender.toUpperCase()}`)],
  [t('SCHEDULING.CONTACT.PHONE'), props.patient.phone],
  [t('SCHEDULING.PATIENT_CONTEXT.PROVIDER_ID'), attributes.value.medelement_patient_code],
]);
</script>

<template>
  <section class="border-b border-n-weak px-4 py-3" data-test="patient-details">
    <h3 class="m-0 text-sm font-semibold text-n-slate-12">
      {{ patientDisplayName(patient) }}
    </h3>
    <dl class="mt-2 grid gap-2 text-xs">
      <template v-for="[label, value] in rows" :key="label">
        <div v-if="value" class="flex min-w-0 justify-between gap-3">
          <dt class="text-n-slate-11">{{ label }}</dt>
          <dd class="m-0 break-words text-right text-n-slate-12">{{ value }}</dd>
        </div>
      </template>
    </dl>
    <Button
      v-if="!isEditing && patient.patient_contact_id && contextKey"
      size="sm" variant="ghost" :label="t('SCHEDULING.GENERAL.EDIT')"
      @click="startEdit"
    />
    <form v-if="isEditing" class="grid gap-3" @submit.prevent="save">
      <Input v-model="form.first_name" :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')" :disabled="saving" />
      <Input v-model="form.last_name" :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')" :disabled="saving" />
      <Input v-model="form.middle_name" :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')" :disabled="saving" />
      <Input v-model="form.iin" :label="t('SCHEDULING.CONTACT.IIN')" :disabled="saving" />
      <Input v-model="form.birth_date" type="date" :label="t('SCHEDULING.CONTACT.BIRTH_DATE')" :disabled="saving" />
      <label class="grid gap-2 text-xs text-n-slate-11">
        {{ t('SCHEDULING.CONTACT.GENDER_LABEL') }}
        <Select v-model="form.gender" :options="genderOptions" :disabled="saving" class="w-full" />
      </label>
      <p v-if="error" role="alert" class="m-0 text-xs text-n-ruby-9">{{ error }}</p>
      <div class="flex justify-end gap-2">
        <Button type="button" size="sm" variant="ghost" :disabled="saving" :label="t('SCHEDULING.GENERAL.CANCEL')" @click="isEditing = false" />
        <Button type="submit" size="sm" :disabled="invalid || saving" :is-loading="saving" :label="t('SCHEDULING.GENERAL.SAVE')" />
      </div>
    </form>
  </section>
</template>
