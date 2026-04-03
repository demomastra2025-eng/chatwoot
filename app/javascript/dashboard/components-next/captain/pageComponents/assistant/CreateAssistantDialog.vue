<script setup>
import { ref, computed } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import AssistantForm from './AssistantForm.vue';

const props = defineProps({
  selectedAssistant: {
    type: Object,
    default: () => ({}),
  },
  type: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit'].includes(value),
  },
});
const emit = defineEmits(['close', 'created']);
const { t } = useI18n();
const store = useStore();

const dialogRef = ref(null);
const assistantForm = ref(null);

const updateAssistant = assistantDetails =>
  store.dispatch('captainAssistants/update', {
    id: props.selectedAssistant.id,
    ...assistantDetails,
  });

const i18nKey = computed(
  () => `CAPTAIN.ASSISTANTS.${props.type.toUpperCase()}`
);

const createAssistant = async assistantDetails => {
  try {
    return await store.dispatch('captainAssistants/create', assistantDetails);
  } catch (error) {
    const errorMessage = error?.message || t(`${i18nKey.value}.ERROR_MESSAGE`);
    useAlert(errorMessage);
    return null;
  }
};

const syncAvatar = async ({ assistantId, avatar, removeAvatar }) => {
  if (!assistantId) return { ok: true };

  if (removeAvatar) {
    try {
      await CaptainAssistantAPI.deleteAvatar(assistantId);
      const refreshedAssistant = await store.dispatch(
        'captainAssistants/show',
        assistantId
      );
      return { ok: true, assistant: refreshedAssistant };
    } catch {
      return { ok: false, reason: 'delete' };
    }
  }

  if (avatar) {
    try {
      await CaptainAssistantAPI.updateAvatar(assistantId, avatar);
      const refreshedAssistant = await store.dispatch(
        'captainAssistants/show',
        assistantId
      );
      return { ok: true, assistant: refreshedAssistant };
    } catch {
      return { ok: false, reason: 'upload' };
    }
  }

  return { ok: true };
};

const handleSubmit = async updatedAssistant => {
  try {
    const { assistant, avatar, removeAvatar } = updatedAssistant;
    let savedAssistant;

    if (props.type === 'edit') {
      savedAssistant = await updateAssistant(assistant);
    } else {
      savedAssistant = await createAssistant(assistant);
    }

    if (!savedAssistant) return;

    const avatarSyncResult = await syncAvatar({
      assistantId: savedAssistant.id,
      avatar,
      removeAvatar,
    });

    if (props.type === 'create') {
      emit('created', avatarSyncResult.assistant || savedAssistant);
    }

    if (!avatarSyncResult.ok) {
      const avatarErrorKey =
        avatarSyncResult.reason === 'delete'
          ? 'CAPTAIN.ASSISTANTS.AVATAR.EDIT_DELETE_ERROR'
          : `CAPTAIN.ASSISTANTS.AVATAR.${props.type.toUpperCase()}_UPLOAD_ERROR`;
      useAlert(t(avatarErrorKey));
    } else {
      useAlert(t(`${i18nKey.value}.SUCCESS_MESSAGE`));
    }

    dialogRef.value.close();
  } catch (error) {
    const errorMessage = error?.message || t(`${i18nKey.value}.ERROR_MESSAGE`);
    useAlert(errorMessage);
  }
};

const handleClose = () => {
  emit('close');
};

const handleCancel = () => {
  dialogRef.value.close();
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    :title="t(`${i18nKey}.TITLE`)"
    :description="t('CAPTAIN.ASSISTANTS.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    overflow-y-auto
    @close="handleClose"
  >
    <AssistantForm
      ref="assistantForm"
      :mode="type"
      :assistant="selectedAssistant"
      @submit="handleSubmit"
      @cancel="handleCancel"
    />
    <template #footer />
  </Dialog>
</template>
