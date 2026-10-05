<script setup>
import { computed, reactive, ref } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import {
  buildDefaultAgentToolAccess,
  normalizeCapabilityToolAccess,
} from './toolAccessDefaults';

const emit = defineEmits(['close', 'created']);

// Every new assistant is a customer-facing AI agent: there is no choice of kind.
const NEW_ASSISTANT_USAGE_MODE = 'external_agent';

const { t } = useI18n();
const store = useStore();

const dialogRef = ref(null);
const isSubmitting = ref(false);
const createFormState = reactive({
  name: '',
  attemptedSubmit: false,
});

const resetCreateForm = () => {
  createFormState.name = '';
  createFormState.attemptedSubmit = false;
};

const createNameError = computed(() =>
  createFormState.attemptedSubmit && !createFormState.name.trim()
    ? t('CAPTAIN.ASSISTANTS.FORM.NAME.ERROR')
    : ''
);

const getCreateDefaultInstruction = () =>
  t('CAPTAIN.ASSISTANTS.CREATE.DEFAULT_INSTRUCTION.EXTERNAL_AGENT');

const getAvatarErrorMessage = reason =>
  reason === 'delete'
    ? t('CAPTAIN.ASSISTANTS.AVATAR.EDIT_DELETE_ERROR')
    : t('CAPTAIN.ASSISTANTS.AVATAR.CREATE_UPLOAD_ERROR');

const createAssistant = async assistantDetails => {
  try {
    return await store.dispatch('captainAssistants/create', assistantDetails);
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.CREATE.ERROR_MESSAGE'));
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

const buildCreateAssistantPayload = () => {
  const toolAccess = normalizeCapabilityToolAccess(
    buildDefaultAgentToolAccess()
  );

  return {
    assistant: {
      name: createFormState.name.trim(),
      usage_mode: NEW_ASSISTANT_USAGE_MODE,
      description: getCreateDefaultInstruction(),
      config: {
        feature_faq: false,
        feature_memory: false,
        feature_citation: false,
        context_access: {},
        tool_access: toolAccess,
      },
    },
    avatar: null,
    removeAvatar: false,
  };
};

const handleSubmit = async updatedAssistant => {
  isSubmitting.value = true;
  try {
    const { assistant, avatar, removeAvatar } = updatedAssistant;
    const savedAssistant = await createAssistant(assistant);

    if (!savedAssistant) return;

    const avatarSyncResult = await syncAvatar({
      assistantId: savedAssistant.id,
      avatar,
      removeAvatar,
    });

    emit('created', avatarSyncResult.assistant || savedAssistant);

    if (!avatarSyncResult.ok) {
      useAlert(getAvatarErrorMessage(avatarSyncResult.reason));
    } else {
      useAlert(t('CAPTAIN.ASSISTANTS.CREATE.SUCCESS_MESSAGE'));
    }

    resetCreateForm();
    dialogRef.value.close();
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.CREATE.ERROR_MESSAGE'));
  } finally {
    isSubmitting.value = false;
  }
};

const handleCreateConfirm = async () => {
  createFormState.attemptedSubmit = true;
  if (!createFormState.name.trim()) {
    return;
  }

  await handleSubmit(buildCreateAssistantPayload());
};

const handleClose = () => {
  resetCreateForm();
  emit('close');
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    width="lg-plus"
    :title="t('CAPTAIN.ASSISTANTS.CREATE.TITLE')"
    :description="t('CAPTAIN.ASSISTANTS.CREATE.FORM_DESCRIPTION')"
    show-cancel-button
    show-confirm-button
    :confirm-button-label="t('CAPTAIN.FORM.CREATE')"
    :disable-confirm-button="isSubmitting"
    :is-loading="isSubmitting"
    overflow-y-auto
    @confirm="handleCreateConfirm"
    @close="handleClose"
  >
    <div class="flex flex-col gap-5">
      <Input
        v-model="createFormState.name"
        :label="t('CAPTAIN.ASSISTANTS.FORM.NAME.LABEL')"
        :placeholder="t('CAPTAIN.ASSISTANTS.FORM.NAME.PLACEHOLDER')"
        :message="createNameError"
        :message-type="createNameError ? 'error' : 'info'"
        autofocus
      />
    </div>
  </Dialog>
</template>
