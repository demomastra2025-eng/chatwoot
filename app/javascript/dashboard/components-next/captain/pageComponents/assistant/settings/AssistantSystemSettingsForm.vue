<script setup>
import { reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { minLength } from '@vuelidate/validators';

import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SettingsInfoDialog from './SettingsInfoDialog.vue';

const props = defineProps({
  assistant: {
    type: Object,
    default: () => ({}),
  },
  showConversationMessages: {
    type: Boolean,
    default: true,
  },
  showTemperatureSetting: {
    type: Boolean,
    default: true,
  },
  showAutomationSettings: {
    type: Boolean,
    default: true,
  },
  showVoiceSettings: {
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

const DEFAULT_VOICE_SETTINGS = {
  provider: 'gemini-live',
  model: 'gemini-3.1-flash-live-preview',
  voice: 'sulafat',
  language: 'auto',
  thinkingLevel: 'minimal',
  contextWindowCompressionEnabled: true,
  systemPrompt: '',
  voiceCharacterPrompt: '',
  firstMessage: '',
  transferMessage: '',
  maxDurationSec: 0,
  interruptionsEnabled: true,
  proactiveAudioEnabled: false,
  affectiveDialogEnabled: false,
};

const GEMINI_AFFECTIVE_DIALOG_MODELS = new Set([
  'gemini-2.5-flash-native-audio-preview-12-2025',
]);
const GEMINI_AUTO_LANGUAGE_MODELS = new Set([
  'gemini-3.1-flash-live-preview',
  'gemini-2.5-flash-native-audio-preview-12-2025',
]);
const GEMINI_THINKING_LEVEL_MODELS = new Set(['gemini-3.1-flash-live-preview']);
const GEMINI_PROACTIVE_AUDIO_MODELS = GEMINI_AUTO_LANGUAGE_MODELS;

const VOICE_PROVIDER_OPTIONS = Object.freeze([
  { value: 'gemini-live', label: 'Gemini Live' },
  { value: 'openai-realtime', label: 'OpenAI Realtime' },
  { value: 'elevenlabs', label: 'ElevenLabs + OpenRouter' },
  { value: 'cartesia', label: 'Cartesia + OpenRouter' },
]);

const VOICE_PROVIDER_PRESETS = Object.freeze({
  'gemini-live': {
    model: 'gemini-3.1-flash-live-preview',
    voice: 'sulafat',
    language: 'auto',
    models: [
      {
        value: 'gemini-3.1-flash-live-preview',
        label: 'Gemini 3.1 Flash Live Preview',
      },
      {
        value: 'gemini-2.5-flash-native-audio-preview-12-2025',
        label: 'Gemini 2.5 Native Audio',
      },
      { value: 'gemini-2.0-flash-live-001', label: 'Gemini 2.0 Flash Live' },
    ],
    voices: [
      { value: 'sulafat', label: 'Sulafat' },
      { value: 'aoede', label: 'Aoede' },
      { value: 'charon', label: 'Charon' },
      { value: 'fenrir', label: 'Fenrir' },
      { value: 'kore', label: 'Kore' },
      { value: 'puck', label: 'Puck' },
    ],
  },
  'openai-realtime': {
    model: 'gpt-realtime-2',
    voice: 'alloy',
    language: 'ru-KZ',
    models: [
      { value: 'gpt-realtime-2', label: 'GPT Realtime 2' },
      { value: 'gpt-4o-realtime-preview', label: 'GPT-4o Realtime Preview' },
    ],
    voices: [
      { value: 'alloy', label: 'Alloy' },
      { value: 'coral', label: 'Coral' },
      { value: 'sage', label: 'Sage' },
      { value: 'shimmer', label: 'Shimmer' },
      { value: 'verse', label: 'Verse' },
    ],
  },
  elevenlabs: {
    model: 'openai/gpt-5.4-mini',
    voice: 'Xb7hH8MSUJpSbSDYk0k2',
    language: 'ru-KZ',
    models: [
      { value: 'openai/gpt-5.4-mini', label: 'GPT-5.4 Mini (OpenRouter)' },
      { value: 'openai/gpt-5.4', label: 'GPT-5.4 (OpenRouter)' },
    ],
    voices: [{ value: 'Xb7hH8MSUJpSbSDYk0k2', label: 'ElevenLabs default' }],
  },
  cartesia: {
    model: 'openai/gpt-5.4-mini',
    voice: '71a7ad14-091c-4e8e-a314-022ece01c121',
    language: 'ru-KZ',
    models: [
      { value: 'openai/gpt-5.4-mini', label: 'GPT-5.4 Mini (OpenRouter)' },
      { value: 'openai/gpt-5.4', label: 'GPT-5.4 (OpenRouter)' },
    ],
    voices: [
      {
        value: '71a7ad14-091c-4e8e-a314-022ece01c121',
        label: 'Cartesia multilingual',
      },
    ],
  },
});

const VOICE_LANGUAGE_OPTIONS = Object.freeze([
  { value: 'ru-KZ', label: 'Русский (Казахстан)' },
  { value: 'ru-RU', label: 'Русский' },
  { value: 'kk-KZ', label: 'Қазақша' },
  { value: 'en-US', label: 'English' },
]);

const initialState = {
  handoffMessageEnabled: false,
  resolutionMessageEnabled: false,
  handoffMessage: '',
  resolutionMessage: '',
  temperature: 1,
  autoReplyOnLastIncoming: false,
  messageCollapseWindowSeconds: 0,
  historyMessageLimit: 0,
  voiceSettings: { ...DEFAULT_VOICE_SETTINGS },
};

const state = reactive({ ...initialState });

const isGeminiLive = computed(
  () => state.voiceSettings.provider === 'gemini-live'
);
const isAffectiveDialogSupported = computed(
  () =>
    isGeminiLive.value &&
    GEMINI_AFFECTIVE_DIALOG_MODELS.has(state.voiceSettings.model)
);
const supportsGeminiAutoLanguage = (provider, model) =>
  provider === 'gemini-live' && GEMINI_AUTO_LANGUAGE_MODELS.has(model);
const isGeminiAutoLanguageSupported = computed(() =>
  supportsGeminiAutoLanguage(
    state.voiceSettings.provider,
    state.voiceSettings.model
  )
);
const isGeminiThinkingSupported = computed(
  () =>
    isGeminiLive.value &&
    GEMINI_THINKING_LEVEL_MODELS.has(state.voiceSettings.model)
);
const supportsGeminiProactiveAudio = (provider, model) =>
  provider === 'gemini-live' && GEMINI_PROACTIVE_AUDIO_MODELS.has(model);
const isGeminiProactiveAudioSupported = computed(() =>
  supportsGeminiProactiveAudio(
    state.voiceSettings.provider,
    state.voiceSettings.model
  )
);

const validationRules = computed(() => ({
  handoffMessage: state.handoffMessageEnabled
    ? { minLength: minLength(1) }
    : {},
  resolutionMessage: state.resolutionMessageEnabled
    ? { minLength: minLength(1) }
    : {},
}));

const v$ = useVuelidate(validationRules, state);

const getErrorMessage = field => {
  return v$.value[field].$error ? v$.value[field].$errors[0].$message : '';
};

const formErrors = computed(() => ({
  handoffMessage: getErrorMessage('handoffMessage'),
  resolutionMessage: getErrorMessage('resolutionMessage'),
}));

const temperaturePercent = computed(() => Number(state.temperature || 0) * 100);

const formattedTemperature = computed(() =>
  Number(state.temperature || 0).toFixed(1)
);
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

const temperatureMinLabel = '0.0';
const temperatureMaxLabel = '1.0';
const optionLabel = (options, value) =>
  options.find(option => option.value === value)?.label || value;

const optionsWithCurrentValue = (options, value) => {
  if (!value || options.some(option => option.value === value)) {
    return options;
  }

  return [{ value, label: value }, ...options];
};

const voiceProviderOptions = computed(() =>
  optionsWithCurrentValue(VOICE_PROVIDER_OPTIONS, state.voiceSettings.provider)
);
const voiceProviderPreset = computed(
  () =>
    VOICE_PROVIDER_PRESETS[state.voiceSettings.provider] ||
    VOICE_PROVIDER_PRESETS['gemini-live']
);
const voiceModelOptions = computed(() =>
  optionsWithCurrentValue(
    voiceProviderPreset.value.models,
    state.voiceSettings.model
  )
);
const voiceVoiceOptions = computed(() =>
  optionsWithCurrentValue(
    voiceProviderPreset.value.voices,
    state.voiceSettings.voice
  )
);
const voiceLanguageOptions = computed(() => {
  const options = isGeminiAutoLanguageSupported.value
    ? [
        {
          value: 'auto',
          label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.LANGUAGE_AUTO'),
        },
        ...VOICE_LANGUAGE_OPTIONS,
      ]
    : VOICE_LANGUAGE_OPTIONS;
  return optionsWithCurrentValue(options, state.voiceSettings.language);
});
const voiceThinkingLevelOptions = computed(() => [
  {
    value: 'minimal',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.THINKING_MINIMAL'),
  },
  {
    value: 'low',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.THINKING_LOW'),
  },
  {
    value: 'medium',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.THINKING_MEDIUM'),
  },
  {
    value: 'high',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.THINKING_HIGH'),
  },
]);

const voiceSettingsSummary = computed(
  () =>
    `${optionLabel(voiceModelOptions.value, state.voiceSettings.model)} / ${optionLabel(
      voiceVoiceOptions.value,
      state.voiceSettings.voice
    )}`
);

const updateVoiceProvider = provider => {
  const preset = VOICE_PROVIDER_PRESETS[provider];
  if (!preset) return;

  state.voiceSettings.provider = provider;
  state.voiceSettings.model = preset.model;
  state.voiceSettings.voice = preset.voice;
  state.voiceSettings.language = preset.language;
};

watch(
  () => [state.voiceSettings.provider, state.voiceSettings.model],
  ([provider, model]) => {
    if (
      state.voiceSettings.language === 'auto' &&
      !supportsGeminiAutoLanguage(provider, model)
    ) {
      state.voiceSettings.language = 'ru-KZ';
    }
    if (
      state.voiceSettings.proactiveAudioEnabled &&
      !supportsGeminiProactiveAudio(provider, model)
    ) {
      state.voiceSettings.proactiveAudioEnabled = false;
    }
  }
);

const temperatureOrDefault = value => {
  if (value === null || value === undefined || value === '') return 1;

  return value;
};

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.handoffMessageEnabled = Boolean(config.handoff_message);
  state.resolutionMessageEnabled = Boolean(config.resolution_message);
  state.handoffMessage = config.handoff_message;
  state.resolutionMessage = config.resolution_message;
  state.temperature = temperatureOrDefault(config.temperature);
  state.autoReplyOnLastIncoming = config.auto_reply_on_last_incoming || false;
  state.messageCollapseWindowSeconds = Number(
    config.message_collapse_window_seconds || 0
  );
  state.historyMessageLimit = Number(config.history_message_limit || 0);

  const voiceSettings = config.voice_settings || {};
  const provider = voiceSettings.provider || DEFAULT_VOICE_SETTINGS.provider;
  const providerPreset =
    VOICE_PROVIDER_PRESETS[provider] || VOICE_PROVIDER_PRESETS['gemini-live'];
  const model = voiceSettings.model || providerPreset.model;
  const savedLanguage = voiceSettings.language || providerPreset.language;
  state.voiceSettings = {
    provider,
    model,
    voice: voiceSettings.voice || providerPreset.voice,
    language:
      savedLanguage === 'auto' && !supportsGeminiAutoLanguage(provider, model)
        ? 'ru-KZ'
        : savedLanguage,
    thinkingLevel:
      voiceSettings.thinking_level ?? DEFAULT_VOICE_SETTINGS.thinkingLevel,
    contextWindowCompressionEnabled:
      voiceSettings.context_window_compression_enabled ??
      DEFAULT_VOICE_SETTINGS.contextWindowCompressionEnabled,
    systemPrompt:
      voiceSettings.system_prompt ?? DEFAULT_VOICE_SETTINGS.systemPrompt,
    voiceCharacterPrompt:
      voiceSettings.voice_character_prompt ??
      DEFAULT_VOICE_SETTINGS.voiceCharacterPrompt,
    firstMessage:
      voiceSettings.first_message ?? DEFAULT_VOICE_SETTINGS.firstMessage,
    transferMessage:
      voiceSettings.transfer_message ?? DEFAULT_VOICE_SETTINGS.transferMessage,
    maxDurationSec: Number(
      voiceSettings.max_duration_sec || DEFAULT_VOICE_SETTINGS.maxDurationSec
    ),
    interruptionsEnabled:
      voiceSettings.interruptions_enabled ??
      DEFAULT_VOICE_SETTINGS.interruptionsEnabled,
    proactiveAudioEnabled: Boolean(
      supportsGeminiProactiveAudio(provider, model) &&
        (voiceSettings.proactive_audio_enabled ??
          DEFAULT_VOICE_SETTINGS.proactiveAudioEnabled)
    ),
    affectiveDialogEnabled:
      voiceSettings.affective_dialog_enabled ??
      DEFAULT_VOICE_SETTINGS.affectiveDialogEnabled,
  };
};

const normalizeNonNegativeInteger = value => {
  const normalizedValue = Number(value);
  if (!Number.isFinite(normalizedValue) || normalizedValue <= 0) {
    return 0;
  }

  return Math.floor(normalizedValue);
};

const buildPayload = async () => {
  const validations = [
    v$.value.handoffMessage.$validate(),
    v$.value.resolutionMessage.$validate(),
  ];

  const result = await Promise.all(validations).then(results =>
    results.every(Boolean)
  );
  if (!result) return null;

  return {
    assistant: {
      config: {
        handoff_message: state.handoffMessageEnabled
          ? state.handoffMessage
          : '',
        resolution_message: state.resolutionMessageEnabled
          ? state.resolutionMessage
          : '',
        temperature: temperatureOrDefault(state.temperature),
        auto_reply_on_last_incoming: state.autoReplyOnLastIncoming,
        message_collapse_window_seconds: normalizeNonNegativeInteger(
          state.messageCollapseWindowSeconds
        ),
        history_message_limit: normalizeNonNegativeInteger(
          state.historyMessageLimit
        ),
        voice_settings: {
          provider:
            state.voiceSettings.provider || DEFAULT_VOICE_SETTINGS.provider,
          model: state.voiceSettings.model || DEFAULT_VOICE_SETTINGS.model,
          voice: state.voiceSettings.voice || DEFAULT_VOICE_SETTINGS.voice,
          language:
            state.voiceSettings.language === 'auto' &&
            !isGeminiAutoLanguageSupported.value
              ? 'ru-KZ'
              : state.voiceSettings.language || DEFAULT_VOICE_SETTINGS.language,
          thinking_level:
            state.voiceSettings.thinkingLevel ||
            DEFAULT_VOICE_SETTINGS.thinkingLevel,
          context_window_compression_enabled: Boolean(
            state.voiceSettings.contextWindowCompressionEnabled
          ),
          system_prompt: state.voiceSettings.systemPrompt || '',
          voice_character_prompt:
            state.voiceSettings.voiceCharacterPrompt || '',
          first_message: state.voiceSettings.firstMessage || '',
          transfer_message: state.voiceSettings.transferMessage || '',
          max_duration_sec: normalizeNonNegativeInteger(
            state.voiceSettings.maxDurationSec
          ),
          interruptions_enabled: Boolean(
            state.voiceSettings.interruptionsEnabled
          ),
          proactive_audio_enabled: Boolean(
            isGeminiProactiveAudioSupported.value &&
              state.voiceSettings.proactiveAudioEnabled
          ),
          affective_dialog_enabled: Boolean(
            isAffectiveDialogSupported.value &&
              state.voiceSettings.affectiveDialogEnabled
          ),
        },
      },
    },
    avatar: null,
    removeAvatar: false,
  };
};

const handleSystemMessagesUpdate = async () => {
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

defineExpose({
  buildPayload,
});
</script>

<template>
  <div class="flex flex-col gap-6">
    <template v-if="showConversationMessages">
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
          <div class="flex items-center gap-3">
            <Switch
              v-model="state.handoffMessageEnabled"
              class="data-[state=checked]:!bg-n-violet-9"
            />
          </div>
        </div>

        <Editor
          v-if="state.handoffMessageEnabled"
          v-model="state.handoffMessage"
          override-line-breaks
          auto-height
          :editor-key="`captain:assistant:${assistant?.id || 'new'}:system-handoff-message`"
          :placeholder="
            t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.PLACEHOLDER')
          "
          :message="formErrors.handoffMessage"
          :message-type="formErrors.handoffMessage ? 'error' : 'info'"
          :show-character-count="false"
          class="z-0 compact-system-message-editor"
          enable-captain-fields
          :captain-context-assistant-id="assistant.id"
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
              :title="
                t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.INFO_TITLE')
              "
              :description="
                t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.INFO_DESCRIPTION')
              "
              :points="resolutionInfoPoints"
              align="left"
            />
          </div>
          <div class="flex items-center gap-3">
            <Switch
              v-model="state.resolutionMessageEnabled"
              class="data-[state=checked]:!bg-n-violet-9"
            />
          </div>
        </div>

        <Editor
          v-if="state.resolutionMessageEnabled"
          v-model="state.resolutionMessage"
          override-line-breaks
          auto-height
          :editor-key="`captain:assistant:${assistant?.id || 'new'}:system-resolution-message`"
          :placeholder="
            t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.PLACEHOLDER')
          "
          :message="formErrors.resolutionMessage"
          :message-type="formErrors.resolutionMessage ? 'error' : 'info'"
          :show-character-count="false"
          class="z-0 compact-system-message-editor"
          enable-captain-fields
          :captain-context-assistant-id="assistant.id"
        />
      </div>
    </template>

    <template v-if="showTemperatureSetting || showAutomationSettings">
      <div
        class="grid grid-cols-1 gap-4"
        :class="{
          'xl:grid-cols-[minmax(0,1.3fr)_minmax(18rem,0.9fr)]':
            showTemperatureSetting && showAutomationSettings,
        }"
      >
        <div
          v-if="showTemperatureSetting"
          class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <label class="text-sm font-medium text-n-slate-12">
                {{ t('CAPTAIN.ASSISTANTS.FORM.TEMPERATURE.LABEL') }}
              </label>
              <p class="mt-1 text-sm text-n-slate-11 italic">
                {{ t('CAPTAIN.ASSISTANTS.FORM.TEMPERATURE.DESCRIPTION') }}
              </p>
            </div>
            <span
              class="inline-flex shrink-0 items-center rounded-full bg-n-alpha-2 px-3 py-1 text-sm font-medium tabular-nums text-n-violet-11"
            >
              {{ formattedTemperature }}
            </span>
          </div>

          <div class="mt-4">
            <div class="relative flex h-5 items-center">
              <div
                class="absolute inset-x-0 h-2 rounded-full bg-n-alpha-black2"
              />
              <div
                class="absolute left-0 h-2 rounded-full bg-n-violet-9"
                :style="{ width: `${temperaturePercent}%` }"
              />
              <input
                v-model.number="state.temperature"
                type="range"
                min="0"
                max="1"
                step="0.1"
                class="captain-temperature-slider text-n-violet-9"
              />
            </div>
            <div
              class="mt-2 flex items-center justify-between text-xs text-n-slate-10"
            >
              <span>{{ temperatureMinLabel }}</span>
              <span>{{ temperatureMaxLabel }}</span>
            </div>
          </div>
        </div>

        <div
          v-if="showAutomationSettings"
          class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex items-center justify-between gap-4"
        >
          <div class="flex-1 min-w-0">
            <h4 class="text-sm font-medium text-n-slate-12">
              {{
                t('CAPTAIN.ASSISTANTS.FORM.AUTO_REPLY_ON_LAST_INCOMING.TITLE')
              }}
            </h4>
            <p class="text-sm text-n-slate-11 mt-0.5">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.AUTO_REPLY_ON_LAST_INCOMING.DESCRIPTION'
                )
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
      </div>

      <div
        v-if="showAutomationSettings"
        class="grid grid-cols-1 gap-4 md:grid-cols-2"
      >
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
    </template>

    <details
      v-if="showVoiceSettings"
      open
      data-test-id="assistant-voice-settings"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <summary class="cursor-pointer list-none">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h4 class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TITLE') }}
            </h4>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.DESCRIPTION') }}
            </p>
          </div>
          <span class="text-xs font-medium text-n-slate-10">
            {{ voiceSettingsSummary }}
          </span>
        </div>
      </summary>

      <div class="mt-4 rounded-lg border border-n-weak bg-n-alpha-1 p-3">
        <div class="flex items-center gap-2">
          <i class="i-lucide-phone-call h-4 w-4 text-n-slate-10" />
          <h5 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.ACTIVE_RUNTIME') }}
          </h5>
        </div>
        <div class="mt-3 flex flex-wrap gap-2">
          <span
            class="rounded-full border border-n-weak bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
          >
            {{
              optionLabel(voiceProviderOptions, state.voiceSettings.provider)
            }}
          </span>
          <span
            class="rounded-full border border-n-weak bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
          >
            {{ optionLabel(voiceModelOptions, state.voiceSettings.model) }}
          </span>
          <span
            class="rounded-full border border-n-weak bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
          >
            {{
              optionLabel(voiceLanguageOptions, state.voiceSettings.language)
            }}
          </span>
        </div>
        <p class="mt-3 text-sm text-n-slate-11">
          {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.RUNTIME_NOTE') }}
        </p>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
        <div class="flex flex-col gap-1.5">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.PROVIDER') }}
          </label>
          <Select
            :model-value="state.voiceSettings.provider"
            :options="voiceProviderOptions"
            class="w-full"
            @update:model-value="updateVoiceProvider"
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.MODEL') }}
          </label>
          <Select
            v-model="state.voiceSettings.model"
            :options="voiceModelOptions"
            class="w-full"
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE') }}
          </label>
          <Select
            v-model="state.voiceSettings.voice"
            :options="voiceVoiceOptions"
            class="w-full"
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.LANGUAGE') }}
          </label>
          <Select
            v-model="state.voiceSettings.language"
            :options="voiceLanguageOptions"
            class="w-full"
          />
        </div>
        <div
          v-if="isGeminiThinkingSupported"
          data-test-id="assistant-gemini-thinking-level"
          class="flex flex-col gap-1.5"
        >
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.THINKING_LEVEL') }}
          </label>
          <Select
            v-model="state.voiceSettings.thinkingLevel"
            :options="voiceThinkingLevelOptions"
            class="w-full"
          />
          <p class="text-sm text-n-slate-11">
            {{
              t(
                'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.THINKING_LEVEL_DESCRIPTION'
              )
            }}
          </p>
        </div>
        <div
          data-test-id="assistant-voice-system-prompt"
          class="md:col-span-2 flex flex-col gap-2"
        >
          <div>
            <h5 class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SYSTEM_PROMPT') }}
            </h5>
            <p class="mt-1 text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SYSTEM_PROMPT_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Editor
            v-model="state.voiceSettings.systemPrompt"
            override-line-breaks
            auto-height
            :editor-key="`captain:assistant:${assistant?.id || 'new'}:voice-system-prompt`"
            :placeholder="
              t(
                'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SYSTEM_PROMPT_PLACEHOLDER'
              )
            "
            :show-character-count="false"
            class="z-0 compact-system-message-editor"
            enable-captain-fields
            :captain-context-assistant-id="assistant.id"
          />
        </div>
        <div
          data-test-id="assistant-voice-character-prompt"
          class="md:col-span-2 flex flex-col gap-2"
        >
          <div>
            <h5 class="text-sm font-medium text-n-slate-12">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_CHARACTER_PROMPT'
                )
              }}
            </h5>
            <p class="mt-1 text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_CHARACTER_PROMPT_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Editor
            v-model="state.voiceSettings.voiceCharacterPrompt"
            override-line-breaks
            auto-height
            :editor-key="`captain:assistant:${assistant?.id || 'new'}:voice-character-prompt`"
            :placeholder="
              t(
                'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_CHARACTER_PROMPT_PLACEHOLDER'
              )
            "
            :show-character-count="false"
            class="z-0 compact-system-message-editor"
            enable-captain-fields
            :captain-context-assistant-id="assistant.id"
          />
        </div>
        <Input
          v-model="state.voiceSettings.firstMessage"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FIRST_MESSAGE')"
          :placeholder="
            t(
              'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FIRST_MESSAGE_PLACEHOLDER'
            )
          "
        />
        <Input
          v-model="state.voiceSettings.transferMessage"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_MESSAGE')"
          :placeholder="
            t(
              'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_MESSAGE_PLACEHOLDER'
            )
          "
        />
        <Input
          v-model="state.voiceSettings.maxDurationSec"
          type="number"
          min="0"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.MAX_DURATION_SEC')"
          placeholder="900"
        />
        <div
          class="rounded-lg border border-n-weak p-3 flex items-center justify-between gap-4"
        >
          <div class="min-w-0">
            <h5 class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.INTERRUPTIONS') }}
            </h5>
            <p class="text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.INTERRUPTIONS_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Switch
            v-model="state.voiceSettings.interruptionsEnabled"
            class="data-[state=checked]:!bg-n-violet-9"
          />
        </div>
        <div
          v-if="isGeminiLive"
          data-test-id="assistant-gemini-context-compression"
          class="rounded-lg border border-n-weak p-3 flex items-center justify-between gap-4"
        >
          <div class="min-w-0">
            <h5 class="text-sm font-medium text-n-slate-12">
              {{
                t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.CONTEXT_COMPRESSION')
              }}
            </h5>
            <p class="text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.CONTEXT_COMPRESSION_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Switch
            v-model="state.voiceSettings.contextWindowCompressionEnabled"
            class="data-[state=checked]:!bg-n-violet-9"
          />
        </div>
        <div
          v-if="isGeminiProactiveAudioSupported"
          data-test-id="assistant-gemini-proactive-audio"
          class="rounded-lg border border-n-weak p-3 flex items-center justify-between gap-4"
        >
          <div class="min-w-0">
            <h5 class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.PROACTIVE_AUDIO') }}
            </h5>
            <p class="text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.PROACTIVE_AUDIO_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Switch
            v-model="state.voiceSettings.proactiveAudioEnabled"
            class="data-[state=checked]:!bg-n-violet-9"
          />
        </div>
        <div
          v-if="isAffectiveDialogSupported"
          data-test-id="assistant-gemini-affective-dialog"
          class="rounded-lg border border-n-weak p-3 flex items-center justify-between gap-4"
        >
          <div class="min-w-0">
            <h5 class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.AFFECTIVE_DIALOG') }}
            </h5>
            <p class="text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.AFFECTIVE_DIALOG_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Switch
            v-model="state.voiceSettings.affectiveDialogEnabled"
            class="data-[state=checked]:!bg-n-violet-9"
          />
        </div>
      </div>
    </details>

    <div v-if="showSubmitButton">
      <Button
        :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
        @click="handleSystemMessagesUpdate"
      />
    </div>
  </div>
</template>

<style scoped>
.captain-temperature-slider {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  height: 1.25rem;
  cursor: pointer;
  background: transparent;
  outline: none;
}

.captain-temperature-slider::-webkit-slider-runnable-track {
  height: 1.25rem;
  background: transparent;
}

.captain-temperature-slider::-moz-range-track {
  height: 1.25rem;
  background: transparent;
}

.captain-temperature-slider::-webkit-slider-thumb {
  -webkit-appearance: none;
  appearance: none;
  margin-top: 0;
  width: 1.125rem;
  height: 1.125rem;
  border: 2px solid rgba(255, 255, 255, 0.92);
  border-radius: 9999px;
  background: currentColor;
  box-shadow: 0 1px 4px rgba(15, 23, 42, 0.18);
}

.captain-temperature-slider::-moz-range-thumb {
  width: 1.125rem;
  height: 1.125rem;
  border: 2px solid rgba(255, 255, 255, 0.92);
  border-radius: 9999px;
  background: currentColor;
  box-shadow: 0 1px 4px rgba(15, 23, 42, 0.18);
}

.captain-temperature-slider:focus-visible::-webkit-slider-thumb {
  box-shadow:
    0 0 0 3px color-mix(in srgb, currentColor 22%, transparent),
    0 1px 4px rgba(15, 23, 42, 0.18);
}

.captain-temperature-slider:focus-visible::-moz-range-thumb {
  box-shadow:
    0 0 0 3px color-mix(in srgb, currentColor 22%, transparent),
    0 1px 4px rgba(15, 23, 42, 0.18);
}

.compact-system-message-editor {
  ::v-deep(.editor-wrapper) {
    padding-top: 0.625rem;
    padding-bottom: 0.625rem;
  }

  ::v-deep(.ProseMirror-menubar) {
    margin-bottom: 0.25rem;
  }

  ::v-deep(.ProseMirror.ProseMirror-woot-style) {
    min-height: 1.5rem;
  }
}
</style>
