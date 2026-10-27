<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useOpenPersonDialog } from 'dashboard/composables/useOpenPersonDialog';
import { INBOX_TYPES } from 'dashboard/helper/inbox';

import Button from 'dashboard/components-next/button/Button.vue';
import VoiceCallButton from 'dashboard/components-next/Contacts/VoiceCallButton.vue';

const props = defineProps({
  contactId: { type: [String, Number], required: true },
  phone: { type: String, default: '' },
  // The patient the dialog is about, when the dialog is held with someone else (a child written to through the parent's number).
  patientContactId: { type: [String, Number], default: null },
  size: { type: String, default: 'sm' },
  showWrite: { type: Boolean, default: true },
  showCall: { type: Boolean, default: true },
  // An icon-only button for narrow places; the label stays as its tooltip.
  iconOnly: { type: Boolean, default: false },
});

const emit = defineEmits(['write', 'callInitiated']);

const { t } = useI18n();
const { openPersonDialog } = useOpenPersonDialog();
const inboxes = useMapGetter('inboxes/getInboxes');

const hasVoiceInbox = computed(() =>
  (inboxes.value || []).some(inbox => inbox.channel_type === INBOX_TYPES.VOICE)
);

const writeLabel = computed(() => t('PERSON_DIALOG.WRITE'));
const callLabel = computed(() => t('PERSON_DIALOG.CALL'));

const write = () => {
  emit('write', props.contactId);
  openPersonDialog(props.contactId, {
    patientContactId: props.patientContactId,
  });
};
</script>

<template>
  <div class="flex items-center gap-2" data-test-id="person-dialog-actions">
    <template v-if="showCall && hasVoiceInbox">
      <VoiceCallButton
        v-if="phone"
        :phone="phone"
        :contact-id="contactId"
        :label="iconOnly ? '' : callLabel"
        :tooltip-label="iconOnly ? callLabel : ''"
        :icon="iconOnly ? 'i-lucide-phone' : ''"
        :size="size"
        data-test-id="person-dialog-call"
        @call-initiated="emit('callInitiated', $event)"
      />
      <Button
        v-else
        v-tooltip.top-end="t('PERSON_DIALOG.CALL_NO_PHONE')"
        :label="iconOnly ? '' : callLabel"
        :icon="iconOnly ? 'i-lucide-phone' : ''"
        :size="size"
        disabled
        data-test-id="person-dialog-call-disabled"
      />
    </template>
    <Button
      v-if="showWrite"
      v-tooltip.top-end="iconOnly ? writeLabel : null"
      :label="iconOnly ? '' : writeLabel"
      :icon="iconOnly ? 'i-lucide-message-circle' : ''"
      :size="size"
      data-test-id="person-dialog-write"
      @click="write"
    />
  </div>
</template>
