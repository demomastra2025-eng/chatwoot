<script setup>
import { reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useMapGetter } from 'dashboard/composables/store';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';

import SettingsInfoDialog from './settings/SettingsInfoDialog.vue';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  buildDefaultToolAccessForUsageMode,
  isToolEnabled,
  normalizeCapabilityToolAccess,
  resolveToolAccessForUsageMode,
  setToolEnabled,
} from './toolAccessDefaults';

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
const safeAssistant = computed(() => props.assistant || {});

const buildInitialState = () => ({
  name: '',
  description: '',
  usageMode: 'external_agent',
  featureFaq: false,
  featureMemory: false,
  featureCitation: false,
  handoffMessageEnabled: false,
  resolutionMessageEnabled: false,
  handoffMessage: '',
  resolutionMessage: '',
  autoReplyOnLastIncoming: false,
  messageCollapseWindowSeconds: 0,
  historyMessageLimit: 0,
  contextAccess: {},
  toolAccess: buildDefaultToolAccessForUsageMode(),
  avatarFile: null,
  avatarUrl: '',
  removeAvatar: false,
});

const state = reactive(buildInitialState());
const activeToolScope = AGENT_TOOL_SCOPE;

const validationRules = computed(() => ({
  name: { required, minLength: minLength(1) },
  description: { required, minLength: minLength(1) },
  handoffMessage: state.handoffMessageEnabled
    ? { minLength: minLength(1) }
    : {},
  resolutionMessage: state.resolutionMessageEnabled
    ? { minLength: minLength(1) }
    : {},
}));

const v$ = useVuelidate(validationRules, state);

const isLoading = computed(() => formState.uiFlags.value.creatingItem);

const getErrorMessage = (field, errorKey) => {
  return v$.value[field].$error
    ? t(`CAPTAIN.ASSISTANTS.FORM.${errorKey}.ERROR`)
    : '';
};

const formErrors = computed(() => ({
  name: getErrorMessage('name', 'NAME'),
  description: getErrorMessage('description', 'INSTRUCTION'),
  handoffMessage: getErrorMessage('handoffMessage', 'INSTRUCTION'),
  resolutionMessage: getErrorMessage('resolutionMessage', 'INSTRUCTION'),
}));

const handoffInfoPoints = computed(() => [
  t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.INFO_POINTS.TRIGGER'),
  t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.INFO_POINTS.FALLBACK'),
  t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.INFO_POINTS.FIELDS'),
]);

const resolutionInfoPoints = computed(() => [
  t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.INFO_POINTS.TRIGGER'),
  t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.INFO_POINTS.DEFAULT'),
  t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.INFO_POINTS.USE_CASE'),
]);

const handleCancel = () => emit('cancel');

const handleAvatarUpload = ({ file, url }) => {
  state.avatarFile = file;
  state.avatarUrl = url;
  state.removeAvatar = false;
};

const handleAvatarDelete = () => {
  state.avatarFile = null;
  state.avatarUrl = '';
  state.removeAvatar = Boolean(safeAssistant.value?.avatar_url);
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
    const scopeName = activeToolScope;
    return (
      isToolEnabled(state.toolAccess, scopeName, ADD_CONTACT_NOTE_TOOL_ID) &&
      isToolEnabled(state.toolAccess, scopeName, ADD_PRIVATE_NOTE_TOOL_ID)
    );
  },
  set: enabled => {
    const scopeName = AGENT_TOOL_SCOPE;

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

const normalizeNonNegativeInteger = value => {
  const normalizedValue = Number(value);
  if (!Number.isFinite(normalizedValue) || normalizedValue <= 0) {
    return 0;
  }

  return Math.floor(normalizedValue);
};

const prepareAssistantDetails = () => {
  const config = {
    feature_faq: state.featureFaq,
    feature_memory: state.featureMemory,
    feature_citation: state.featureCitation,
    handoff_message: state.handoffMessageEnabled ? state.handoffMessage : '',
    resolution_message: state.resolutionMessageEnabled
      ? state.resolutionMessage
      : '',
    auto_reply_on_last_incoming: state.autoReplyOnLastIncoming,
    message_collapse_window_seconds: normalizeNonNegativeInteger(
      state.messageCollapseWindowSeconds
    ),
    history_message_limit: normalizeNonNegativeInteger(
      state.historyMessageLimit
    ),
    context_access: {},
    tool_access: normalizeCapabilityToolAccess(
      state.toolAccess,
      state.usageMode
    ),
  };

  return {
    assistant: {
      name: state.name,
      description: state.description || safeAssistant.value.description || '',
      usage_mode: 'external_agent',
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

  const { name, config } = assistant;

  Object.assign(state, {
    name,
    description: resolveInstructionText(assistant),
    usageMode: 'external_agent',
    featureFaq: config.feature_faq || false,
    featureMemory: config.feature_memory || false,
    featureCitation: config.feature_citation || false,
    handoffMessageEnabled: Boolean(config.handoff_message),
    resolutionMessageEnabled: Boolean(config.resolution_message),
    handoffMessage: config.handoff_message || '',
    resolutionMessage: config.resolution_message || '',
    autoReplyOnLastIncoming: config.auto_reply_on_last_incoming || false,
    messageCollapseWindowSeconds: Number(
      config.message_collapse_window_seconds || 0
    ),
    historyMessageLimit: Number(config.history_message_limit || 0),
    contextAccess: {},
    toolAccess: resolveToolAccessForUsageMode(
      config.tool_access || {},
      'external_agent'
    ),
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
      return;
    }

    if (props.mode === 'create') {
      Object.assign(state, buildInitialState());
    }
  },
  { immediate: true }
);

watch(
  () => state.usageMode,
  usageMode => {
    if (
      props.mode === 'create' &&
      !Object.keys(state.toolAccess || {}).length
    ) {
      state.toolAccess = buildDefaultToolAccessForUsageMode(usageMode);
    } else {
      state.toolAccess = resolveToolAccessForUsageMode(
        state.toolAccess,
        usageMode
      );
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
      override-line-breaks
      :label="t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTION.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTION.PLACEHOLDER')"
      :message="formErrors.description"
      :message-type="formErrors.description ? 'error' : 'info'"
      class="z-0"
      enable-captain-tools
      enable-captain-fields
      enable-captain-skills
      :captain-context-assistant-id="safeAssistant.id"
      :captain-context-access="state.contextAccess"
      :captain-tool-access="state.toolAccess"
      :captain-tool-scope="activeToolScope"
    />

    <div
      class="flex flex-col gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <div class="flex items-start justify-between gap-4">
        <div class="flex items-center gap-2">
          <h4 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.LABEL') }}
          </h4>
          <SettingsInfoDialog
            :title="t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.INFO_TITLE')"
            :description="
              t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.INFO_DESCRIPTION')
            "
            :points="handoffInfoPoints"
            align="left"
          />
        </div>
        <Switch
          v-model="state.handoffMessageEnabled"
          class="data-[state=checked]:!bg-n-violet-9"
        />
      </div>

      <Editor
        v-if="state.handoffMessageEnabled"
        v-model="state.handoffMessage"
        override-line-breaks
        auto-height
        :editor-key="`captain:assistant:${assistant?.id || mode}:handoff-message`"
        :placeholder="t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.PLACEHOLDER')"
        :message="formErrors.handoffMessage"
        :message-type="formErrors.handoffMessage ? 'error' : 'info'"
        :show-character-count="false"
        class="z-0 compact-system-message-editor"
        enable-captain-tools
        enable-captain-fields
        enable-captain-skills
        :captain-context-assistant-id="safeAssistant.id"
        :captain-context-access="state.contextAccess"
        :captain-tool-access="state.toolAccess"
        :captain-tool-scope="activeToolScope"
      />
    </div>

    <div
      class="flex flex-col gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <div class="flex items-start justify-between gap-4">
        <div class="flex items-center gap-2">
          <h4 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.LABEL') }}
          </h4>
          <SettingsInfoDialog
            :title="t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.INFO_TITLE')"
            :description="
              t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.INFO_DESCRIPTION')
            "
            :points="resolutionInfoPoints"
            align="left"
          />
        </div>
        <Switch
          v-model="state.resolutionMessageEnabled"
          class="data-[state=checked]:!bg-n-violet-9"
        />
      </div>

      <Editor
        v-if="state.resolutionMessageEnabled"
        v-model="state.resolutionMessage"
        override-line-breaks
        auto-height
        :editor-key="`captain:assistant:${assistant?.id || mode}:resolution-message`"
        :placeholder="
          t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.PLACEHOLDER')
        "
        :message="formErrors.resolutionMessage"
        :message-type="formErrors.resolutionMessage ? 'error' : 'info'"
        :show-character-count="false"
        class="z-0 compact-system-message-editor"
        enable-captain-tools
        enable-captain-fields
        enable-captain-skills
        :captain-context-assistant-id="safeAssistant.id"
        :captain-context-access="state.contextAccess"
        :captain-tool-access="state.toolAccess"
        :captain-tool-scope="activeToolScope"
      />
    </div>

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
        <Checkbox v-model="notesEnabled" />
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_NOTES') }}
        </span>
      </label>

      <label class="flex items-center gap-2">
        <Checkbox v-model="state.featureCitation" />
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CITATIONS') }}
        </span>
      </label>

      <label class="flex items-center gap-2">
        <Checkbox v-model="faqLookupEnabled" />
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_FAQ_LOOKUP') }}
        </span>
      </label>

      <label class="flex items-center gap-2">
        <Checkbox v-model="handoffToHumanEnabled" />
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_HUMAN_HANDOFF') }}
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
