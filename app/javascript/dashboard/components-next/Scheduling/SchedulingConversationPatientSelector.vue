<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import { formatSchedulingErrorMessage } from 'dashboard/stores/scheduling/shared';
import { schedulingContactNameParts } from 'dashboard/stores/scheduling/contactName';
import {
  isValidPatientIin,
  normalizePatientIin,
  parseIinMetadata,
} from 'dashboard/stores/scheduling/iin';
import {
  canEditLocalPatient,
  formatPatientBirthDate,
  normalizePatientGender,
  patientAgeLabel,
  patientBirthDate,
  patientDisplayName,
  useConversationPatientContextStore,
} from 'dashboard/stores/scheduling/patientContext';

const props = defineProps({
  contextKey: { type: String, required: true },
  entry: { type: Object, default: null },
  conversationDisplayId: { type: [Number, String], default: null },
  compact: { type: Boolean, default: false },
  chips: { type: Boolean, default: false },
  showChips: { type: Boolean, default: undefined },
  showAddButton: { type: Boolean, default: true },
});
const { t, locale } = useI18n();
const patientStore = useConversationPatientContextStore();
const isCreating = ref(false);
const isEditing = ref(false);
const isDropdownOpen = ref(false);
const dropdownRootRef = ref(null);
const error = ref('');
const idempotencyKey = ref('');
let editSnapshot = null;
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
const selectedPatient = computed(
  () =>
    (props.entry?.patients || []).find(
      patient => Number(patient.id) === Number(props.entry?.selectedId)
    ) || null
);
const canEditSelected = computed(() =>
  Boolean(props.entry?.loaded && selectedPatient.value?.id)
);
const options = computed(() =>
  (props.entry?.patients || []).map(patient => ({
    value: patient.id,
    label: [
      patientDisplayName(patient),
      props.compact || props.chips
        ? patientAgeLabel(patient, t, locale?.value || 'ru')
        : formatPatientBirthDate(patient),
    ]
      .filter(Boolean)
      .join(props.compact || props.chips ? ', ' : ' · '),
  }))
);
const selectedOption = computed(
  () =>
    options.value.find(
      option => Number(option.value) === Number(props.entry?.selectedId)
    ) ||
    options.value[0] ||
    null
);
const isOptionSelected = option =>
  Number(option?.value) === Number(props.entry?.selectedId);
const selectedOptionIndex = computed(() => {
  const index = options.value.findIndex(option => isOptionSelected(option));
  return index >= 0 ? index : 0;
});
const selectedOptionPositionLabel = computed(() =>
  options.value.length > 0
    ? `${selectedOptionIndex.value + 1}/${options.value.length}`
    : ''
);
const isInteractionDisabled = computed(
  () =>
    !props.entry?.loaded || Boolean(props.entry?.loading || props.entry?.saving)
);
const addFamilyMemberMenuLabel = computed(() =>
  t('SCHEDULING.PATIENT_CONTEXT.ADD_FAMILY_MEMBER').replace(/^\+\s*/, '')
);
const hasVisibleChips = computed(() =>
  props.showChips === undefined
    ? options.value.length > 1
    : Boolean(props.showChips && options.value.length > 1)
);
const closeDropdown = () => {
  isDropdownOpen.value = false;
};
const toggleDropdown = () => {
  if (isInteractionDisabled.value) return;
  isDropdownOpen.value = !isDropdownOpen.value;
};
const handleOutsideClick = event => {
  if (!isDropdownOpen.value) return;
  if (dropdownRootRef.value && !dropdownRootRef.value.contains(event.target)) {
    closeDropdown();
  }
};
const handleDocumentKeydown = event => {
  if (event.key === 'Escape' && isDropdownOpen.value) {
    event.preventDefault();
    event.stopImmediatePropagation();
    closeDropdown();
  }
};
watch(hasVisibleChips, visible => {
  if (props.chips && !visible) closeDropdown();
});
watch(isInteractionDisabled, disabled => {
  if (disabled) closeDropdown();
});
onMounted(() => {
  document.addEventListener('mousedown', handleOutsideClick);
  document.addEventListener('keydown', handleDocumentKeydown, true);
});
onBeforeUnmount(() => {
  document.removeEventListener('mousedown', handleOutsideClick);
  document.removeEventListener('keydown', handleDocumentKeydown, true);
});
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
    if ((!isCreating.value && !isEditing.value) || props.entry?.saving) return;
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
  isEditing.value = false;
  closeDropdown();
  editSnapshot = null;
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
  if (isInteractionDisabled.value) return;
  resetForm();
  idempotencyKey.value = newIdempotencyKey();
  isCreating.value = true;
};
defineExpose({ startCreate });
const startEdit = () => {
  if (!canEditSelected.value || props.entry?.saving) return;
  resetForm();
  const current = selectedPatient.value;
  const nameParts = schedulingContactNameParts({
    ...current,
    fullName: current.full_name || current.fullName || current.name,
  });
  const attributes =
    current.custom_attributes || current.customAttributes || {};
  Object.assign(form, {
    first_name: nameParts.firstName,
    last_name: nameParts.lastName,
    middle_name: nameParts.middleName,
    iin: String(current.identifier || attributes.iin || '').trim(),
    birth_date: patientBirthDate(current),
    gender: normalizePatientGender(current.gender),
    phone: String(
      current.phone || current.phone_number || current.phoneNumber || ''
    ).trim(),
  });
  inferredMetadata = null;
  editSnapshot = { ...form };
  isEditing.value = true;
};
watch(() => props.contextKey, resetForm);
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
    if (isEditing.value && selectedPatient.value && editSnapshot) {
      const current = selectedPatient.value;
      const values = {
        first_name: form.first_name.trim(),
        last_name: form.last_name.trim(),
        middle_name: form.middle_name.trim(),
        iin: form.iin.trim(),
        birth_date: form.birth_date,
        gender: form.gender,
        phone: form.phone.trim(),
      };
      const changes = Object.fromEntries(
        Object.entries(values).filter(
          ([field, value]) => value !== editSnapshot[field]
        )
      );
      if (!Object.keys(changes).length) {
        resetForm();
        return;
      }
      if (canEditLocalPatient(current)) {
        const updated = await patientStore.updatePatient(
          key,
          current.id,
          changes
        );
        if (isCurrent() && updated) resetForm();
      } else {
        await SchedulingContactsAPI.update(current.id, changes);
        if (!isCurrent()) return;
        await patientStore.load(key, props.entry.contactId, { force: true });
        if (key === props.contextKey) resetForm();
      }
      return;
    }

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
    v-show="
      !chips || hasVisibleChips || isCreating || isEditing || entry?.error
    "
    class="w-full min-w-0 shrink-0"
    :class="
      compact
        ? 'py-1'
        : chips
          ? showAddButton
            ? 'border-b border-n-weak bg-n-alpha-1 px-3 py-1.5'
            : 'py-1'
          : 'border-b border-n-weak bg-n-alpha-1 px-3 py-2'
    "
    data-test="patient-selector"
  >
    <div
      v-if="chips && hasVisibleChips && !isCreating && !isEditing"
      ref="dropdownRootRef"
      class="relative flex w-full min-w-0 items-center gap-1.5"
      data-test="patient-switcher"
    >
      <button
        type="button"
        data-test="patient-dropdown-trigger"
        :disabled="isInteractionDisabled"
        :aria-expanded="isDropdownOpen"
        aria-haspopup="listbox"
        :aria-label="
          selectedOption?.label ||
          t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT')
        "
        :title="selectedOption?.label || t('CONTACT_PANEL.PATIENT_HINT')"
        class="flex h-8 min-w-0 flex-1 items-center justify-between gap-2 rounded-lg border-0 bg-n-solid-1 px-2.5 text-start text-xs text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak transition-colors duration-150 hover:outline-n-slate-6 focus-visible:outline-2 focus-visible:outline-n-brand disabled:cursor-not-allowed disabled:bg-n-slate-2 disabled:opacity-60"
        @click="toggleDropdown"
      >
        <span class="flex min-w-0 flex-1 items-center gap-1.5">
          <span
            class="i-lucide-users size-3.5 shrink-0 text-n-teal-11"
            aria-hidden="true"
          />
          <span class="min-w-0 flex-1 truncate font-medium text-n-slate-12">
            {{
              selectedOption?.label ||
              t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT')
            }}
          </span>
        </span>
        <span class="flex shrink-0 items-center gap-1.5">
          <span
            data-test="patient-count-badge"
            class="inline-flex shrink-0 items-center rounded-full bg-n-teal-3 px-1.5 py-0.5 text-[11px] font-medium leading-none tabular-nums text-n-teal-11"
          >
            {{ selectedOptionPositionLabel }}
          </span>
          <span
            class="i-lucide-chevron-down size-3.5 shrink-0 text-n-slate-11 transition-transform duration-150"
            :class="{ 'rotate-180': isDropdownOpen }"
            aria-hidden="true"
          />
        </span>
      </button>

      <Button
        v-if="showAddButton"
        type="button"
        size="sm"
        variant="faded"
        color="slate"
        icon="i-lucide-user-plus"
        class="shrink-0"
        data-test="add-family-member-button"
        :disabled="isInteractionDisabled"
        :title="t('SCHEDULING.PATIENT_CONTEXT.ADD_FAMILY_MEMBER')"
        :aria-label="t('SCHEDULING.PATIENT_CONTEXT.ADD_FAMILY_MEMBER')"
        @click="startCreate"
      />

      <div
        v-if="isDropdownOpen"
        data-test="patient-dropdown-menu"
        class="absolute inset-x-0 top-full z-40 mt-1 flex max-h-60 flex-col gap-0.5 overflow-y-auto overflow-x-hidden rounded-lg border border-n-weak bg-n-solid-2 p-1 shadow-lg dark:border-n-strong/50"
      >
        <div
          role="listbox"
          :aria-label="t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT')"
          class="flex flex-col gap-0.5"
        >
          <button
            v-for="option in options"
            :key="option.value"
            type="button"
            role="option"
            :disabled="isInteractionDisabled"
            :data-test="`patient-option-${option.value}`"
            :aria-selected="isOptionSelected(option)"
            :title="option.label"
            class="flex w-full min-w-0 items-center justify-between gap-2 rounded-md px-2.5 py-1.5 text-start text-xs transition-colors duration-150 hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-n-brand disabled:cursor-not-allowed disabled:opacity-60"
            :class="
              isOptionSelected(option)
                ? 'bg-n-teal-3/50 font-medium text-n-teal-11'
                : 'text-n-slate-12'
            "
            @click="selectPatient(option.value)"
          >
            <span class="flex min-w-0 flex-1 items-start gap-2">
              <span
                class="mt-0.5 size-3.5 shrink-0"
                :class="
                  isOptionSelected(option)
                    ? 'i-lucide-user-check text-n-teal-11'
                    : 'i-lucide-user text-n-slate-10'
                "
                aria-hidden="true"
              />
              <span
                class="line-clamp-2 min-w-0 flex-1 break-words leading-snug"
              >
                {{ option.label }}
              </span>
            </span>
            <span
              v-if="isOptionSelected(option)"
              class="i-lucide-check size-3.5 shrink-0 text-n-teal-11"
              aria-hidden="true"
            />
          </button>
        </div>

        <template v-if="showAddButton">
          <div class="my-0.5 border-t border-n-weak" role="separator" />
          <Button
            type="button"
            size="xs"
            variant="ghost"
            color="blue"
            icon="i-lucide-user-plus"
            justify="start"
            class="w-full"
            data-test="dropdown-add-family-member-button"
            :disabled="isInteractionDisabled"
            :title="t('SCHEDULING.PATIENT_CONTEXT.ADD_FAMILY_MEMBER')"
            :label="addFamilyMemberMenuLabel"
            @click="startCreate"
          />
        </template>
      </div>
    </div>
    <div v-if="!chips" class="grid min-w-0 gap-1.5">
      <div
        v-if="!compact"
        class="flex min-w-0 items-center justify-between gap-1.5"
      >
        <label
          for="scheduling-conversation-patient-select"
          class="flex min-w-0 items-center gap-1.5 truncate text-xs font-medium text-n-slate-11"
        >
          <span>
            {{ t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT') }}
          </span>
          <span
            v-if="selectedPatient"
            data-test="selected-patient-badge"
            class="inline-flex shrink-0 items-center rounded-md bg-n-teal-3 px-1.5 py-0.5 text-[11px] font-medium text-n-teal-11"
          >
            {{ t('SCHEDULING.PATIENT_CONTEXT.SELECTED_BADGE') }}
          </span>
        </label>
        <div
          v-if="!isCreating && !isEditing && entry?.loaded && canEditSelected"
          class="flex shrink-0 items-center gap-1"
        >
          <Button
            size="xs"
            variant="ghost"
            color="slate"
            icon="i-lucide-pencil"
            data-test="edit-patient-button"
            :title="t('SCHEDULING.GENERAL.EDIT')"
            :aria-label="t('SCHEDULING.GENERAL.EDIT')"
            :label="t('SCHEDULING.GENERAL.EDIT')"
            @click="startEdit"
          />
        </div>
      </div>

      <div
        v-show="!isCreating && !isEditing"
        ref="dropdownRootRef"
        class="relative min-w-0"
      >
        <button
          type="button"
          data-test="patient-dropdown-trigger"
          :disabled="isInteractionDisabled"
          :aria-expanded="isDropdownOpen"
          aria-haspopup="listbox"
          class="flex w-full min-w-0 items-center justify-between gap-2 rounded-lg border-0 bg-n-surface-1 px-3 py-2 text-start text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak transition-colors duration-150 hover:outline-n-slate-6 focus-visible:outline-2 focus-visible:outline-n-brand disabled:cursor-not-allowed disabled:bg-n-slate-2 disabled:opacity-60"
          @click="toggleDropdown"
        >
          <span class="flex min-w-0 flex-1 items-center gap-2">
            <span v-if="compact" class="shrink-0 text-xs text-n-slate-11">
              {{ t('SCHEDULING.PATIENT_CONTEXT.PATIENT') }}:
            </span>
            <span
              v-else
              class="i-lucide-user-check size-4 shrink-0 text-n-teal-11"
              aria-hidden="true"
            />
            <span
              class="min-w-0 flex-1 truncate font-medium text-n-slate-12"
              :title="selectedOption?.label"
            >
              {{
                selectedOption?.label ||
                t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT')
              }}
            </span>
          </span>
          <span
            class="i-lucide-chevron-down size-4 shrink-0 text-n-slate-11 transition-transform duration-150"
            :class="{ 'rotate-180': isDropdownOpen }"
            aria-hidden="true"
          />
        </button>

        <div
          v-if="isDropdownOpen"
          data-test="patient-dropdown-menu"
          class="absolute inset-x-0 top-full z-40 mt-1 flex max-h-64 flex-col gap-0.5 overflow-y-auto overflow-x-hidden rounded-lg border border-n-weak bg-n-solid-2 p-1 shadow-lg dark:border-n-strong/50"
        >
          <div
            role="listbox"
            :aria-label="t('SCHEDULING.PATIENT_CONTEXT.SELECT_PATIENT')"
            class="flex flex-col gap-0.5"
          >
            <button
              v-for="option in options"
              :key="option.value"
              type="button"
              role="option"
              :disabled="isInteractionDisabled"
              :data-test="`patient-option-${option.value}`"
              :aria-selected="isOptionSelected(option)"
              class="flex w-full items-center justify-between gap-2 rounded-md px-2.5 py-1.5 text-start text-sm text-n-slate-12 transition-colors hover:bg-n-alpha-2 disabled:cursor-not-allowed disabled:opacity-60"
              :class="{ 'bg-n-alpha-2 font-medium': isOptionSelected(option) }"
              @click="selectPatient(option.value)"
            >
              <span class="flex min-w-0 flex-1 items-center gap-2">
                <span
                  class="size-4 shrink-0"
                  :class="
                    isOptionSelected(option)
                      ? 'i-lucide-user-check text-n-teal-11'
                      : 'i-lucide-user text-n-slate-10'
                  "
                  aria-hidden="true"
                />
                <span class="min-w-0 flex-1 truncate">{{ option.label }}</span>
              </span>
              <span
                v-if="isOptionSelected(option)"
                class="flex shrink-0 items-center gap-1 text-xs font-medium text-n-teal-11"
              >
                <span>{{
                  t('SCHEDULING.PATIENT_CONTEXT.SELECTED_BADGE')
                }}</span>
                <span
                  class="i-lucide-check size-4 shrink-0"
                  aria-hidden="true"
                />
              </span>
            </button>
          </div>

          <div
            v-if="options.length > 0"
            class="my-0.5 border-t border-n-weak"
            role="separator"
          />

          <Button
            type="button"
            size="xs"
            variant="ghost"
            color="blue"
            icon="i-lucide-plus"
            justify="start"
            class="w-full"
            data-test="new-patient-button"
            :disabled="isInteractionDisabled"
            :title="t('SCHEDULING.PATIENT_CONTEXT.NEW_PATIENT')"
            :label="t('SCHEDULING.PATIENT_CONTEXT.NEW_PATIENT')"
            @click="startCreate"
          />
        </div>

        <select
          id="scheduling-conversation-patient-select"
          :value="entry?.selectedId || ''"
          :disabled="isInteractionDisabled"
          class="sr-only"
          @change="selectPatient($event.target.value)"
        >
          <option
            v-for="option in options"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </option>
        </select>
      </div>
    </div>
    <div
      v-if="entry?.error"
      class="flex items-center justify-between gap-2"
      :class="{
        'mt-2': !chips || (hasVisibleChips && !isCreating && !isEditing),
      }"
      role="alert"
    >
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
      v-if="isCreating || isEditing"
      class="grid min-w-0 max-h-[min(32rem,55dvh)] gap-2.5 overflow-y-auto overflow-x-hidden rounded-lg border border-n-weak bg-n-solid-1 p-3"
      :class="{ 'mt-2.5': !chips || entry?.error }"
      @submit.prevent="savePatient"
    >
      <p v-if="isCreating" class="m-0 text-xs text-n-slate-11">
        {{ t('SCHEDULING.PATIENT_CONTEXT.CREATE_DESCRIPTION') }}
      </p>
      <p
        v-if="isEditing"
        data-test="edit-patient-description"
        class="m-0 text-xs font-medium text-n-slate-12"
      >
        {{ t('SCHEDULING.PATIENT_CONTEXT.EDIT_TITLE') }}
      </p>
      <div class="grid min-w-0 grid-cols-2 gap-2">
        <Input
          v-model="form.last_name"
          size="sm"
          class="min-w-0"
          :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_LAST_NAME')"
          :disabled="entry?.saving"
        />
        <Input
          v-model="form.first_name"
          size="sm"
          class="min-w-0"
          :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_FIRST_NAME')"
          :disabled="entry?.saving"
        />
      </div>
      <div class="grid min-w-0 grid-cols-2 gap-2">
        <Input
          v-model="form.middle_name"
          size="sm"
          class="min-w-0"
          :label="t('SCHEDULING.APPOINTMENT_FORM.CLIENT_MIDDLE_NAME')"
          :disabled="entry?.saving"
        />
        <Input
          v-model="form.iin"
          size="sm"
          class="min-w-0"
          :label="t('SCHEDULING.CONTACT.IIN')"
          :message="iinError"
          :message-type="iinError ? 'error' : 'info'"
          inputmode="numeric"
          maxlength="12"
          :disabled="entry?.saving"
        />
      </div>
      <div class="grid min-w-0 grid-cols-2 gap-2">
        <Input
          v-model="form.birth_date"
          type="date"
          size="sm"
          class="min-w-0"
          :label="t('SCHEDULING.CONTACT.BIRTH_DATE')"
          :disabled="entry?.saving"
        />
        <label class="grid min-w-0 gap-1 text-xs text-n-slate-11">
          {{ t('SCHEDULING.CONTACT.GENDER_LABEL') }}
          <Select
            v-model="form.gender"
            :options="genderOptions"
            :disabled="entry?.saving"
            class="w-full min-w-0"
          />
        </label>
      </div>
      <Input
        v-model="form.phone"
        size="sm"
        class="min-w-0"
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
          :label="
            isCreating
              ? t('SCHEDULING.GENERAL.CREATE')
              : t('SCHEDULING.GENERAL.SAVE')
          "
        />
      </div>
    </form>
  </section>
</template>
