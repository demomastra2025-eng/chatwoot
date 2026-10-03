<script setup>
import { reactive, computed, watch, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import AssistantUsageModeSelector from '../AssistantUsageModeSelector.vue';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  ASSISTANT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  WEB_SCRAPE_URL_TOOL_ID,
  WEB_SEARCH_TOOL_ID,
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
  descriptionMinHeight: {
    type: String,
    default: '10rem',
  },
  descriptionInitialHeight: {
    type: Number,
    default: 240,
  },
  showFeatureFlags: {
    type: Boolean,
    default: true,
  },
  showSubmitButton: {
    type: Boolean,
    default: true,
  },
  audioTranscriptionsAvailable: {
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
    web: false,
    useAudioTranscriptions: true,
  },
  contextAccess: {},
  toolAccess: buildDefaultToolAccessForUsageMode(),
  avatarFile: null,
  avatarUrl: '',
  removeAvatar: false,
};

const state = reactive({ ...initialState });
const instructionEditorRef = ref(null);
const isExternalAgent = computed(
  () => state.usageMode !== 'internal_assistant'
);
const activeToolScope = computed(() =>
  state.usageMode === 'internal_assistant'
    ? ASSISTANT_TOOL_SCOPE
    : AGENT_TOOL_SCOPE
);
const validationRules = {
  name: { required, minLength: minLength(1) },
  description: { required, minLength: minLength(1) },
};

const instructionReferenceActions = computed(() => [
  {
    id: 'tools',
    marker: '@',
    label: t('CAPTAIN.ASSISTANTS.FORM.REFERENCE_ACTIONS.TOOLS'),
  },
  {
    id: 'fields',
    marker: '$',
    label: t('CAPTAIN.ASSISTANTS.FORM.REFERENCE_ACTIONS.FIELDS'),
  },
  {
    id: 'skills',
    marker: '!',
    label: t('CAPTAIN.ASSISTANTS.FORM.REFERENCE_ACTIONS.SKILLS'),
  },
]);

const openInstructionReferenceMenu = menuType => {
  instructionEditorRef.value?.openCaptainReferenceMenu?.(menuType);
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

const webAccessEnabled = computed({
  get: () =>
    state.features.web ||
    (isToolEnabled(state.toolAccess, AGENT_TOOL_SCOPE, WEB_SEARCH_TOOL_ID) &&
      isToolEnabled(
        state.toolAccess,
        AGENT_TOOL_SCOPE,
        WEB_SCRAPE_URL_TOOL_ID
      )),
  set: enabled => {
    state.features.web = enabled;
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      WEB_SEARCH_TOOL_ID,
      enabled,
      state.usageMode
    );
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      WEB_SCRAPE_URL_TOOL_ID,
      enabled,
      state.usageMode
    );
  },
});

const audioTranscriptionsLabel = computed(() =>
  props.audioTranscriptionsAvailable
    ? t('CAPTAIN.ASSISTANTS.FORM.FEATURES.USE_AUDIO_TRANSCRIPTIONS')
    : t('CAPTAIN.ASSISTANTS.FORM.FEATURES.USE_AUDIO_TRANSCRIPTIONS_DISABLED')
);

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
    web: config.feature_web || false,
    useAudioTranscriptions: config.use_audio_transcriptions !== false,
  };
  state.contextAccess = {};
  state.toolAccess = resolveToolAccessForUsageMode(
    config.tool_access || {},
    state.usageMode
  );
  if (state.features.web) {
    webAccessEnabled.value = true;
  }
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
      feature_web: webAccessEnabled.value,
      tool_access: state.toolAccess,
    };

    if (props.audioTranscriptionsAvailable) {
      assistantPayload.config.use_audio_transcriptions =
        state.features.useAudioTranscriptions;
    }
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

      <div v-if="showDescriptionField" class="flex flex-col gap-2">
        <div class="flex w-full flex-wrap items-center justify-between gap-2">
          <span class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTION.LABEL') }}
          </span>
          <div class="flex min-w-0 flex-wrap items-center justify-center gap-2">
            <Button
              v-for="action in instructionReferenceActions"
              :key="action.id"
              size="sm"
              color="slate"
              variant="faded"
              class="!px-3"
              @mousedown.prevent
              @click="openInstructionReferenceMenu(action.id)"
            >
              <span class="flex min-w-0 truncate">
                <span class="font-semibold text-n-brand">
                  {{ action.marker }}
                </span>
                <span class="min-w-0 truncate">{{ action.label }}</span>
              </span>
            </Button>
          </div>
        </div>
        <Editor
          ref="instructionEditorRef"
          v-model="state.description"
          override-line-breaks
          auto-height
          :editor-key="`captain:assistant:${assistant?.id || 'new'}:basic-description`"
          :placeholder="t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTION.PLACEHOLDER')"
          :max-length="descriptionMaxLength"
          :initial-height="descriptionInitialHeight"
          :min-height="descriptionMinHeight"
          :message="formErrors.description"
          :message-type="formErrors.description ? 'error' : 'info'"
          class="z-0"
          enable-captain-tools
          enable-captain-fields
          enable-captain-skills
          :captain-context-assistant-id="assistant.id"
          :captain-context-access="state.contextAccess"
          :captain-tool-access="state.toolAccess"
          :captain-tool-scope="activeToolScope"
        />
      </div>
    </template>

    <section
      v-if="showFeatureFlags"
      class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 py-3"
    >
      <h3 class="mb-2 text-sm font-semibold text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.TITLE') }}
      </h3>
      <div class="grid gap-3 sm:grid-cols-2">
        <section
          v-if="isExternalAgent"
          class="rounded-xl bg-n-slate-1 px-3 py-2.5"
        >
          <h4 class="mb-2 text-xs font-semibold text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.GROUPS.CUSTOMER_CONTEXT') }}
          </h4>
          <div class="capability-list flex flex-col divide-y divide-n-weak/50">
            <label class="flex items-center justify-between gap-3">
              <span>{{
                t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CONVERSATION_FAQS')
              }}</span>
              <Switch v-model="state.features.conversationFaqs" />
            </label>
            <label class="flex items-center justify-between gap-3">
              <span>{{
                t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_MEMORIES')
              }}</span>
              <Switch v-model="state.features.memories" />
            </label>
          </div>
        </section>

        <section class="rounded-xl bg-n-slate-1 px-3 py-2.5">
          <h4 class="mb-2 text-xs font-semibold text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.GROUPS.TOOLS') }}
          </h4>
          <div class="capability-list flex flex-col divide-y divide-n-weak/50">
            <label class="flex items-center justify-between gap-3">
              <span>{{
                t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_NOTES')
              }}</span>
              <Switch v-model="notesEnabled" />
            </label>
            <label class="flex items-center justify-between gap-3">
              <span>{{
                t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CITATIONS')
              }}</span>
              <Switch v-model="state.features.citations" />
            </label>
            <label
              v-if="isExternalAgent"
              class="flex items-center justify-between gap-3"
            >
              <span>{{
                t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_WEB_ACCESS')
              }}</span>
              <Switch v-model="webAccessEnabled" />
            </label>
            <label
              v-if="isExternalAgent"
              class="flex items-center justify-between gap-3"
            >
              <span>{{
                t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_FAQ_LOOKUP')
              }}</span>
              <Switch v-model="faqLookupEnabled" />
            </label>
            <label
              v-if="isExternalAgent"
              class="flex items-center justify-between gap-3"
            >
              <span>{{
                t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_HUMAN_HANDOFF')
              }}</span>
              <Switch v-model="handoffToHumanEnabled" />
            </label>
          </div>
        </section>

        <section
          v-if="isExternalAgent"
          class="rounded-xl bg-n-slate-1 px-3 py-2.5 sm:col-span-2"
        >
          <h4 class="mb-2 text-xs font-semibold text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.GROUPS.VOICE') }}
          </h4>
          <div class="capability-list flex flex-col divide-y divide-n-weak/50">
            <label class="flex items-center justify-between gap-3">
              <span>{{ audioTranscriptionsLabel }}</span>
              <Switch
                v-model="state.features.useAudioTranscriptions"
                :disabled="!audioTranscriptionsAvailable"
              />
            </label>
          </div>
        </section>
      </div>
    </section>

    <div v-if="showSubmitButton">
      <Button
        :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
        @click="handleBasicInfoUpdate"
      />
    </div>
  </div>
</template>
