<script setup>
import { reactive, computed, watch, ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';

import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  WEB_SCRAPE_URL_TOOL_ID,
  WEB_SEARCH_TOOL_ID,
  buildDefaultAgentToolAccess,
  isToolEnabled,
  resolveAgentToolAccess,
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
  showCoreSettings: {
    type: Boolean,
    default: true,
  },
  showCapabilities: {
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

const emit = defineEmits(['submit', 'handoffCapabilityChange']);

const { t } = useI18n();

const initialState = {
  name: '',
  description: '',
  model: '',
  temperature: 1,
  autoReplyOnLastIncoming: false,
  messageCollapseWindowSeconds: 0,
  historyMessageLimit: 0,
  features: {
    conversationFaqs: false,
    memories: false,
    citations: false,
    documentReading: false,
    imageUnderstanding: false,
    useAudioTranscriptions: true,
  },
  contextAccess: {},
  toolAccess: buildDefaultAgentToolAccess(),
  avatarFile: null,
  avatarUrl: '',
  removeAvatar: false,
};

const state = reactive({ ...initialState });
const instructionEditorRef = ref(null);
const captainConfigStore = useCaptainConfigStore();
// Only the short list curated by the platform. A model the agent already has stays selectable and is marked as
// the current one; it is not offered to agents that do not use it.
const assistantModelOptions = computed(() => {
  const currentLabel = name =>
    `${name} (${t('CAPTAIN.ASSISTANTS.FORM.MODEL.CURRENT_MODEL')})`;
  const options = captainConfigStore
    .getModelsForFeature('assistant')
    .filter(model => !model.current_only || model.id === state.model)
    .map(model => {
      const name = model.display_name || model.id;
      return {
        value: model.id,
        label: model.current_only ? currentLabel(name) : name,
      };
    });

  if (state.model && !options.some(option => option.value === state.model)) {
    options.unshift({
      value: state.model,
      label: currentLabel(state.model),
    });
  }

  return options;
});
// Web search, page and document reading need the web provider that the platform administrator connects.
// An option that is already on stays switchable, so that it can still be turned off.
const isWebProviderConfigured = computed(
  () => captainConfigStore.runtimeMetadata?.web_access?.configured === true
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
      enabled
    );
    emit('handoffCapabilityChange', enabled);
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
      enabled
    );
  },
});

const webSearchEnabled = computed({
  get: () =>
    isToolEnabled(state.toolAccess, AGENT_TOOL_SCOPE, WEB_SEARCH_TOOL_ID),
  set: enabled => {
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      WEB_SEARCH_TOOL_ID,
      enabled
    );
  },
});

const webPageReadingEnabled = computed({
  get: () =>
    isToolEnabled(state.toolAccess, AGENT_TOOL_SCOPE, WEB_SCRAPE_URL_TOOL_ID),
  set: enabled => {
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      WEB_SCRAPE_URL_TOOL_ID,
      enabled
    );
  },
});

const audioTranscriptionsLabel = computed(() =>
  props.audioTranscriptionsAvailable
    ? t('CAPTAIN.ASSISTANTS.FORM.FEATURES.USE_AUDIO_TRANSCRIPTIONS')
    : t('CAPTAIN.ASSISTANTS.FORM.FEATURES.USE_AUDIO_TRANSCRIPTIONS_DISABLED')
);

const formattedTemperature = computed(() =>
  Number(state.temperature || 0).toFixed(1)
);
const temperatureOrDefault = value =>
  value === null || value === undefined || value === '' ? 1 : Number(value);
const normalizeNonNegativeInteger = value => {
  const normalizedValue = Number(value);
  return Number.isFinite(normalizedValue) && normalizedValue > 0
    ? Math.floor(normalizedValue)
    : 0;
};

const notesEnabled = computed({
  get: () =>
    isToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      ADD_CONTACT_NOTE_TOOL_ID
    ) &&
    isToolEnabled(state.toolAccess, AGENT_TOOL_SCOPE, ADD_PRIVATE_NOTE_TOOL_ID),
  set: enabled => {
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      ADD_CONTACT_NOTE_TOOL_ID,
      enabled
    );
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      ADD_PRIVATE_NOTE_TOOL_ID,
      enabled
    );
  },
});

const resolveInstructionText = assistant => {
  return assistant?.description?.trim?.() || '';
};

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.name = assistant.name;
  state.model = config.model || '';
  state.description = resolveInstructionText(assistant);
  state.temperature = temperatureOrDefault(config.temperature);
  state.autoReplyOnLastIncoming = Boolean(config.auto_reply_on_last_incoming);
  state.messageCollapseWindowSeconds = Number(
    config.message_collapse_window_seconds || 0
  );
  state.historyMessageLimit = Number(config.history_message_limit || 0);
  state.features = {
    conversationFaqs: config.feature_faq || false,
    memories: config.feature_memory || false,
    citations: config.feature_citation || false,
    documentReading: Object.prototype.hasOwnProperty.call(
      config,
      'feature_document_reading'
    )
      ? config.feature_document_reading !== false
      : true,
    imageUnderstanding: Object.prototype.hasOwnProperty.call(
      config,
      'feature_image_understanding'
    )
      ? config.feature_image_understanding !== false
      : true,
    useAudioTranscriptions: config.use_audio_transcriptions !== false,
  };
  state.contextAccess = {};
  state.toolAccess = resolveAgentToolAccess(config.tool_access || {});
  const hasAgentToolScope = Boolean(config.tool_access?.[AGENT_TOOL_SCOPE]);
  if (
    !hasAgentToolScope &&
    Object.prototype.hasOwnProperty.call(config, 'feature_web')
  ) {
    webSearchEnabled.value = config.feature_web === true;
    webPageReadingEnabled.value = config.feature_web === true;
  } else if (!hasAgentToolScope) {
    webSearchEnabled.value = true;
    webPageReadingEnabled.value = true;
  }
  // The server lets an explicit handoff_enabled=false win over the tool list: show what really happens.
  if (config.handoff_enabled === false) handoffToHumanEnabled.value = false;
  emit('handoffCapabilityChange', handoffToHumanEnabled.value);
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

  if (props.showFeatureFlags && props.showCoreSettings) {
    assistantPayload.config = {
      temperature: temperatureOrDefault(state.temperature),
      model: state.model || null,
      message_collapse_window_seconds: normalizeNonNegativeInteger(
        state.messageCollapseWindowSeconds
      ),
      history_message_limit: normalizeNonNegativeInteger(
        state.historyMessageLimit
      ),
    };
  }

  if (props.showFeatureFlags && props.showCapabilities) {
    assistantPayload.config = {
      ...(assistantPayload.config || {}),
      feature_faq: state.features.conversationFaqs,
      feature_memory: state.features.memories,
      feature_citation: state.features.citations,
      feature_web: webSearchEnabled.value && webPageReadingEnabled.value,
      tool_access: state.toolAccess,
      auto_reply_on_last_incoming: state.autoReplyOnLastIncoming,
      feature_document_reading: state.features.documentReading,
      feature_image_understanding: state.features.imageUnderstanding,
      handoff_enabled: handoffToHumanEnabled.value,
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

onMounted(async () => {
  await captainConfigStore.fetch();
  if (!state.model) {
    // A workspace model outside the curated list is not copied into the agent: choosing it anew is not allowed.
    const selectedModelId =
      captainConfigStore.getSelectedModelForFeature('assistant') || '';
    const isCurrentOnly = captainConfigStore
      .getModelsForFeature('assistant')
      .some(model => model.id === selectedModelId && model.current_only);
    state.model = isCurrentOnly ? '' : selectedModelId;
  }
});

watch(
  () => props.assistant,
  newAssistant => {
    if (newAssistant) updateStateFromAssistant(newAssistant);
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
      <div v-if="showNameField" class="flex flex-col gap-1">
        <Input
          v-model="state.name"
          :label="t('CAPTAIN.ASSISTANTS.FORM.NAME.LABEL')"
          :placeholder="t('CAPTAIN.ASSISTANTS.FORM.NAME.PLACEHOLDER')"
          :message="formErrors.name"
          :message-type="formErrors.name ? 'error' : 'info'"
        />
      </div>

      <section
        v-if="showFeatureFlags && showCoreSettings"
        class="flex flex-col gap-5"
      >
        <div class="flex flex-col gap-2">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.MODEL.LABEL') }}
          </label>
          <Select
            v-model="state.model"
            :options="assistantModelOptions"
            class="w-full"
          />
          <p class="m-0 text-xs text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.FORM.MODEL.DESCRIPTION') }}
          </p>
        </div>

        <div class="flex items-center justify-between gap-6">
          <div class="min-w-0">
            <label class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.TEMPERATURE.LABEL') }}
            </label>
            <p class="mt-1 text-xs text-n-slate-11">
              {{ t('CAPTAIN.ASSISTANTS.FORM.TEMPERATURE.DESCRIPTION') }}
            </p>
          </div>
          <div class="flex w-72 shrink-0 items-center gap-3">
            <input
              v-model.number="state.temperature"
              type="range"
              min="0"
              max="1"
              step="0.1"
              class="min-w-0 flex-1 cursor-pointer accent-n-brand"
            />
            <span
              class="inline-flex w-12 shrink-0 justify-center rounded-full bg-n-alpha-2 px-2 py-1 text-sm font-medium tabular-nums text-n-slate-12"
            >
              {{ formattedTemperature }}
            </span>
          </div>
        </div>

        <div class="flex items-center justify-between gap-6">
          <div class="min-w-0">
            <label class="text-sm font-medium text-n-slate-12">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.MESSAGE_COLLAPSE_WINDOW_SECONDS.LABEL'
                )
              }}
            </label>
            <p class="mt-1 text-xs text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.MESSAGE_COLLAPSE_WINDOW_SECONDS.DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Input
            v-model="state.messageCollapseWindowSeconds"
            type="number"
            min="0"
            :placeholder="
              t(
                'CAPTAIN.ASSISTANTS.FORM.MESSAGE_COLLAPSE_WINDOW_SECONDS.PLACEHOLDER'
              )
            "
            class="w-36 shrink-0"
          />
        </div>

        <div class="flex items-center justify-between gap-6">
          <div class="min-w-0">
            <label class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.HISTORY_MESSAGE_LIMIT.LABEL') }}
            </label>
            <p class="mt-1 text-xs text-n-slate-11">
              {{
                t('CAPTAIN.ASSISTANTS.FORM.HISTORY_MESSAGE_LIMIT.DESCRIPTION')
              }}
            </p>
          </div>
          <Input
            v-model="state.historyMessageLimit"
            type="number"
            min="0"
            :placeholder="
              t('CAPTAIN.ASSISTANTS.FORM.HISTORY_MESSAGE_LIMIT.PLACEHOLDER')
            "
            class="w-36 shrink-0"
          />
        </div>
      </section>

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
          :captain-tool-scope="AGENT_TOOL_SCOPE"
        />
      </div>
    </template>

    <section v-if="showFeatureFlags && showCapabilities">
      <div class="flex flex-col divide-y divide-n-weak">
        <label class="flex items-center justify-between gap-3 py-3 first:pt-0">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.AUTO_REPLY_ON_LAST_INCOMING.TITLE') }}
            <span class="block text-xs text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.AUTO_REPLY_ON_LAST_INCOMING.DESCRIPTION'
                )
              }}
            </span>
          </span>
          <Switch v-model="state.autoReplyOnLastIncoming" />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CONVERSATION_FAQS') }}
          </span>
          <Switch v-model="state.features.conversationFaqs" />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_MEMORIES') }}
          </span>
          <Switch v-model="state.features.memories" />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_NOTES') }}
          </span>
          <Switch v-model="notesEnabled" />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CITATIONS') }}
          </span>
          <Switch v-model="state.features.citations" />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_SEARCH') }}
            <span class="block text-xs text-n-slate-11">
              {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_SEARCH_DESCRIPTION') }}
            </span>
          </span>
          <Switch
            v-model="webSearchEnabled"
            :disabled="!isWebProviderConfigured && !webSearchEnabled"
          />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_PAGE_READING') }}
            <span class="block text-xs text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_PAGE_READING_DESCRIPTION'
                )
              }}
            </span>
          </span>
          <Switch
            v-model="webPageReadingEnabled"
            :disabled="!isWebProviderConfigured && !webPageReadingEnabled"
          />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.DOCUMENT_READING') }}
            <span class="block text-xs text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.FEATURES.DOCUMENT_READING_DESCRIPTION'
                )
              }}
            </span>
          </span>
          <Switch
            v-model="state.features.documentReading"
            :disabled="
              !isWebProviderConfigured && !state.features.documentReading
            "
          />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.IMAGE_UNDERSTANDING') }}
            <span class="block text-xs text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.FEATURES.IMAGE_UNDERSTANDING_DESCRIPTION'
                )
              }}
            </span>
          </span>
          <Switch v-model="state.features.imageUnderstanding" />
        </label>
        <p
          v-if="!isWebProviderConfigured"
          class="m-0 py-3 text-xs text-n-slate-11"
        >
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_PROVIDER_REQUIRED') }}
        </p>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ audioTranscriptionsLabel }}
          </span>
          <Switch
            v-model="state.features.useAudioTranscriptions"
            :disabled="!audioTranscriptionsAvailable"
          />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_FAQ_LOOKUP') }}
          </span>
          <Switch v-model="faqLookupEnabled" />
        </label>
        <label class="flex items-center justify-between gap-3 py-3">
          <span class="text-sm text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_HUMAN_HANDOFF') }}
          </span>
          <Switch v-model="handoffToHumanEnabled" />
        </label>
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
