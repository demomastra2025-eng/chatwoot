<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import { voiceInboxesForAgent } from './agentVoice';

// «Удалить агента» confirmation. Any agent can be deleted; when it answers the
// calls of a number, the number loses its AI, and the dialog says so.
const props = defineProps({
  assistant: { type: Object, required: true },
});

const emit = defineEmits(['deleted']);

const { t } = useI18n();
const store = useStore();
const dialogRef = ref(null);
const isDeleting = ref(false);

const voiceNumbers = computed(() =>
  voiceInboxesForAgent(props.assistant, store.getters['inboxes/getInboxes'])
    .map(inbox => inbox.phone_number || inbox.name || `#${inbox.id}`)
    .join(', ')
);

const description = computed(() =>
  voiceNumbers.value
    ? `${t('CAPTAIN.ASSISTANTS.DELETE.DESCRIPTION')} ${t('CAPTAIN.GALLERY.CONFIRM_DELETE_VOICE', { numbers: voiceNumbers.value })}`
    : t('CAPTAIN.ASSISTANTS.DELETE.DESCRIPTION')
);

const open = () => dialogRef.value?.open();
const close = () => dialogRef.value?.close();

const handleConfirm = async () => {
  const id = props.assistant?.id;
  if (!id || isDeleting.value) return;

  isDeleting.value = true;
  try {
    await CaptainAssistantAPI.delete(id);
  } catch {
    isDeleting.value = false;
    close();
    useAlert(t('CAPTAIN.ASSISTANTS.DELETE.ERROR_MESSAGE'));
    return;
  }

  useAlert(t('CAPTAIN.ASSISTANTS.DELETE.SUCCESS_MESSAGE'));
  isDeleting.value = false;
  close();
  // Navigate away first so the page of the deleted agent never renders empty.
  emit('deleted', id);
  try {
    await store.dispatch('captainAssistants/get');
  } catch {
    // The agent is deleted; the gallery reloads the list on its own.
  }
};

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="alert"
    :title="t('CAPTAIN.ASSISTANTS.DELETE.TITLE')"
    :description="description"
    :confirm-button-label="t('CAPTAIN.ASSISTANTS.DELETE.CONFIRM')"
    :is-loading="isDeleting"
    @confirm="handleConfirm"
  />
</template>
