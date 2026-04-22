<script setup>
import { reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { minLength } from '@vuelidate/validators';

import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Input from 'dashboard/components-next/input/Input.vue';
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
  showSubmitButton: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['submit']);

const { t } = useI18n();

const initialState = {
  handoffMessageEnabled: false,
  resolutionMessageEnabled: false,
  handoffMessage: '',
  resolutionMessage: '',
  temperature: 1,
  autoReplyOnLastIncoming: false,
  messageCollapseWindowSeconds: 0,
  historyMessageLimit: 0,
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

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.handoffMessageEnabled = Boolean(config.handoff_message);
  state.resolutionMessageEnabled = Boolean(config.resolution_message);
  state.handoffMessage = config.handoff_message;
  state.resolutionMessage = config.resolution_message;
  state.temperature = config.temperature || 1;
  state.autoReplyOnLastIncoming = config.auto_reply_on_last_incoming || false;
  state.messageCollapseWindowSeconds = Number(
    config.message_collapse_window_seconds || 0
  );
  state.historyMessageLimit = Number(config.history_message_limit || 0);
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
        temperature: state.temperature || 1,
        auto_reply_on_last_incoming: state.autoReplyOnLastIncoming,
        message_collapse_window_seconds: normalizeNonNegativeInteger(
          state.messageCollapseWindowSeconds
        ),
        history_message_limit: normalizeNonNegativeInteger(
          state.historyMessageLimit
        ),
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
