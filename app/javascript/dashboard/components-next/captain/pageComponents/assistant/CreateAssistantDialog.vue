<script setup>
import { computed, reactive, ref } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import AssistantForm from './AssistantForm.vue';

import {
  buildDefaultToolAccessForUsageMode,
  normalizeCapabilityToolAccess,
} from './toolAccessDefaults';

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
const resolvedAssistant = computed(() => props.selectedAssistant || {});
const isCreateMode = computed(() => props.type === 'create');
const isSubmitting = ref(false);
const createFormState = reactive({
  name: '',
  attemptedSubmit: false,
});

const resetCreateForm = () => {
  createFormState.name = '';
  createFormState.attemptedSubmit = false;
};

const updateAssistant = assistantDetails =>
  store.dispatch('captainAssistants/update', {
    id: resolvedAssistant.value.id,
    ...assistantDetails,
  });

const dialogTitle = computed(() =>
  isCreateMode.value
    ? t('CAPTAIN.ASSISTANTS.CREATE.TITLE')
    : t('CAPTAIN.ASSISTANTS.EDIT.TITLE')
);
const dialogDescription = computed(() =>
  isCreateMode.value
    ? t('CAPTAIN.ASSISTANTS.CREATE.FORM_DESCRIPTION')
    : t('CAPTAIN.ASSISTANTS.FORM_DESCRIPTION')
);
const dialogWidth = computed(() => (isCreateMode.value ? 'lg-plus' : '2xl'));
const createNameError = computed(() =>
  createFormState.attemptedSubmit && !createFormState.name.trim()
    ? t('CAPTAIN.ASSISTANTS.FORM.NAME.ERROR')
    : ''
);

const getDialogSuccessMessage = () =>
  isCreateMode.value
    ? t('CAPTAIN.ASSISTANTS.CREATE.SUCCESS_MESSAGE')
    : t('CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE');

const getDialogErrorMessage = () =>
  isCreateMode.value
    ? t('CAPTAIN.ASSISTANTS.CREATE.ERROR_MESSAGE')
    : t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE');

const getCreateDefaultInstruction = () =>
  t('CAPTAIN.ASSISTANTS.CREATE.DEFAULT_INSTRUCTION.EXTERNAL_AGENT');

const getAvatarErrorMessage = reason => {
  if (reason === 'delete') {
    return t('CAPTAIN.ASSISTANTS.AVATAR.EDIT_DELETE_ERROR');
  }

  return isCreateMode.value
    ? t('CAPTAIN.ASSISTANTS.AVATAR.CREATE_UPLOAD_ERROR')
    : t('CAPTAIN.ASSISTANTS.AVATAR.EDIT_UPLOAD_ERROR');
};

const createAssistant = async assistantDetails => {
  try {
    return await store.dispatch('captainAssistants/create', assistantDetails);
  } catch (error) {
    const errorMessage = error?.message || getDialogErrorMessage();
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

const buildCreateAssistantPayload = () => {
  const usageMode = 'external_agent';
  const toolAccess = normalizeCapabilityToolAccess(
    buildDefaultToolAccessForUsageMode(usageMode),
    usageMode
  );

  return {
    assistant: {
      name: createFormState.name.trim(),
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
      useAlert(getAvatarErrorMessage(avatarSyncResult.reason));
    } else {
      useAlert(getDialogSuccessMessage());
    }

    resetCreateForm();
    dialogRef.value.close();
  } catch (error) {
    const errorMessage = error?.message || getDialogErrorMessage();
    useAlert(errorMessage);
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
  if (isCreateMode.value) {
    resetCreateForm();
  }
  emit('close');
};

const handleCancel = () => {
  if (isCreateMode.value) {
    resetCreateForm();
  }
  dialogRef.value.close();
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    :width="dialogWidth"
    :title="dialogTitle"
    :description="dialogDescription"
    :show-cancel-button="isCreateMode"
    :show-confirm-button="isCreateMode"
    :confirm-button-label="t('CAPTAIN.FORM.CREATE')"
    :disable-confirm-button="isCreateMode && isSubmitting"
    :is-loading="isCreateMode && isSubmitting"
    overflow-y-auto
    @confirm="handleCreateConfirm"
    @close="handleClose"
  >
    <div v-if="isCreateMode" class="flex flex-col gap-5">
      <Input
        v-model="createFormState.name"
        :label="t('CAPTAIN.ASSISTANTS.FORM.NAME.LABEL')"
        :placeholder="t('CAPTAIN.ASSISTANTS.FORM.NAME.PLACEHOLDER')"
        :message="createNameError"
        :message-type="createNameError ? 'error' : 'info'"
        autofocus
      />
    </div>
    <AssistantForm
      v-else
      :mode="type"
      :assistant="resolvedAssistant"
      @submit="handleSubmit"
      @cancel="handleCancel"
    />
    <template v-if="!isCreateMode" #footer />
  </Dialog>
</template>
