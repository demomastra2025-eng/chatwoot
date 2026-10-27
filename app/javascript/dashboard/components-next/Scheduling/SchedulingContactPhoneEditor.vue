<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import PhoneNumberInput from 'dashboard/components-next/phonenumberinput/PhoneNumberInput.vue';
import { isKazakhstanE164Phone } from 'dashboard/stores/scheduling/appointmentForm';

const props = defineProps({
  contactId: { type: [Number, String], default: null },
  phone: { type: String, default: '' },
  saving: { type: Boolean, default: false },
  error: { type: String, default: '' },
});
const emit = defineEmits(['save']);
const { t } = useI18n();
const editing = ref(false);
const draft = ref('');
const validationError = ref('');

watch(
  () => [props.contactId, props.phone],
  ([, value]) => {
    draft.value = value || '';
    editing.value = false;
    validationError.value = '';
  }
);

const open = () => {
  draft.value = props.phone || '';
  validationError.value = '';
  editing.value = true;
};
const cancel = () => {
  editing.value = false;
  validationError.value = '';
};
const save = () => {
  if (!isKazakhstanE164Phone(draft.value)) {
    validationError.value = t(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED'
    );
    return;
  }
  validationError.value = '';
  emit('save', draft.value);
};
</script>

<template>
  <div class="appointment-drawer-row min-w-0" data-test="contact-phone-editor">
    <span class="appointment-drawer-label">{{
      $t('SCHEDULING.CONTACT.PHONE')
    }}</span>
    <div class="appointment-drawer-control min-w-0">
      <div v-if="!editing" class="flex min-w-0 flex-wrap items-center gap-2">
        <span
          v-if="phone"
          class="break-all text-sm tabular-nums text-n-slate-11"
          >{{ phone }}</span
        >
        <Button
          size="sm"
          variant="link"
          color="blue"
          :label="
            phone
              ? $t('SCHEDULING.CONTACT.CHANGE_PHONE')
              : $t('SCHEDULING.CONTACT.ADD_PHONE')
          "
          :disabled="saving"
          @click="open"
        />
      </div>
      <div v-else class="grid min-w-0 gap-2">
        <PhoneNumberInput
          v-model="draft"
          default-country="KZ"
          :show-country-flag="false"
          :max-digits="11"
          :label="$t('SCHEDULING.CONTACT.PHONE')"
          :disabled="saving"
          size="md"
        />
        <p v-if="validationError || error" class="m-0 text-xs text-n-ruby-9">
          {{ validationError || error }}
        </p>
        <div class="flex flex-wrap gap-2">
          <Button
            size="sm"
            :label="$t('SCHEDULING.CONTACT.SAVE_ACTION')"
            :disabled="saving"
            @click="save"
          />
          <Button
            size="sm"
            variant="link"
            :label="$t('SCHEDULING.CONTACT.CANCEL_ACTION')"
            :disabled="saving"
            @click="cancel"
          />
        </div>
      </div>
    </div>
  </div>
</template>
