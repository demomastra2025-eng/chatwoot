<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import { formatSchedulingErrorMessage } from 'dashboard/stores/scheduling/shared';
import {
  formatPatientBirthDate,
  patientDisplayName,
  useConversationPatientContextStore,
} from 'dashboard/stores/scheduling/patientContext';

const props = defineProps({
  contextKey: { type: String, required: true },
  entry: { type: Object, default: null },
  conversationDisplayId: { type: [Number, String], default: null },
});
const { t } = useI18n();
const patientStore = useConversationPatientContextStore();
const isCreating = ref(false);
const error = ref('');
const idempotencyKey = ref('');
const newIdempotencyKey = () =>
  window.crypto?.randomUUID?.() ||
  'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, character => {
    const value = Math.floor(Math.random() * 16);
    return (character === 'x' ? value : 8 + (value % 4)).toString(16);
  });
const form = reactive({
  first_name: '',
  last_name: '',
  middle_name: '',
  iin: '',
  birth_date: '',
  gender: 'unknown',
  phone: '',
});
const options = computed(() =>
  (props.entry?.patients || []).map(patient => ({
    value: patient.id,
    label: [
      patientDisplayName(patient),
      formatPatientBirthDate(patient) ||
        t('SCHEDULING.PATIENT_CONTEXT.NO_BIRTH_DATE'),
    ]
      .filter(Boolean)
      .join(' · '),
  }))
);
const genderOptions = computed(() =>
  ['unknown', 'male', 'female', 'other'].map(value => ({
    value,
    label: t(`SCHEDULING.CONTACT.GENDER.${value.toUpperCase()}`),
  }))
);
const isInvalid = computed(
  () =>
    !form.first_name.trim() ||
    !form.last_name.trim() ||
    (form.iin && !/^\d{12}$/.test(form.iin))
);
const resetForm = () => {
  Object.assign(form, {
    first_name: '',
    last_name: '',
    middle_name: '',
    iin: '',
    birth_date: '',
    gender: 'unknown',
    phone: '',
  });
  isCreating.value = false;
  error.value = '';
  idempotencyKey.value = '';
};
const startCreate = () => {
  resetForm();
  idempotencyKey.value = newIdempotencyKey();
  isCreating.value = true;
};
watch(() => props.contextKey, resetForm, { flush: 'sync' });
const selectPatient = value => {
  if (props.entry?.saving) return;
  resetForm();
  patientStore.select(props.contextKey, value);
};
const savePatient = async () => {
  if (isInvalid.value || !props.entry?.loaded || props.entry.saving) return;
  const key = props.contextKey;
  const requestId = props.entry.requestId;
  const selectedId = props.entry.selectedId;
  const isCurrent = () =>
    key === props.contextKey && props.entry?.requestId === requestId;
  error.value = '';
  try {
    const { phone, ...patientAttributes } = form;
    const patient = await patientStore.createPatient(key, {
      ...patientAttributes,
      ...(phone.trim() ? { phone: phone.trim() } : {}),
      idempotency_key: idempotencyKey.value,
      first_name: form.first_name.trim(),
      last_name: form.last_name.trim(),
      middle_name: form.middle_name.trim(),
      ...(props.conversationDisplayId
        ? { conversation_display_id: props.conversationDisplayId }
        : {}),
    });
    if (isCurrent() && patient) resetForm();
  } catch (failure) {
    if (isCurrent() && props.entry?.selectedId === selectedId)
      error.value = formatSchedulingErrorMessage(failure, t);
  }
};
</script>

<template>
  <section
    class="shrink-0 border-b border-n-weak px-4 py-3"
    data-test="patient-selector"
  >
    <label class="grid min-w-0 gap-2 text-xs font-medium text-n-slate-11">
      {{ t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT') }}
      <Select
        :model-value="entry?.selectedId || ''"
        :options="options"
        :disabled="!entry?.loaded || entry?.loading || entry?.saving"
        class="w-full"
        @update:model-value="selectPatient"
      />
    </label>
    <p class="mb-0 mt-2 text-xs text-n-slate-10">
      {{ t('SCHEDULING.PATIENT_CONTEXT.SELECTION_SCOPE') }}
    </p>
    <div v-if="entry?.error" class="mt-2 grid gap-2" role="alert">
      <p class="m-0 text-xs text-n-ruby-9">
        {{ t('SCHEDULING.PATIENT_CONTEXT.LOAD_ERROR') }}
      </p>
      <Button
        size="sm"
        variant="ghost"
        :label="t('DESIGN_SYSTEM.STATE.RETRY')"
        @click="patientStore.load(contextKey, entry.contactId, { force: true })"
      />
    </div>
    <Button
      v-if="!isCreating && entry?.loaded"
      size="sm"
      variant="ghost"
      icon="i-lucide-user-plus"
      class="mt-2"
      :label="t('SCHEDULING.PATIENT_CONTEXT.NEW_PATIENT')"
      @click="startCreate"
    />
    <form
      v-if="isCreating"
      class="mt-3 grid max-h-[min(32rem,50dvh)] gap-3 overflow-y-auto"
      @submit.prevent="savePatient"
    >
      <p class="m-0 text-xs text-n-slate-11">
        {{ t('SCHEDULING.PATIENT_CONTEXT.CREATE_DESCRIPTION') }}
      </p>
      <Input
        v-model="form.first_name"
        :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')"
        :disabled="entry?.saving"
      />
      <Input
        v-model="form.last_name"
        :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')"
        :disabled="entry?.saving"
      />
      <Input
        v-model="form.middle_name"
        :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')"
        :disabled="entry?.saving"
      />
      <Input
        v-model="form.iin"
        :label="t('SCHEDULING.CONTACT.IIN')"
        :disabled="entry?.saving"
      />
      <Input
        v-model="form.phone"
        :label="t('SCHEDULING.PATIENT_CONTEXT.OWN_PHONE')"
        :disabled="entry?.saving"
      />
      <Input
        v-model="form.birth_date"
        type="date"
        :label="t('SCHEDULING.CONTACT.BIRTH_DATE')"
        :disabled="entry?.saving"
      />
      <label class="grid gap-2 text-xs text-n-slate-11">
        {{ t('SCHEDULING.CONTACT.GENDER_LABEL') }}
        <Select
          v-model="form.gender"
          :options="genderOptions"
          :disabled="entry?.saving"
          class="w-full"
        />
      </label>
      <p v-if="error" class="m-0 text-xs text-n-ruby-9" role="alert">
        {{ error }}
      </p>
      <div class="flex justify-end gap-2">
        <Button
          type="button"
          size="sm"
          variant="ghost"
          :disabled="entry?.saving"
          :label="t('SCHEDULING.GENERAL.CANCEL')"
          @click="resetForm"
        />
        <Button
          type="submit"
          size="sm"
          :disabled="isInvalid || entry?.saving"
          :is-loading="entry?.saving"
          :label="t('SCHEDULING.PATIENT_CONTEXT.NEW_PATIENT')"
        />
      </div>
    </form>
  </section>
</template>
