<script setup>
import { reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import ContextAccessSettings from '../ContextAccessSettings.vue';
import ToolAccessSettings from '../ToolAccessSettings.vue';
import AssistantUsageModeSelector from '../AssistantUsageModeSelector.vue';

const props = defineProps({
  assistant: {
    type: Object,
    default: () => ({}),
  },
  showAvatarSection: {
    type: Boolean,
    default: true,
  },
  showIdentityFields: {
    type: Boolean,
    default: true,
  },
  showNameField: {
    type: Boolean,
    default: true,
  },
  showUsageModeField: {
    type: Boolean,
    default: true,
  },
  showDescriptionField: {
    type: Boolean,
    default: true,
  },
  descriptionMaxLength: {
    type: Number,
    default: 10000,
  },
  showFeatureFlags: {
    type: Boolean,
    default: true,
  },
  contextAccess: {
    type: Object,
    default: undefined,
  },
  toolAccess: {
    type: Object,
    default: undefined,
  },
  showContextAccess: {
    type: Boolean,
    default: true,
  },
  showToolAccess: {
    type: Boolean,
    default: true,
  },
  showSubmitButton: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits([
  'submit',
  'update:contextAccess',
  'update:toolAccess',
  'update:usageMode',
]);

const { t } = useI18n();

const initialState = {
  name: '',
  description: '',
  usageMode: 'external_agent',
  features: {
    conversationFaqs: false,
    memories: false,
    citations: false,
  },
  contextAccess: {},
  toolAccess: {},
  avatarFile: null,
  avatarUrl: '',
  removeAvatar: false,
};

const state = reactive({ ...initialState });
const activeToolScope = computed(() =>
  state.usageMode === 'internal_assistant' ? 'assistant' : 'agent'
);

const validationRules = {
  name: { required, minLength: minLength(1) },
  description: { required, minLength: minLength(1) },
};

const v$ = useVuelidate(validationRules, state);
const hasExternalContextAccess = computed(
  () => props.contextAccess !== undefined
);
const hasExternalToolAccess = computed(() => props.toolAccess !== undefined);
const assistantHasToolAccessConfig = computed(() =>
  Object.prototype.hasOwnProperty.call(
    props.assistant?.config || {},
    'tool_access'
  )
);

const getErrorMessage = (field, translationKey) => {
  return v$.value[field].$error
    ? t(`CAPTAIN.ASSISTANTS.FORM.${translationKey}.ERROR`)
    : '';
};

const formErrors = computed(() => ({
  name: getErrorMessage('name', 'NAME'),
  description: getErrorMessage('description', 'INSTRUCTION'),
}));

const handleAvatarUpload = ({ file, url }) => {
  state.avatarFile = file;
  state.avatarUrl = url;
  state.removeAvatar = false;
};

const handleAvatarDelete = () => {
  state.avatarFile = null;
  state.avatarUrl = '';
  state.removeAvatar = Boolean(props.assistant?.avatar_url);
};

const resolveInstructionText = assistant => {
  return assistant?.description?.trim?.() || '';
};

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.name = assistant.name;
  state.description = resolveInstructionText(assistant);
  state.usageMode = assistant.usage_mode || 'external_agent';
  state.features = {
    conversationFaqs: config.feature_faq || false,
    memories: config.feature_memory || false,
    citations: config.feature_citation || false,
  };
  state.contextAccess = config.context_access || {};
  state.toolAccess = config.tool_access || {};
  state.avatarFile = null;
  state.avatarUrl = assistant.avatar_url || '';
  state.removeAvatar = false;
};

const buildPayload = async () => {
  const validations = [];

  if (props.showIdentityFields && props.showNameField) {
    validations.push(v$.value.name.$validate());
  }

  if (props.showIdentityFields && props.showDescriptionField) {
    validations.push(v$.value.description.$validate());
  }

  const result = await Promise.all(validations).then(results =>
    results.every(Boolean)
  );
  if (!result) return null;

  const existingConfig = { ...(props.assistant.config || {}) };
  delete existingConfig.product_name;
  delete existingConfig.instructions;
  delete existingConfig.copilot_instructions;
  delete existingConfig.feature_contact_attributes;
  const payload = {
    assistant: {
      name: state.name,
      description: state.description,
      usage_mode: state.usageMode,
      config: {
        ...existingConfig,
        feature_faq: state.features.conversationFaqs,
        feature_memory: state.features.memories,
        feature_citation: state.features.citations,
        context_access: state.contextAccess,
      },
    },
    avatar: state.avatarFile,
    removeAvatar: state.removeAvatar,
  };

  if (
    assistantHasToolAccessConfig.value ||
    Object.keys(state.toolAccess || {}).length
  ) {
    payload.assistant.config.tool_access = state.toolAccess;
  }

  return payload;
};

const handleBasicInfoUpdate = async () => {
  const payload = await buildPayload();
  if (!payload) return;

  emit('submit', payload);
};

watch(
  () => props.assistant,
  newAssistant => {
    if (newAssistant) updateStateFromAssistant(newAssistant);
  },
  { immediate: true }
);

watch(
  () => props.contextAccess,
  newContextAccess => {
    if (!hasExternalContextAccess.value) return;

    const nextContextAccess = newContextAccess || {};
    if (
      JSON.stringify(state.contextAccess || {}) ===
      JSON.stringify(nextContextAccess)
    ) {
      return;
    }

    state.contextAccess = nextContextAccess;
  },
  { deep: true, immediate: true }
);

watch(
  () => props.toolAccess,
  newToolAccess => {
    if (!hasExternalToolAccess.value) return;

    const nextToolAccess = newToolAccess || {};
    if (
      JSON.stringify(state.toolAccess || {}) === JSON.stringify(nextToolAccess)
    ) {
      return;
    }

    state.toolAccess = nextToolAccess;
  },
  { deep: true, immediate: true }
);

watch(
  () => state.contextAccess,
  newContextAccess => {
    emit('update:contextAccess', newContextAccess);
  },
  { deep: true }
);

watch(
  () => state.toolAccess,
  newToolAccess => {
    emit('update:toolAccess', newToolAccess);
  },
  { deep: true }
);

watch(
  () => state.usageMode,
  newUsageMode => {
    emit('update:usageMode', newUsageMode);
  },
  { immediate: true }
);

defineExpose({
  buildPayload,
});
</script>

<template>
  <div class="flex flex-col gap-6">
    <div v-if="showAvatarSection" class="flex flex-col gap-2">
      <span class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.AVATAR.LABEL') }}
      </span>
      <Avatar
        :src="state.avatarUrl"
        :name="state.name || t('CAPTAIN.PLAYGROUND.ASSISTANT')"
        :size="72"
        icon-name="i-woot-captain"
        allow-upload
        @upload="handleAvatarUpload"
        @delete="handleAvatarDelete"
      />
    </div>

    <template v-if="showIdentityFields">
      <Input
        v-if="showNameField"
        v-model="state.name"
        :label="t('CAPTAIN.ASSISTANTS.FORM.NAME.LABEL')"
        :placeholder="t('CAPTAIN.ASSISTANTS.FORM.NAME.PLACEHOLDER')"
        :message="formErrors.name"
        :message-type="formErrors.name ? 'error' : 'info'"
      />

      <AssistantUsageModeSelector
        v-if="showUsageModeField"
        v-model="state.usageMode"
      />

      <Editor
        v-if="showDescriptionField"
        v-model="state.description"
        :label="t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTION.LABEL')"
        :placeholder="t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTION.PLACEHOLDER')"
        :max-length="descriptionMaxLength"
        :message="formErrors.description"
        :message-type="formErrors.description ? 'error' : 'info'"
        class="z-0"
        enable-captain-tools
        enable-captain-fields
        :captain-context-assistant-id="assistant.id"
        :captain-context-access="state.contextAccess"
        :captain-tool-access="state.toolAccess"
        :captain-tool-scope="activeToolScope"
      />
    </template>

    <div v-if="showFeatureFlags" class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.TITLE') }}
      </label>
      <div class="flex flex-col gap-2">
        <label class="flex items-center gap-2">
          <Checkbox v-model="state.features.conversationFaqs" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CONVERSATION_FAQS') }}
        </label>
        <label class="flex items-center gap-2">
          <Checkbox v-model="state.features.memories" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_MEMORIES') }}
        </label>
        <label class="flex items-center gap-2">
          <Checkbox v-model="state.features.citations" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CITATIONS') }}
        </label>
      </div>
    </div>

    <ContextAccessSettings
      v-if="showContextAccess"
      v-model="state.contextAccess"
      :assistant-id="assistant.id"
    />

    <ToolAccessSettings
      v-if="showToolAccess"
      v-model="state.toolAccess"
      :assistant-id="assistant.id"
    />

    <div v-if="showSubmitButton">
      <Button
        :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
        @click="handleBasicInfoUpdate"
      />
    </div>
  </div>
</template>
