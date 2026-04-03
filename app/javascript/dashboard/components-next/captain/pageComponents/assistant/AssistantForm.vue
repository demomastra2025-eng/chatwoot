<script setup>
import { reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useMapGetter } from 'dashboard/composables/store';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import ContextAccessSettings from './ContextAccessSettings.vue';
import ToolAccessSettings from './ToolAccessSettings.vue';

const props = defineProps({
  mode: {
    type: String,
    required: true,
    validator: value => ['edit', 'create'].includes(value),
  },
  assistant: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['submit', 'cancel']);

const { t } = useI18n();

const formState = {
  uiFlags: useMapGetter('captainAssistants/getUIFlags'),
};

const initialState = {
  name: '',
  description: '',
  productName: '',
  featureFaq: false,
  featureMemory: false,
  featureCitation: false,
  autoReplyOnLastIncoming: false,
  messageCollapseWindowSeconds: 0,
  historyMessageLimit: 0,
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

const isLoading = computed(() => formState.uiFlags.value.creatingItem);

const getErrorMessage = (field, errorKey) => {
  return v$.value[field].$error
    ? t(`CAPTAIN.ASSISTANTS.FORM.${errorKey}.ERROR`)
    : '';
};

const formErrors = computed(() => ({
  name: getErrorMessage('name', 'NAME'),
  description: getErrorMessage('description', 'DESCRIPTION'),
  productName: getErrorMessage('productName', 'PRODUCT_NAME'),
}));

const handleCancel = () => emit('cancel');

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

const normalizeNonNegativeInteger = value => {
  const normalizedValue = Number(value);
  if (!Number.isFinite(normalizedValue) || normalizedValue <= 0) {
    return 0;
  }

  return Math.floor(normalizedValue);
};

const assistantHasConfiguredToolAccess = assistant =>
  Object.prototype.hasOwnProperty.call(assistant?.config || {}, 'tool_access');

const prepareAssistantDetails = () => {
  const config = {
    product_name: state.productName,
    feature_faq: state.featureFaq,
    feature_memory: state.featureMemory,
    feature_citation: state.featureCitation,
    auto_reply_on_last_incoming: state.autoReplyOnLastIncoming,
    message_collapse_window_seconds: normalizeNonNegativeInteger(
      state.messageCollapseWindowSeconds
    ),
    history_message_limit: normalizeNonNegativeInteger(
      state.historyMessageLimit
    ),
    context_access: state.contextAccess,
  };

  if (
    assistantHasConfiguredToolAccess(props.assistant) ||
    Object.keys(state.toolAccess || {}).length
  ) {
    config.tool_access = state.toolAccess;
  }

  return {
    assistant: {
      name: state.name,
      description: state.description,
      config,
    },
    avatar: state.avatarFile,
    removeAvatar: state.removeAvatar,
  };
};

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) {
    return;
  }

  emit('submit', prepareAssistantDetails());
};

const updateStateFromAssistant = assistant => {
  if (!assistant) return;

  const { name, description, config } = assistant;

  Object.assign(state, {
    name,
    description,
    productName: config.product_name,
    featureFaq: config.feature_faq || false,
    featureMemory: config.feature_memory || false,
    featureCitation: config.feature_citation || false,
    autoReplyOnLastIncoming: config.auto_reply_on_last_incoming || false,
    messageCollapseWindowSeconds: Number(
      config.message_collapse_window_seconds || 0
    ),
    historyMessageLimit: Number(config.history_message_limit || 0),
    contextAccess: config.context_access || {},
    toolAccess: config.tool_access || {},
    avatarFile: null,
    avatarUrl: assistant.avatar_url || '',
    removeAvatar: false,
  });
};

watch(
  () => props.assistant,
  newAssistant => {
    if (props.mode === 'edit' && newAssistant) {
      updateStateFromAssistant(newAssistant);
    }
  },
  { immediate: true }
);
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
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

    <Editor
      v-model="state.description"
      :label="t('CAPTAIN.ASSISTANTS.FORM.DESCRIPTION.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.DESCRIPTION.PLACEHOLDER')"
      :message="formErrors.description"
      :message-type="formErrors.description ? 'error' : 'info'"
      enable-captain-fields
      :captain-context-access="state.contextAccess"
    />

    <Input
      v-model="state.productName"
      :label="t('CAPTAIN.ASSISTANTS.FORM.PRODUCT_NAME.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.PRODUCT_NAME.PLACEHOLDER')"
      :message="formErrors.productName"
      :message-type="formErrors.productName ? 'error' : 'info'"
    />

    <fieldset class="flex flex-col gap-2.5">
      <legend class="mb-3 text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.TITLE') }}
      </legend>

      <label class="flex items-center gap-2">
        <Checkbox v-model="state.featureFaq" />
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CONVERSATION_FAQS') }}
        </span>
      </label>

      <label class="flex items-center gap-2">
        <Checkbox v-model="state.featureMemory" />
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_MEMORIES') }}
        </span>
      </label>

      <label class="flex items-center gap-2">
        <Checkbox v-model="state.featureCitation" />
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CITATIONS') }}
        </span>
      </label>
    </fieldset>

    <div
      class="p-4 rounded-xl border border-n-weak bg-n-solid-1 flex items-center justify-between gap-4"
    >
      <div class="flex-1 min-w-0">
        <h4 class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.AUTO_REPLY_ON_LAST_INCOMING.TITLE') }}
        </h4>
        <p class="text-sm text-n-slate-11 mt-0.5">
          {{
            t('CAPTAIN.ASSISTANTS.FORM.AUTO_REPLY_ON_LAST_INCOMING.DESCRIPTION')
          }}
        </p>
      </div>
      <div class="flex-shrink-0">
        <Switch
          v-model="state.autoReplyOnLastIncoming"
          class="data-[state=checked]:!bg-n-violet-9"
        />
      </div>
    </div>

    <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
      <Input
        v-model="state.messageCollapseWindowSeconds"
        type="number"
        min="0"
        :label="
          t('CAPTAIN.ASSISTANTS.FORM.MESSAGE_COLLAPSE_WINDOW_SECONDS.LABEL')
        "
        :placeholder="
          t(
            'CAPTAIN.ASSISTANTS.FORM.MESSAGE_COLLAPSE_WINDOW_SECONDS.PLACEHOLDER'
          )
        "
        :message="
          t(
            'CAPTAIN.ASSISTANTS.FORM.MESSAGE_COLLAPSE_WINDOW_SECONDS.DESCRIPTION'
          )
        "
        message-type="info"
      />

      <Input
        v-model="state.historyMessageLimit"
        type="number"
        min="0"
        :label="t('CAPTAIN.ASSISTANTS.FORM.HISTORY_MESSAGE_LIMIT.LABEL')"
        :placeholder="
          t('CAPTAIN.ASSISTANTS.FORM.HISTORY_MESSAGE_LIMIT.PLACEHOLDER')
        "
        :message="
          t('CAPTAIN.ASSISTANTS.FORM.HISTORY_MESSAGE_LIMIT.DESCRIPTION')
        "
        message-type="info"
      />
    </div>

    <ContextAccessSettings v-model="state.contextAccess" />

    <ToolAccessSettings
      v-model="state.toolAccess"
      :assistant-id="assistant.id"
    />

    <div class="flex items-center justify-between w-full gap-3">
      <Button
        type="button"
        variant="faded"
        color="slate"
        :label="t('CAPTAIN.FORM.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        type="submit"
        :label="t(`CAPTAIN.FORM.${mode.toUpperCase()}`)"
        class="w-full"
        :is-loading="isLoading"
        :disabled="isLoading"
      />
    </div>
  </form>
</template>
