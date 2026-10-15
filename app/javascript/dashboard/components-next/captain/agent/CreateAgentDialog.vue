<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import {
  buildDefaultAgentToolAccess,
  normalizeCapabilityToolAccess,
} from 'dashboard/components-next/captain/pageComponents/assistant/toolAccessDefaults';

const emit = defineEmits(['close', 'created']);

// Every new assistant is a customer-facing AI agent: there is no choice of
// kind. Only the defaults below are sent: feature_faq / feature_memory /
// feature_citation / context_access stay server defaults (sending
// feature_faq: false silently disabled FAQ lookup for new agents).
const NEW_AGENT_USAGE_MODE = 'external_agent';
const DESCRIPTION_MAX_LENGTH = 400;

const { t } = useI18n();
const store = useStore();

const dialogRef = ref(null);
const isSubmitting = ref(false);
const state = reactive({
  name: '',
  description: '',
  avatarFile: null,
  avatarUrl: '',
  attemptedSubmit: false,
});

const trimmedName = computed(() => state.name.trim());
const trimmedDescription = computed(() => state.description.trim());

const nameError = computed(() => {
  if (!state.attemptedSubmit || trimmedName.value) return '';
  return t('CAPTAIN.GALLERY.CREATE.NAME_ERROR');
});

const descriptionError = computed(() => {
  if (!state.attemptedSubmit) return '';
  if (!trimmedDescription.value) {
    return t('CAPTAIN.GALLERY.CREATE.DESCRIPTION_ERROR_REQUIRED');
  }
  if (trimmedDescription.value.length > DESCRIPTION_MAX_LENGTH) {
    return t('CAPTAIN.GALLERY.CREATE.DESCRIPTION_ERROR_MAX', {
      max: DESCRIPTION_MAX_LENGTH,
    });
  }
  return '';
});

const isFormValid = computed(
  () =>
    Boolean(trimmedName.value) &&
    Boolean(trimmedDescription.value) &&
    trimmedDescription.value.length <= DESCRIPTION_MAX_LENGTH
);

const revokeAvatarPreview = () => {
  if (!state.avatarUrl || typeof URL.revokeObjectURL !== 'function') return;
  URL.revokeObjectURL(state.avatarUrl);
};

const handleAvatarUpload = ({ file, url }) => {
  revokeAvatarPreview();
  state.avatarFile = file || null;
  state.avatarUrl = url || '';
};

const handleAvatarDelete = () => {
  revokeAvatarPreview();
  state.avatarFile = null;
  state.avatarUrl = '';
};

const resetForm = () => {
  revokeAvatarPreview();
  state.name = '';
  state.description = '';
  state.avatarFile = null;
  state.avatarUrl = '';
  state.attemptedSubmit = false;
};

const defaultInstruction = () =>
  t('CAPTAIN.ASSISTANTS.CREATE.DEFAULT_INSTRUCTION.EXTERNAL_AGENT');

const buildCreatePayload = () => {
  const toolAccess = normalizeCapabilityToolAccess(
    buildDefaultAgentToolAccess()
  );

  return {
    assistant: {
      name: trimmedName.value,
      routing_description: trimmedDescription.value,
      usage_mode: NEW_AGENT_USAGE_MODE,
      description: defaultInstruction(),
      config: { tool_access: toolAccess },
    },
  };
};

const createAgent = async () => {
  try {
    return await store.dispatch(
      'captainAssistants/create',
      buildCreatePayload()
    );
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.GALLERY.CREATE.ERROR'));
    return null;
  }
};

// The avatar file is kept in the form until the agent exists, then uploaded.
const uploadAvatar = async agent => {
  if (!state.avatarFile) return { ok: true, agent };

  try {
    await CaptainAssistantAPI.updateAvatar(agent.id, state.avatarFile);
    const refreshedAgent = await store.dispatch(
      'captainAssistants/show',
      agent.id
    );
    return { ok: true, agent: refreshedAgent || agent };
  } catch {
    return { ok: false, agent };
  }
};

const handleConfirm = async () => {
  if (isSubmitting.value) return;

  state.attemptedSubmit = true;
  if (!isFormValid.value) return;

  isSubmitting.value = true;
  try {
    const createdAgent = await createAgent();
    if (!createdAgent?.id) return;

    const avatarResult = await uploadAvatar(createdAgent);
    useAlert(
      avatarResult.ok
        ? t('CAPTAIN.GALLERY.CREATE.SUCCESS')
        : t('CAPTAIN.GALLERY.CREATE.AVATAR_ERROR')
    );

    dialogRef.value?.close();
    emit('created', avatarResult.agent);
  } finally {
    isSubmitting.value = false;
  }
};

const handleClose = () => {
  resetForm();
  emit('close');
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    width="lg-plus"
    :title="t('CAPTAIN.GALLERY.CREATE.TITLE')"
    :confirm-button-label="t('CAPTAIN.GALLERY.CREATE.SUBMIT')"
    :disable-confirm-button="isSubmitting"
    :is-loading="isSubmitting"
    overflow-y-auto
    @confirm="handleConfirm"
    @close="handleClose"
  >
    <div class="flex flex-col gap-5">
      <div class="flex items-center gap-4">
        <Avatar
          :src="state.avatarUrl"
          :name="trimmedName"
          :size="72"
          icon-name="i-woot-captain"
          rounded-full
          allow-upload
          @upload="handleAvatarUpload"
          @delete="handleAvatarDelete"
        />
        <div class="flex min-w-0 flex-col gap-1">
          <span class="text-heading-3 text-n-slate-12">
            {{ t('CAPTAIN.GALLERY.CREATE.AVATAR_LABEL') }}
          </span>
          <span class="text-body-main text-n-slate-11">
            {{ t('CAPTAIN.GALLERY.CREATE.AVATAR_HINT') }}
          </span>
        </div>
      </div>

      <Input
        v-model="state.name"
        :label="t('CAPTAIN.GALLERY.CREATE.NAME_LABEL')"
        :placeholder="t('CAPTAIN.GALLERY.CREATE.NAME_PLACEHOLDER')"
        :message="nameError"
        :message-type="nameError ? 'error' : 'info'"
        autofocus
      />

      <TextArea
        v-model="state.description"
        :label="t('CAPTAIN.GALLERY.CREATE.DESCRIPTION_LABEL')"
        :placeholder="t('CAPTAIN.GALLERY.CREATE.DESCRIPTION_PLACEHOLDER')"
        :max-length="DESCRIPTION_MAX_LENGTH"
        :message="descriptionError"
        :message-type="descriptionError ? 'error' : 'info'"
        show-character-count
        auto-height
        min-height="5rem"
      />
    </div>
  </Dialog>
</template>
