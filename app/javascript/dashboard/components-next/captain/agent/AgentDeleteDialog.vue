<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import { parseMainAgentInUseError } from './agentErrors';

// «Удалить агента» confirmation. The API client is called directly so the
// 422 MAIN_AGENT_IN_USE body (the agent answers first in AI channels) can be
// turned into a clear message with the channel names.
const props = defineProps({
  assistant: { type: Object, required: true },
});

const emit = defineEmits(['deleted']);

const { t } = useI18n();
const store = useStore();
const dialogRef = ref(null);
const isDeleting = ref(false);

const channelNames = inboxIds => {
  const inboxes = store.getters['inboxes/getInboxes'] || [];
  return inboxIds
    .map(
      inboxId =>
        inboxes.find(inbox => Number(inbox.id) === Number(inboxId))?.name ||
        `#${inboxId}`
    )
    .join(', ');
};

const failureMessage = error => {
  const mainAgentError = parseMainAgentInUseError(error);
  if (!mainAgentError) return t('CAPTAIN.ASSISTANTS.DELETE.ERROR_MESSAGE');
  if (mainAgentError.inboxIds.length) {
    return t('CAPTAIN.GALLERY.ERRORS.MAIN_AGENT_IN_USE', {
      channels: channelNames(mainAgentError.inboxIds),
    });
  }
  return mainAgentError.message || t('CAPTAIN.ASSISTANTS.DELETE.ERROR_MESSAGE');
};

const open = () => dialogRef.value?.open();
const close = () => dialogRef.value?.close();

const handleConfirm = async () => {
  const id = props.assistant?.id;
  if (!id || isDeleting.value) return;

  isDeleting.value = true;
  try {
    await CaptainAssistantAPI.delete(id);
  } catch (error) {
    isDeleting.value = false;
    close();
    useAlert(failureMessage(error));
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
    :description="t('CAPTAIN.ASSISTANTS.DELETE.DESCRIPTION')"
    :confirm-button-label="t('CAPTAIN.ASSISTANTS.DELETE.CONFIRM')"
    :is-loading="isDeleting"
    @confirm="handleConfirm"
  />
</template>
