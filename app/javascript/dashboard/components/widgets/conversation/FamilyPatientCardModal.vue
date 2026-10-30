<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'vuex';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import { useAlert } from 'dashboard/composables';
import { resolveOptionalPatientStore } from 'dashboard/composables/useConversationPatientContext';
import { formatSchedulingErrorMessage } from 'dashboard/stores/scheduling/shared';
import {
  isValidPatientIin,
  normalizePatientIin,
  parseIinMetadata,
} from 'dashboard/stores/scheduling/iin';

const props = defineProps({
  show: { type: Boolean, default: false },
  contextKey: { type: String, default: '' },
  contactId: { type: [Number, String], default: null },
  conversationDisplayId: { type: [Number, String], default: null },
});

const emit = defineEmits(['update:show', 'created']);

const { t } = useI18n();
const store = useStore();
const patientStore = resolveOptionalPatientStore();

const error = ref('');
const idempotencyKey = ref('');
let inferredMetadata = null;

const newIdempotencyKey = () =>
  window.crypto?.randomUUID?.() ||
  'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, character => {
    const value = Math.floor(Math.random() * 16);
    return (character === 'x' ? value : 8 + (value % 4)).toString(16);
  });

const form = reactive({
  last_name: '',
  first_name: '',
  middle_name: '',
  iin: '',
  birth_date: '',
  gender: 'unknown',
  phone: '',
});

const entry = computed(() =>
  patientStore && props.contextKey
    ? patientStore.contexts[props.contextKey] || null
    : null
);

const isSaving = computed(() => Boolean(entry.value?.saving));

const genderOptions = computed(() =>
  ['unknown', 'male', 'female', 'other'].map(value => ({
    value,
    label: t(`SCHEDULING.CONTACT.GENDER.${value.toUpperCase()}`),
  }))
);

const iinState = computed(() => parseIinMetadata(form.iin));
const iinError = computed(() => {
  if (!form.iin) return '';
  if (iinState.value.reason === 'length') {
    return t('SCHEDULING.CONTACT.IIN_ERROR_LENGTH');
  }
  return iinState.value.valid && isValidPatientIin(form.iin)
    ? ''
    : t('SCHEDULING.CONTACT.IIN_ERROR_INVALID');
});

const isInvalid = computed(
  () =>
    !form.first_name.trim() || !form.last_name.trim() || Boolean(iinError.value)
);

watch(
  () => form.iin,
  value => {
    if (!props.show || isSaving.value) return;
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
  inferredMetadata = null;
  Object.assign(form, {
    last_name: '',
    first_name: '',
    middle_name: '',
    iin: '',
    birth_date: '',
    gender: 'unknown',
    phone: '',
  });
  error.value = '';
  idempotencyKey.value = newIdempotencyKey();
};

watch(
  () => props.show,
  visible => {
    if (visible) resetForm();
  }
);

const closeModal = () => {
  if (isSaving.value) return;
  emit('update:show', false);
};

const submitCard = async () => {
  if (isInvalid.value || !patientStore || !props.contextKey || isSaving.value) {
    return;
  }
  error.value = '';
  try {
    if (!entry.value?.loaded && props.contactId) {
      await patientStore.load(props.contextKey, props.contactId);
    }
    const { phone, ...patientAttributes } = form;
    const created = await patientStore.createPatient(props.contextKey, {
      ...patientAttributes,
      ...(phone.trim() ? { phone: phone.trim() } : {}),
      idempotency_key: idempotencyKey.value || newIdempotencyKey(),
      first_name: form.first_name.trim(),
      last_name: form.last_name.trim(),
      middle_name: form.middle_name.trim(),
      ...(props.conversationDisplayId
        ? { conversation_display_id: props.conversationDisplayId }
        : {}),
    });
    if (created?.id) {
      store?.dispatch?.('contacts/show', { id: created.id });
      useAlert(t('PATIENT_TABS.CREATE_SUCCESS'));
      emit('created', created);
      emit('update:show', false);
    }
  } catch (failure) {
    error.value = formatSchedulingErrorMessage(failure, t);
  }
};
</script>

<template>
  <Teleport to="body">
    <div
      v-if="show"
      data-modal-safe-interaction
      data-testid="family-patient-card-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-n-alpha-black1/50 p-4 backdrop-blur-[1px]"
      @mousedown.self="closeModal"
    >
      <div
        role="dialog"
        aria-modal="true"
        :aria-label="t('PATIENT_TABS.MODAL_TITLE')"
        class="flex w-full max-w-md flex-col gap-3 rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-xl"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="flex flex-col gap-0.5">
            <h3 class="m-0 text-base font-semibold text-n-slate-12">
              {{ t('PATIENT_TABS.MODAL_TITLE') }}
            </h3>
            <p class="m-0 text-xs text-n-slate-11">
              {{ t('PATIENT_TABS.MODAL_DESCRIPTION') }}
            </p>
          </div>
          <button
            type="button"
            class="inline-flex size-7 items-center justify-center rounded-lg text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
            :aria-label="t('SCHEDULING.GENERAL.CANCEL')"
            @click="closeModal"
          >
            <span class="i-lucide-x size-4" />
          </button>
        </div>

        <form class="grid gap-3" @submit.prevent="submitCard">
          <div class="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
            <Input
              v-model="form.last_name"
              size="sm"
              data-testid="family-card-last-name"
              :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')"
              :disabled="isSaving"
            />
            <Input
              v-model="form.first_name"
              size="sm"
              data-testid="family-card-first-name"
              :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')"
              :disabled="isSaving"
            />
          </div>

          <div class="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
            <Input
              v-model="form.middle_name"
              size="sm"
              :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')"
              :disabled="isSaving"
            />
            <Input
              v-model="form.iin"
              size="sm"
              data-testid="family-card-iin"
              :label="t('SCHEDULING.CONTACT.IIN')"
              :message="iinError"
              :message-type="iinError ? 'error' : 'info'"
              inputmode="numeric"
              maxlength="12"
              :disabled="isSaving"
            />
          </div>

          <div class="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
            <Input
              v-model="form.birth_date"
              type="date"
              size="sm"
              :label="t('SCHEDULING.CONTACT.BIRTH_DATE')"
              :disabled="isSaving"
            />
            <label class="grid min-w-0 gap-1 text-xs text-n-slate-11">
              {{ t('SCHEDULING.CONTACT.GENDER_LABEL') }}
              <Select
                v-model="form.gender"
                :options="genderOptions"
                :disabled="isSaving"
                class="w-full min-w-0"
              />
            </label>
          </div>

          <Input
            v-model="form.phone"
            size="sm"
            :label="t('PATIENT_TABS.OWN_PHONE_OPTIONAL')"
            :disabled="isSaving"
          />

          <p v-if="error" class="m-0 text-xs text-n-ruby-9" role="alert">
            {{ error }}
          </p>

          <div class="flex justify-end gap-2 pt-1">
            <Button
              type="button"
              size="sm"
              variant="ghost"
              :disabled="isSaving"
              :label="t('SCHEDULING.GENERAL.CANCEL')"
              @click="closeModal"
            />
            <Button
              type="submit"
              size="sm"
              data-testid="family-card-submit"
              :disabled="isInvalid || isSaving"
              :is-loading="isSaving"
              :label="t('SCHEDULING.GENERAL.CREATE')"
            />
          </div>
        </form>
      </div>
    </div>
  </Teleport>
</template>
