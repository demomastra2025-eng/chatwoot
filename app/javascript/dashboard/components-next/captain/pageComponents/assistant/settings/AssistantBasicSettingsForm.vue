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
import AssistantUsageModeSelector from '../AssistantUsageModeSelector.vue';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  ASSISTANT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  buildDefaultToolAccessForUsageMode,
  isToolEnabled,
  resolveToolAccessForUsageMode,
  setToolEnabled,
} from '../toolAccessDefaults';

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
  showSubmitButton: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['submit', 'update:usageMode']);

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
  toolAccess: buildDefaultToolAccessForUsageMode(),
  avatarFile: null,
  avatarUrl: '',
  removeAvatar: false,
};

const state = reactive({ ...initialState });
const isExternalAgent = computed(
  () => state.usageMode !== 'internal_assistant'
);
const activeToolScope = computed(() =>
  state.usageMode === 'internal_assistant' ? 'assistant' : 'agent'
);

const validationRules = {
  name: { required, minLength: minLength(1) },
  description: { required, minLength: minLength(1) },
};

const v$ = useVuelidate(validationRules, state);

const getErrorMessage = field => {
  if (!v$.value[field].$error) return '';

  if (field === 'name') {
    return t('CAPTAIN.ASSISTANTS.FORM.NAME.ERROR');
  }

  if (field === 'description') {
    return t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTION.ERROR');
  }

  return '';
};

const formErrors = computed(() => ({
  name: getErrorMessage('name'),
  description: getErrorMessage('description'),
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

const handoffToHumanEnabled = computed({
  get: () => isToolEnabled(state.toolAccess, AGENT_TOOL_SCOPE, HANDOFF_TOOL_ID),
  set: enabled => {
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      HANDOFF_TOOL_ID,
      enabled,
      state.usageMode
    );
  },
});

const faqLookupEnabled = computed({
  get: () =>
    isToolEnabled(state.toolAccess, AGENT_TOOL_SCOPE, FAQ_LOOKUP_TOOL_ID),
  set: enabled => {
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      FAQ_LOOKUP_TOOL_ID,
      enabled,
      state.usageMode
    );
  },
});

const notesEnabled = computed({
  get: () => {
    const scopeName = activeToolScope.value;
    return (
      isToolEnabled(state.toolAccess, scopeName, ADD_CONTACT_NOTE_TOOL_ID) &&
      isToolEnabled(state.toolAccess, scopeName, ADD_PRIVATE_NOTE_TOOL_ID)
    );
  },
  set: enabled => {
    const scopeName =
      state.usageMode === 'internal_assistant'
        ? ASSISTANT_TOOL_SCOPE
        : AGENT_TOOL_SCOPE;

    state.toolAccess = setToolEnabled(
      state.toolAccess,
      scopeName,
      ADD_CONTACT_NOTE_TOOL_ID,
      enabled,
      state.usageMode
    );
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      scopeName,
      ADD_PRIVATE_NOTE_TOOL_ID,
      enabled,
      state.usageMode
    );
  },
});

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
  state.contextAccess = {};
  state.toolAccess = resolveToolAccessForUsageMode(
    config.tool_access || {},
    state.usageMode
  );
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

  const assistantPayload = {};

  if (props.showIdentityFields && props.showNameField) {
    assistantPayload.name = state.name;
  }

  if (props.showIdentityFields && props.showDescriptionField) {
    assistantPayload.description = state.description;
  }

  if (props.showIdentityFields && props.showUsageModeField) {
    assistantPayload.usage_mode = state.usageMode;
  }

  if (props.showFeatureFlags) {
    assistantPayload.config = {
      feature_faq: state.features.conversationFaqs,
      feature_memory: state.features.memories,
      feature_citation: state.features.citations,
      tool_access: state.toolAccess,
    };
  }

  return {
    assistant: assistantPayload,
    avatar: state.avatarFile,
    removeAvatar: state.removeAvatar,
  };
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
  () => state.usageMode,
  newUsageMode => {
    state.toolAccess = resolveToolAccessForUsageMode(
      state.toolAccess,
      newUsageMode
    );
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
        override-line-breaks
        auto-height
        :editor-key="`captain:assistant:${assistant?.id || 'new'}:basic-description`"
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
        <label v-if="isExternalAgent" class="flex items-center gap-2">
          <Checkbox v-model="state.features.conversationFaqs" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CONVERSATION_FAQS') }}
        </label>
        <label v-if="isExternalAgent" class="flex items-center gap-2">
          <Checkbox v-model="state.features.memories" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_MEMORIES') }}
        </label>
        <label class="flex items-center gap-2">
          <Checkbox v-model="notesEnabled" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_NOTES') }}
        </label>
        <label class="flex items-center gap-2">
          <Checkbox v-model="state.features.citations" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CITATIONS') }}
        </label>
        <label v-if="isExternalAgent" class="flex items-center gap-2">
          <Checkbox v-model="faqLookupEnabled" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_FAQ_LOOKUP') }}
        </label>
        <label v-if="isExternalAgent" class="flex items-center gap-2">
          <Checkbox v-model="handoffToHumanEnabled" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_HUMAN_HANDOFF') }}
        </label>
      </div>
    </div>

    <div v-if="showSubmitButton">
      <Button
        :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
        @click="handleBasicInfoUpdate"
      />
    </div>
  </div>
</template>
