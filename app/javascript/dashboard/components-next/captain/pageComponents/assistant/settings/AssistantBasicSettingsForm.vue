<script setup>
import { reactive, computed, watch, ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { storeToRefs } from 'pinia';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';

import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
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
});

const emit = defineEmits(['submit']);

const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();
const { runtimeMetadata } = storeToRefs(captainConfigStore);

const initialState = {
  name: '',
  description: '',
  usageMode: 'external_agent',
  model: '',
  temperature: 1,
  autoReplyOnLastIncoming: false,
  messageCollapseWindowSeconds: 0,
  historyMessageLimit: 0,
  features: {
    conversationFaqs: false,
    memories: false,
    citations: false,
    web: false,
    documentReading: false,
    imageUnderstanding: false,
  },
  contextAccess: {},
  toolAccess: buildDefaultToolAccessForUsageMode(),
  avatarFile: null,
  avatarUrl: '',
  removeAvatar: false,
};

const state = reactive({ ...initialState });
const instructionEditorRef = ref(null);
const activeToolScope = AGENT_TOOL_SCOPE;
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

const webSearchEnabled = computed({
  get: () =>
    isToolEnabled(state.toolAccess, AGENT_TOOL_SCOPE, WEB_SEARCH_TOOL_ID),
  set: enabled => {
    state.toolAccess = setToolEnabled(
      state.toolAccess,
      AGENT_TOOL_SCOPE,
      WEB_SEARCH_TOOL_ID,
      enabled,
      state.usageMode
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
      enabled,
      state.usageMode
    );
  },
});

const isFirecrawlConfigured = computed(
  () => runtimeMetadata.value?.web_access?.configured === true
);

const assistantModelOptions = computed(() =>
  captainConfigStore.getModelsForFeature('assistant').map(model => ({
    value: model.id,
    label: model.display_name || model.id,
  }))
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

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.name = assistant.name;
  state.description = resolveInstructionText(assistant);
  state.usageMode = 'external_agent';
  state.model = config.model || '';
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
    web: config.feature_web || false,
    documentReading: config.feature_document_reading || false,
    imageUnderstanding: config.feature_image_understanding || false,
  };
  state.contextAccess = {};
  state.toolAccess = resolveToolAccessForUsageMode(
    config.tool_access || {},
    state.usageMode
  );
  if (state.features.web) {
    webSearchEnabled.value = true;
    webPageReadingEnabled.value = true;
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

  if (props.showFeatureFlags && props.showCoreSettings) {
    assistantPayload.config = {
      model: state.model,
      temperature: temperatureOrDefault(state.temperature),
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
      auto_reply_on_last_incoming: state.autoReplyOnLastIncoming,
      feature_faq: state.features.conversationFaqs,
      feature_memory: state.features.memories,
      feature_citation: state.features.citations,
      feature_web: webSearchEnabled.value && webPageReadingEnabled.value,
      feature_document_reading: state.features.documentReading,
      feature_image_understanding: state.features.imageUnderstanding,
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
  },
  { immediate: true }
);

onMounted(async () => {
  await captainConfigStore.fetch();
  if (!state.model) {
    state.model =
      captainConfigStore.getSelectedModelForFeature('assistant') || '';
  }
});

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
              class="captain-temperature-slider min-w-0 flex-1"
            />
            <span
              class="inline-flex w-12 shrink-0 justify-center rounded-full bg-n-alpha-2 px-2 py-1 text-sm font-medium tabular-nums text-n-violet-11"
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
          :captain-tool-scope="activeToolScope"
        />
      </div>
    </template>

    <section v-if="showFeatureFlags && showCapabilities">
      <div class="capability-list flex flex-col divide-y divide-n-weak/50">
        <label class="flex items-center justify-between gap-3">
          <span>
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
        <label class="flex items-center justify-between gap-3">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CONVERSATION_FAQS') }}
          <Switch v-model="state.features.conversationFaqs" />
        </label>
        <label class="flex items-center justify-between gap-3">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_MEMORIES') }}
          <Switch v-model="state.features.memories" />
        </label>
        <label class="flex items-center justify-between gap-3">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_NOTES') }}
          <Switch v-model="notesEnabled" />
        </label>
        <label class="flex items-center justify-between gap-3">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_CITATIONS') }}
          <Switch v-model="state.features.citations" />
        </label>
        <label class="flex items-center justify-between gap-3">
          <span>
            {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_SEARCH') }}
            <span class="block text-xs text-n-slate-11">
              {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_SEARCH_DESCRIPTION') }}
            </span>
          </span>
          <Switch
            v-model="webSearchEnabled"
            :disabled="!isFirecrawlConfigured"
          />
        </label>
        <label class="flex items-center justify-between gap-3">
          <span>
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
            :disabled="!isFirecrawlConfigured"
          />
        </label>
        <label class="flex items-center justify-between gap-3">
          <span>
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
        <label class="flex items-center justify-between gap-3">
          <span>
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
            :disabled="!isFirecrawlConfigured"
          />
        </label>
        <div v-if="!isFirecrawlConfigured" class="text-xs text-n-amber-11">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.WEB_PROVIDER_REQUIRED') }}
        </div>
        <label class="flex items-center justify-between gap-3">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_FAQ_LOOKUP') }}
          <Switch v-model="faqLookupEnabled" />
        </label>
        <label class="flex items-center justify-between gap-3">
          {{ t('CAPTAIN.ASSISTANTS.FORM.FEATURES.ALLOW_HUMAN_HANDOFF') }}
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

<style scoped>
.capability-list > label {
  padding-block: 0.75rem;
}

.capability-list > label:not(:first-of-type) {
  border-top: 1px solid color-mix(in srgb, currentColor 8%, transparent);
}

.captain-temperature-slider {
  cursor: pointer;
  accent-color: rgb(124 58 237);
}
</style>
