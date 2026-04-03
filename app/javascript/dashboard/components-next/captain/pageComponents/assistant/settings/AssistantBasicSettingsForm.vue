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

const props = defineProps({
  assistant: {
    type: Object,
    default: () => ({}),
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
});

const emit = defineEmits([
  'submit',
  'update:contextAccess',
  'update:toolAccess',
]);

const { t } = useI18n();

const initialState = {
  name: '',
  description: '',
  productName: '',
  features: {
    conversationFaqs: false,
    memories: false,
    citations: false,
    contactAttributes: false,
  },
  contextAccess: {},
  toolAccess: {},
  avatarFile: null,
  avatarUrl: '',
  removeAvatar: false,
};

const state = reactive({ ...initialState });

const validationRules = {
  name: { required, minLength: minLength(1) },
  description: { required, minLength: minLength(1) },
  productName: { required, minLength: minLength(1) },
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

const getErrorMessage = field => {
  return v$.value[field].$error ? v$.value[field].$errors[0].$message : '';
};

const formErrors = computed(() => ({
  name: getErrorMessage('name'),
  description: getErrorMessage('description'),
  productName: getErrorMessage('productName'),
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

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.name = assistant.name;
  state.description = assistant.description;
  state.productName = config.product_name;
  state.features = {
    conversationFaqs: config.feature_faq || false,
    memories: config.feature_memory || false,
    citations: config.feature_citation || false,
    contactAttributes: config.feature_contact_attributes || false,
  };
  state.contextAccess = config.context_access || {};
  state.toolAccess = config.tool_access || {};
  state.avatarFile = null;
  state.avatarUrl = assistant.avatar_url || '';
  state.removeAvatar = false;
};

const handleBasicInfoUpdate = async () => {
  const result = await Promise.all([
    v$.value.name.$validate(),
    v$.value.description.$validate(),
    v$.value.productName.$validate(),
  ]).then(results => results.every(Boolean));
  if (!result) return;

  const payload = {
    assistant: {
      name: state.name,
      description: state.description,
      config: {
        ...(props.assistant.config || {}),
        product_name: state.productName,
        feature_faq: state.features.conversationFaqs,
        feature_memory: state.features.memories,
        feature_citation: state.features.citations,
        feature_contact_attributes: state.features.contactAttributes,
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
</script>

<template>
  <div class="flex flex-col gap-6">
    <div class="flex flex-col gap-2">
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

    <Input
      v-model="state.name"
      :label="t('CAPTAIN.ASSISTANTS.FORM.NAME.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.NAME.PLACEHOLDER')"
      :message="formErrors.name"
      :message-type="formErrors.name ? 'error' : 'info'"
    />

    <Input
      v-model="state.productName"
      :label="t('CAPTAIN.ASSISTANTS.FORM.PRODUCT_NAME.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.PRODUCT_NAME.PLACEHOLDER')"
      :message="formErrors.productName"
      :message-type="formErrors.productName ? 'error' : 'info'"
    />

    <Editor
      v-model="state.description"
      :label="t('CAPTAIN.ASSISTANTS.FORM.DESCRIPTION.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.DESCRIPTION.PLACEHOLDER')"
      :message="formErrors.description"
      :message-type="formErrors.description ? 'error' : 'info'"
      class="z-0"
      enable-captain-fields
      :captain-context-assistant-id="assistant.id"
      :captain-context-access="state.contextAccess"
    />

    <div class="flex flex-col gap-2">
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
        <label class="flex items-center gap-2">
          <Checkbox v-model="state.features.contactAttributes" />
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CONTACT_ATTRIBUTES') }}
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

    <div>
      <Button
        :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
        @click="handleBasicInfoUpdate"
      />
    </div>
  </div>
</template>
