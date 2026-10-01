<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';

// M5(b): the number stopped being another contact's primary (or MedElement could not promote it automatically).
// Nothing happens until the administrator confirms the promotion dialog.
const props = defineProps({
  hint: {
    type: Object,
    required: true,
  },
  patientName: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['promote', 'dismiss']);

const { t } = useI18n();

const hintText = computed(() => {
  const owner = props.hint.previous_holder?.name || '';
  const params = {
    phone: props.hint.masked_phone,
    owner,
    patient: props.patientName,
  };
  if (props.hint.reason === 'medelement') {
    return t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.HINT_MEDELEMENT', params);
  }
  // The previous holder was deleted or merged away: the sentence must not end up with an empty name.
  return owner
    ? t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.HINT_RELEASED', params)
    : t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.HINT_RELEASED_NO_OWNER', {
        phone: params.phone,
        patient: params.patient,
      });
});

const siblingNames = computed(() =>
  (props.hint.siblings || []).map(sibling => sibling.name).join(', ')
);
</script>

<template>
  <div
    class="flex flex-col gap-2 p-3 text-sm border rounded-xl border-n-amber-6 bg-n-amber-2 text-n-slate-12"
    data-testid="contact-shared-phone-hint"
  >
    <p class="mb-0">{{ hintText }}</p>
    <p v-if="siblingNames" class="mb-0 text-n-slate-11">
      {{
        t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.HINT_SIBLINGS', {
          names: siblingNames,
        })
      }}
    </p>
    <div class="flex gap-2">
      <Button
        size="sm"
        :label="t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.HINT_PROMOTE')"
        data-testid="contact-shared-phone-hint-promote"
        @click="emit('promote')"
      />
      <Button
        size="sm"
        variant="ghost"
        color="slate"
        :label="t('CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.HINT_DISMISS')"
        data-testid="contact-shared-phone-hint-dismiss"
        @click="emit('dismiss')"
      />
    </div>
  </div>
</template>
