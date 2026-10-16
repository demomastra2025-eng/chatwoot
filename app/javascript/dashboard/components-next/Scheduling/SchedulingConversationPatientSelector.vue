<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import { formatSchedulingErrorMessage } from 'dashboard/stores/scheduling/shared';
import {
  isValidPatientIin,
  normalizePatientIin,
  parseIinMetadata,
} from 'dashboard/stores/scheduling/iin';
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
    label: [patientDisplayName(patient), formatPatientBirthDate(patient)]
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
const iinState = computed(() => parseIinMetadata(form.iin));
const iinError = computed(() => {
  if (!form.iin) return '';
  if (iinState.value.reason === 'length')
    return t('SCHEDULING.CONTACT.IIN_ERROR_LENGTH');
  return iinState.value.valid && isValidPatientIin(form.iin)
    ? ''
    : t('SCHEDULING.CONTACT.IIN_ERROR_INVALID');
});
const isInvalid = computed(
  () =>
    !form.first_name.trim() || !form.last_name.trim() || Boolean(iinError.value)
);
let inferredMetadata = null;
watch(
  () => form.iin,
  value => {
    if (!isCreating.value || props.entry?.saving) return;
    const normalized = normalizePatientIin(value);
    if (normalized !== value) {
      form.iin = normalized;
      return;
    }
    const metadata = iinState.value;
    if (normalized && metadata.valid && isValidPatientIin(normalized)) {
      form.birth_date = metadata.birthDate;
      form.gender = metadata.gender;
      inferredMetadata = metadata;
      return;
    }
    if (inferredMetadata) {
      if (form.birth_date === inferredMetadata.birthDate) form.birth_date = '';
      if (form.gender === inferredMetadata.gender) form.gender = 'unknown';
      inferredMetadata = null;
    }
  },
  { flush: 'sync' }
);
const resetForm = () => {
  isCreating.value = false;
  inferredMetadata = null;
  Object.assign(form, {
    first_name: '',
    last_name: '',
    middle_name: '',
    iin: '',
    birth_date: '',
    gender: 'unknown',
    phone: '',
  });
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
    class="shrink-0 border-b border-n-weak bg-n-alpha-1 px-3 py-2"
    data-test="patient-selector"
  >
    <div class="flex items-center justify-between gap-2">
      <label
        class="flex min-w-0 flex-1 items-center gap-2 text-xs font-medium text-n-slate-11"
      >
        <span class="shrink-0">
          {{ t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT') }}
        </span>
        <Select
          :model-value="entry?.selectedId || ''"
          :options="options"
          :disabled="!entry?.loaded || entry?.loading || entry?.saving"
          class="min-w-0 flex-1"
          @update:model-value="selectPatient"
        />
      </label>
      <Button
        v-if="!isCreating && entry?.loaded"
        size="xs"
        variant="faded"
        color="slate"
        icon="i-lucide-user-plus"
        class="shrink-0"
        :title="t('SCHEDULING.PATIENT_CONTEXT.NEW_PATIENT')"
        :label="t('SCHEDULING.PATIENT_CONTEXT.NEW_PATIENT')"
        @click="startCreate"
      />
    </div>
    <div v-if="entry?.error" class="mt-2 flex items-center justify-between gap-2" role="alert">
      <p class="m-0 text-xs text-n-ruby-9">
        {{ t('SCHEDULING.PATIENT_CONTEXT.LOAD_ERROR') }}
      </p>
      <Button
        size="xs"
        variant="ghost"
        :label="t('DESIGN_SYSTEM.STATE.RETRY')"
        @click="patientStore.load(contextKey, entry.contactId, { force: true })"
      />
    </div>
    <form
      v-if="isCreating"
      class="mt-2.5 grid max-h-[min(32rem,55dvh)] gap-2.5 overflow-y-auto rounded-lg border border-n-weak bg-n-solid-1 p-3"
      @submit.prevent="savePatient"
    >
      <p class="m-0 text-xs text-n-slate-11">
        {{ t('SCHEDULING.PATIENT_CONTEXT.CREATE_DESCRIPTION') }}
      </p>
      <div class="grid grid-cols-2 gap-2">
        <Input
          v-model="form.last_name"
          size="sm"
          :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')"
          :disabled="entry?.saving"
        />
        <Input
          v-model="form.first_name"
          size="sm"
          :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')"
          :disabled="entry?.saving"
        />
      </div>
      <div class="grid grid-cols-2 gap-2">
        <Input
          v-model="form.middle_name"
          size="sm"
          :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')"
          :disabled="entry?.saving"
        />
        <Input
          v-model="form.iin"
          size="sm"
          :label="t('SCHEDULING.CONTACT.IIN')"
          :message="iinError"
          :message-type="iinError ? 'error' : 'info'"
          inputmode="numeric"
          maxlength="12"
          :disabled="entry?.saving"
        />
      </div>
      <div class="grid grid-cols-2 gap-2">
        <Input
          v-model="form.birth_date"
          type="date"
          size="sm"
          :label="t('SCHEDULING.CONTACT.BIRTH_DATE')"
          :disabled="entry?.saving"
        />
        <label class="grid gap-1 text-xs text-n-slate-11">
          {{ t('SCHEDULING.CONTACT.GENDER_LABEL') }}
          <Select
            v-model="form.gender"
            :options="genderOptions"
            :disabled="entry?.saving"
            class="w-full"
          />
        </label>
      </div>
      <Input
        v-model="form.phone"
        size="sm"
        :label="t('SCHEDULING.PATIENT_CONTEXT.OWN_PHONE')"
        :disabled="entry?.saving"
      />
      <p v-if="error" class="m-0 text-xs text-n-ruby-9" role="alert">
        {{ error }}
      </p>
      <div class="flex justify-end gap-2 pt-1">
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
          :label="t('SCHEDULING.GENERAL.SAVE')"
        />
      </div>
    </form>
  </section>
</template>
