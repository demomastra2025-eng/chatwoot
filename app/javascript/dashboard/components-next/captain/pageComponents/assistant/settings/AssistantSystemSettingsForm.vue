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
  language: 'auto',
  inputLanguagePriorities: ['ru-KZ', 'kk-KZ', 'en-US'],
  maxSentences: 2,
  systemPrompt: '',
  voiceCharacterPrompt: '',
  firstMessage: '',
  closingMessage: 'Спасибо за звонок. Хорошего дня!',
  managerHandoffMode: 'live_transfer',
  callbackMessage: '',
  transferMessage: '',
  transferFailureMode: 'continue',
  transferFailureMessage: '',
  silencePromptEnabled: true,
  silencePromptAfterSeconds: 5,
  silencePrompt: '',
  secondSilencePromptAfterSeconds: 12,
  secondSilencePrompt: '',
  maxSilenceSeconds: 25,
  finalSilenceMessage: '',
  endCallOnSilenceEnabled: true,
  maxDurationSec: 0,
  interruptionsEnabled: true,
  voiceActivityProfile: 'balanced',
};

const VOICE_ACTIVITY_PROFILES = new Set(['sensitive', 'balanced', 'noisy']);

const normalizeVoiceActivityProfile = value =>
  VOICE_ACTIVITY_PROFILES.has(value) ? value : 'balanced';

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
  voiceSettings: { ...DEFAULT_VOICE_SETTINGS },
};

const state = reactive({ ...initialState });

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

const optionLabel = (options, value) =>
  options.find(option => option.value === value)?.label || value;

const optionsWithCurrentValue = (options, value) => {
  if (!value || options.some(option => option.value === value)) {
    return options;
  }

  return [{ value, label: value }, ...options];
};

const voiceVoiceOptions = computed(
  () => props.assistant?.effective_settings?.voice_options || []
);
const voiceLanguageOptions = computed(() => {
  const options = [
    {
      value: 'auto',
      label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.LANGUAGE_AUTO'),
    },
    ...VOICE_LANGUAGE_OPTIONS,
  ];
  return optionsWithCurrentValue(options, state.voiceSettings.language);
});

const normalizeInputLanguagePriorities = (values, primaryLanguage = 'auto') => {
  const saved = Array.isArray(values) ? values : [];
  const candidates =
    primaryLanguage && primaryLanguage !== 'auto'
      ? [primaryLanguage, ...saved]
      : saved;
  const unique = candidates
    .map(value => String(value || '').trim())
    .filter((value, index, items) => value && items.indexOf(value) === index);
  const fallback = DEFAULT_VOICE_SETTINGS.inputLanguagePriorities.filter(
    value => !unique.includes(value)
  );
  return [...unique, ...fallback].slice(0, 3);
};

const inputLanguagePriorityOptions = index =>
  optionsWithCurrentValue(
    VOICE_LANGUAGE_OPTIONS,
    state.voiceSettings.inputLanguagePriorities[index]
  );

const updateInputLanguagePriority = (index, value) => {
  const priorities = normalizeInputLanguagePriorities(
    state.voiceSettings.inputLanguagePriorities,
    state.voiceSettings.language
  );
  if (state.voiceSettings.language !== 'auto' && index === 0) return;
  const duplicateIndex = priorities.indexOf(value);
  if (duplicateIndex >= 0 && duplicateIndex !== index) {
    [priorities[index], priorities[duplicateIndex]] = [
      priorities[duplicateIndex],
      priorities[index],
    ];
  } else {
    priorities[index] = value;
  }
  state.voiceSettings.inputLanguagePriorities =
    normalizeInputLanguagePriorities(priorities, state.voiceSettings.language);
};

watch(
  () => state.voiceSettings.language,
  language => {
    state.voiceSettings.inputLanguagePriorities =
      normalizeInputLanguagePriorities(
        state.voiceSettings.inputLanguagePriorities,
        language
      );
  }
);
const voiceActivityProfileOptions = computed(() => [
  {
    value: 'sensitive',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_ACTIVITY_SENSITIVE'),
  },
  {
    value: 'balanced',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_ACTIVITY_BALANCED'),
  },
  {
    value: 'noisy',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_ACTIVITY_NOISY'),
  },
]);

const managerHandoffOptions = computed(() => [
  {
    value: 'live_transfer',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.HANDOFF_LIVE_TRANSFER'),
  },
  {
    value: 'callback',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.HANDOFF_CALLBACK'),
  },
  {
    value: 'disabled',
    label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.HANDOFF_DISABLED'),
  },
]);

const transferFailureOptions = computed(() => [
  {
    value: 'callback',
    label: t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_FAILURE_CALLBACK'
    ),
  },
  {
    value: 'continue',
    label: t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_FAILURE_CONTINUE'
    ),
  },
  {
    value: 'end_call',
    label: t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_FAILURE_END_CALL'
    ),
  },
]);

const isLiveTransferMode = computed(
  () => state.voiceSettings.managerHandoffMode === 'live_transfer'
);
const isCallbackMode = computed(
  () => state.voiceSettings.managerHandoffMode === 'callback'
);

const voiceSettingsSummary = computed(() =>
  optionLabel(voiceVoiceOptions.value, state.voiceSettings.voice)
);

const millisecondsToSeconds = (value, fallback) => {
  if (value === null || value === undefined || value === '') return fallback;
  const milliseconds = Number(value);
  return Number.isFinite(milliseconds) && milliseconds >= 0
    ? milliseconds / 1000
    : fallback;
};

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.handoffMessageEnabled = Boolean(config.handoff_message);
  state.resolutionMessageEnabled = Boolean(config.resolution_message);
  state.handoffMessage = config.handoff_message;
  state.resolutionMessage = config.resolution_message;

  const voiceSettings = config.voice_settings || {};
  const language = voiceSettings.language || DEFAULT_VOICE_SETTINGS.language;
  state.voiceSettings = {
    voice: voiceVoiceOptions.value.some(
      option => option.value === voiceSettings.voice
    )
      ? voiceSettings.voice
      : voiceVoiceOptions.value[0]?.value || '',
    language,
    inputLanguagePriorities: normalizeInputLanguagePriorities(
      voiceSettings.input_language_priorities,
      language
    ),
    maxSentences: Number(
      voiceSettings.max_sentences ?? DEFAULT_VOICE_SETTINGS.maxSentences
    ),
    systemPrompt:
      voiceSettings.system_prompt ?? DEFAULT_VOICE_SETTINGS.systemPrompt,
    voiceCharacterPrompt:
      voiceSettings.voice_character_prompt ??
      DEFAULT_VOICE_SETTINGS.voiceCharacterPrompt,
    firstMessage:
      voiceSettings.first_message ?? DEFAULT_VOICE_SETTINGS.firstMessage,
    closingMessage:
      voiceSettings.closing_message ?? DEFAULT_VOICE_SETTINGS.closingMessage,
    managerHandoffMode:
      voiceSettings.manager_handoff_mode ??
      DEFAULT_VOICE_SETTINGS.managerHandoffMode,
    callbackMessage:
      voiceSettings.callback_message ?? DEFAULT_VOICE_SETTINGS.callbackMessage,
    transferMessage:
      voiceSettings.transfer_message ?? DEFAULT_VOICE_SETTINGS.transferMessage,
    transferFailureMode:
      voiceSettings.transfer_failure_mode ??
      DEFAULT_VOICE_SETTINGS.transferFailureMode,
    transferFailureMessage:
      voiceSettings.transfer_failure_message ??
      DEFAULT_VOICE_SETTINGS.transferFailureMessage,
    silencePromptEnabled:
      voiceSettings.silence_prompt_enabled ??
      DEFAULT_VOICE_SETTINGS.silencePromptEnabled,
    silencePromptAfterSeconds: millisecondsToSeconds(
      voiceSettings.silence_prompt_after_ms,
      DEFAULT_VOICE_SETTINGS.silencePromptAfterSeconds
    ),
    silencePrompt:
      voiceSettings.silence_prompt ?? DEFAULT_VOICE_SETTINGS.silencePrompt,
    secondSilencePromptAfterSeconds: millisecondsToSeconds(
      voiceSettings.second_silence_prompt_after_ms,
      DEFAULT_VOICE_SETTINGS.secondSilencePromptAfterSeconds
    ),
    secondSilencePrompt:
      voiceSettings.second_silence_prompt ??
      DEFAULT_VOICE_SETTINGS.secondSilencePrompt,
    maxSilenceSeconds: millisecondsToSeconds(
      voiceSettings.max_silence_ms,
      DEFAULT_VOICE_SETTINGS.maxSilenceSeconds
    ),
    finalSilenceMessage:
      voiceSettings.final_silence_message ??
      DEFAULT_VOICE_SETTINGS.finalSilenceMessage,
    endCallOnSilenceEnabled:
      voiceSettings.end_call_on_silence_enabled ??
      DEFAULT_VOICE_SETTINGS.endCallOnSilenceEnabled,
    maxDurationSec: Number(
      voiceSettings.max_duration_sec || DEFAULT_VOICE_SETTINGS.maxDurationSec
    ),
    interruptionsEnabled:
      voiceSettings.interruptions_enabled ??
      DEFAULT_VOICE_SETTINGS.interruptionsEnabled,
    voiceActivityProfile: normalizeVoiceActivityProfile(
      voiceSettings.voice_activity_profile
    ),
  };
};

const normalizeNonNegativeInteger = value => {
  const normalizedValue = Number(value);
  if (!Number.isFinite(normalizedValue) || normalizedValue <= 0) {
    return 0;
  }

  return Math.floor(normalizedValue);
};

const secondsToMilliseconds = (value, fallback) => {
  const seconds = Number(value);
  const normalizedSeconds =
    Number.isFinite(seconds) && seconds >= 0 ? seconds : fallback;
  return Math.round(normalizedSeconds * 1000);
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
        ...(props.showConversationMessages
          ? {
              handoff_message: state.handoffMessageEnabled
                ? state.handoffMessage
                : '',
              resolution_message: state.resolutionMessageEnabled
                ? state.resolutionMessage
                : '',
            }
          : {}),
        voice_settings: {
          voice: state.voiceSettings.voice,
          language:
            state.voiceSettings.language || DEFAULT_VOICE_SETTINGS.language,
          input_language_priorities: normalizeInputLanguagePriorities(
            state.voiceSettings.inputLanguagePriorities,
            state.voiceSettings.language
          ),
          max_sentences: Math.min(
            8,
            Math.max(
              1,
              normalizeNonNegativeInteger(state.voiceSettings.maxSentences) ||
                DEFAULT_VOICE_SETTINGS.maxSentences
            )
          ),
          system_prompt: state.voiceSettings.systemPrompt || '',
          voice_character_prompt:
            state.voiceSettings.voiceCharacterPrompt || '',
          first_message: state.voiceSettings.firstMessage || '',
          closing_message:
            state.voiceSettings.closingMessage ||
            DEFAULT_VOICE_SETTINGS.closingMessage,
          manager_handoff_mode:
            state.voiceSettings.managerHandoffMode ||
            DEFAULT_VOICE_SETTINGS.managerHandoffMode,
          callback_message: state.voiceSettings.callbackMessage || '',
          transfer_message: state.voiceSettings.transferMessage || '',
          transfer_failure_mode:
            state.voiceSettings.transferFailureMode ||
            DEFAULT_VOICE_SETTINGS.transferFailureMode,
          transfer_failure_message:
            state.voiceSettings.transferFailureMessage || '',
          silence_prompt_enabled: Boolean(
            state.voiceSettings.silencePromptEnabled
          ),
          silence_prompt_after_ms: secondsToMilliseconds(
            state.voiceSettings.silencePromptAfterSeconds,
            DEFAULT_VOICE_SETTINGS.silencePromptAfterSeconds
          ),
          silence_prompt: state.voiceSettings.silencePrompt || '',
          second_silence_prompt_after_ms: secondsToMilliseconds(
            state.voiceSettings.secondSilencePromptAfterSeconds,
            DEFAULT_VOICE_SETTINGS.secondSilencePromptAfterSeconds
          ),
          second_silence_prompt: state.voiceSettings.secondSilencePrompt || '',
          max_silence_ms: secondsToMilliseconds(
            state.voiceSettings.maxSilenceSeconds,
            DEFAULT_VOICE_SETTINGS.maxSilenceSeconds
          ),
          final_silence_message: state.voiceSettings.finalSilenceMessage || '',
          end_call_on_silence_enabled: Boolean(
            state.voiceSettings.endCallOnSilenceEnabled
          ),
          max_duration_sec: normalizeNonNegativeInteger(
            state.voiceSettings.maxDurationSec
          ),
          interruptions_enabled: Boolean(
            state.voiceSettings.interruptionsEnabled
          ),
          voice_activity_profile: normalizeVoiceActivityProfile(
            state.voiceSettings.voiceActivityProfile
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
            <Switch v-model="state.handoffMessageEnabled" />
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
          class="z-0 compact-system-message-editor captain-prompt-editor"
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
            <Switch v-model="state.resolutionMessageEnabled" />
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
          class="z-0 compact-system-message-editor captain-prompt-editor"
          enable-captain-fields
          :captain-context-assistant-id="assistant.id"
        />
      </div>
    </template>

    <details
      v-if="showVoiceSettings"
      open
      data-test-id="assistant-voice-settings"
      class="border-t border-n-weak pt-4"
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

      <div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
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
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.PRIMARY_LANGUAGE') }}
          </label>
          <Select
            v-model="state.voiceSettings.language"
            :options="voiceLanguageOptions"
            class="w-full"
          />
        </div>
        <div
          data-test-id="assistant-input-language-priorities"
          class="md:col-span-2 flex flex-col gap-2 border-t border-n-weak pt-4"
        >
          <div>
            <label class="text-sm font-medium text-n-slate-12">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.INPUT_LANGUAGE_PRIORITIES'
                )
              }}
            </label>
            <p class="mt-1 text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.INPUT_LANGUAGE_PRIORITIES_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
            <div
              v-for="(_, index) in state.voiceSettings.inputLanguagePriorities"
              :key="index"
              class="flex flex-col gap-1.5"
            >
              <span class="text-xs font-medium text-n-slate-10">
                {{
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.LANGUAGE_PRIORITY',
                    { index: index + 1 }
                  )
                }}
              </span>
              <Select
                :model-value="
                  state.voiceSettings.inputLanguagePriorities[index]
                "
                :options="inputLanguagePriorityOptions(index)"
                :disabled="
                  state.voiceSettings.language !== 'auto' && index === 0
                "
                class="w-full"
                @update:model-value="
                  value => updateInputLanguagePriority(index, value)
                "
              />
            </div>
          </div>
        </div>
        <Input
          v-model.number="state.voiceSettings.maxSentences"
          type="number"
          min="1"
          max="8"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.MAX_SENTENCES')"
        />
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
            class="z-0 compact-system-message-editor captain-prompt-editor"
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
            class="z-0 compact-system-message-editor captain-prompt-editor"
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
          v-model="state.voiceSettings.closingMessage"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.CLOSING_MESSAGE')"
          :placeholder="
            t(
              'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.CLOSING_MESSAGE_PLACEHOLDER'
            )
          "
        />
        <div
          data-test-id="assistant-voice-manager-handoff"
          class="md:col-span-2 flex flex-col gap-3 border-t border-n-weak pt-4"
        >
          <div class="flex flex-col gap-1.5">
            <label class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.HANDOFF_MODE') }}
            </label>
            <Select
              v-model="state.voiceSettings.managerHandoffMode"
              :options="managerHandoffOptions"
              class="w-full"
            />
            <p class="text-sm text-n-slate-11">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.HANDOFF_MODE_DESCRIPTION'
                )
              }}
            </p>
          </div>
          <Input
            v-if="isCallbackMode"
            v-model="state.voiceSettings.callbackMessage"
            :label="
              t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.CALLBACK_MESSAGE')
            "
            :placeholder="
              t(
                'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.CALLBACK_MESSAGE_PLACEHOLDER'
              )
            "
          />
          <template v-if="isLiveTransferMode">
            <Input
              v-model="state.voiceSettings.transferMessage"
              :label="
                t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_MESSAGE')
              "
              :placeholder="
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_MESSAGE_PLACEHOLDER'
                )
              "
            />
            <div class="flex flex-col gap-1.5">
              <label class="text-sm font-medium text-n-slate-12">
                {{
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_FAILURE_MODE'
                  )
                }}
              </label>
              <Select
                v-model="state.voiceSettings.transferFailureMode"
                :options="transferFailureOptions"
                class="w-full"
              />
            </div>
            <Input
              v-if="state.voiceSettings.transferFailureMode !== 'continue'"
              v-model="state.voiceSettings.transferFailureMessage"
              :label="
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_FAILURE_MESSAGE'
                )
              "
              :placeholder="
                t(
                  'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.TRANSFER_FAILURE_MESSAGE_PLACEHOLDER'
                )
              "
            />
          </template>
        </div>
        <Input
          v-model="state.voiceSettings.maxDurationSec"
          type="number"
          min="0"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.MAX_DURATION_SEC')"
          placeholder="900"
        />
        <div
          data-test-id="assistant-voice-activity-profile"
          class="flex flex-col gap-1.5"
        >
          <label class="text-sm font-medium text-n-slate-12">
            {{
              t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_ACTIVITY_PROFILE')
            }}
          </label>
          <Select
            v-model="state.voiceSettings.voiceActivityProfile"
            :options="voiceActivityProfileOptions"
            class="w-full"
          />
          <p class="text-sm text-n-slate-11">
            {{
              t(
                'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE_ACTIVITY_PROFILE_DESCRIPTION'
              )
            }}
          </p>
        </div>
        <div
          class="border-b border-n-weak py-3 flex items-center justify-between gap-4"
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
          <Switch v-model="state.voiceSettings.interruptionsEnabled" />
        </div>
        <details
          data-test-id="assistant-voice-silence-settings"
          class="md:col-span-2 border-t border-n-weak pt-4"
        >
          <summary class="cursor-pointer text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_TITLE') }}
          </summary>
          <p class="mt-2 text-sm text-n-slate-11">
            {{
              t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_DESCRIPTION')
            }}
          </p>
          <div class="mt-3 grid grid-cols-1 gap-3 md:grid-cols-2">
            <div
              class="md:col-span-2 border-b border-n-weak py-3 flex items-center justify-between gap-4"
            >
              <span class="text-sm font-medium text-n-slate-12">
                {{
                  t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_ENABLED')
                }}
              </span>
              <Switch v-model="state.voiceSettings.silencePromptEnabled" />
            </div>
            <template v-if="state.voiceSettings.silencePromptEnabled">
              <Input
                v-model="state.voiceSettings.silencePromptAfterSeconds"
                type="number"
                min="0"
                step="0.1"
                :label="
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_FIRST_DELAY'
                  )
                "
              />
              <Input
                v-model="state.voiceSettings.silencePrompt"
                :label="
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_FIRST_MESSAGE'
                  )
                "
              />
              <Input
                v-model="state.voiceSettings.secondSilencePromptAfterSeconds"
                type="number"
                min="0"
                step="0.1"
                :label="
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_SECOND_DELAY'
                  )
                "
              />
              <Input
                v-model="state.voiceSettings.secondSilencePrompt"
                :label="
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_SECOND_MESSAGE'
                  )
                "
              />
              <Input
                v-model="state.voiceSettings.maxSilenceSeconds"
                type="number"
                min="0"
                step="0.1"
                :label="
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_FINAL_DELAY'
                  )
                "
              />
              <Input
                v-model="state.voiceSettings.finalSilenceMessage"
                :label="
                  t(
                    'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_FINAL_MESSAGE'
                  )
                "
              />
              <div
                class="md:col-span-2 border-b border-n-weak py-3 flex items-center justify-between gap-4"
              >
                <span class="text-sm font-medium text-n-slate-12">
                  {{
                    t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.SILENCE_END_CALL')
                  }}
                </span>
                <Switch v-model="state.voiceSettings.endCallOnSilenceEnabled" />
              </div>
            </template>
          </div>
        </details>
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
