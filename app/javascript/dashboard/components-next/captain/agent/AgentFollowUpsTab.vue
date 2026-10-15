<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';

const props = defineProps({
  assistant: { type: Object, required: true },
  canEdit: { type: Boolean, default: false },
});

const emit = defineEmits(['dirtyChange', 'saved']);

const store = useStore();
const { t } = useI18n();

const state = reactive({
  enabled: false,
  prompt: '',
  steps: [],
  isSaving: false,
});
const expandedStepIndex = ref(null);
const draftBaseline = ref(null);
const loadedAssistantId = ref(null);

const defaultSteps = () => [
  {
    delay: 1,
    unit: 'hours',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_1'),
    message: '',
  },
  {
    delay: 3,
    unit: 'hours',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_2'),
    message: '',
  },
  {
    delay: 4,
    unit: 'days',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_3'),
    message: '',
  },
];

const secondsByUnit = { minutes: 60, hours: 3600, days: 86400 };

const editableStep = step => {
  const seconds = Number(step.delay_seconds || 3600);
  let unit = 'minutes';
  if (seconds % 86400 === 0) unit = 'days';
  else if (seconds % 3600 === 0) unit = 'hours';

  const mode = step.mode === 'ai' || step.objective ? 'ai' : 'static';
  return {
    delay: Math.max(1, seconds / secondsByUnit[unit]),
    unit,
    mode,
    objective: String(step.objective || ''),
    message: String(step.message || ''),
  };
};

const incomingDraft = value => {
  const settings = value?.config?.follow_up_settings || {};
  return {
    enabled: Boolean(settings.enabled),
    prompt: String(
      settings.prompt || t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_PROMPT')
    ),
    steps:
      Array.isArray(settings.steps) && settings.steps.length
        ? settings.steps.map(editableStep)
        : defaultSteps(),
  };
};

const draftSnapshot = value => JSON.stringify(value);
const currentDraftSnapshot = () =>
  draftSnapshot({
    enabled: state.enabled,
    prompt: state.prompt,
    steps: state.steps,
  });

const isDirty = computed(
  () =>
    draftBaseline.value !== null &&
    currentDraftSnapshot() !== draftBaseline.value
);

watch(isDirty, value => emit('dirtyChange', value));

watch(
  () => props.assistant,
  value => {
    const nextDraft = incomingDraft(value);
    const nextSnapshot = draftSnapshot(nextDraft);
    const currentSnapshot = currentDraftSnapshot();
    const sameAssistant = loadedAssistantId.value === (value?.id ?? null);
    const hasUnsavedChanges =
      draftBaseline.value && currentSnapshot !== draftBaseline.value;
    if (
      sameAssistant &&
      hasUnsavedChanges &&
      nextSnapshot !== currentSnapshot
    ) {
      return;
    }

    Object.assign(state, nextDraft);
    loadedAssistantId.value = value?.id ?? null;
    draftBaseline.value = nextSnapshot;
    expandedStepIndex.value = state.enabled ? 0 : null;
  },
  { deep: true, immediate: true }
);

watch(
  () => state.enabled,
  enabled => {
    expandedStepIndex.value = enabled && state.steps.length ? 0 : null;
  }
);

// Viewing a step stays possible for read-only users; editing needs both
// the follow-ups switch and the right to edit.
const editorDisabled = computed(() => !state.enabled || !props.canEdit);

const unitOptions = computed(() => [
  { value: 'minutes', label: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MINUTES') },
  { value: 'hours', label: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.HOURS') },
  { value: 'days', label: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DAYS') },
]);

const modeOptions = computed(() => [
  { value: 'ai', label: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_AI') },
  { value: 'static', label: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_STATIC') },
]);

const addStep = () => {
  state.steps.push({
    delay: 1,
    unit: 'days',
    mode: 'ai',
    objective: '',
    message: '',
  });
  expandedStepIndex.value = state.steps.length - 1;
};

const removeStep = index => {
  state.steps.splice(index, 1);
  if (expandedStepIndex.value === index) {
    expandedStepIndex.value = Math.min(index, state.steps.length - 1);
  } else if (expandedStepIndex.value > index) {
    expandedStepIndex.value -= 1;
  }
};

const toggleStep = index => {
  expandedStepIndex.value = expandedStepIndex.value === index ? null : index;
};

const isExpanded = index => expandedStepIndex.value === index;

const stepSummary = step =>
  (step.mode === 'ai' ? step.objective : step.message) ||
  t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.EMPTY_STEP_SUMMARY');

const shortUnitLabel = unit => {
  if (unit === 'minutes') {
    return t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MINUTES_SHORT');
  }
  if (unit === 'days') {
    return t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DAYS_SHORT');
  }
  return t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.HOURS_SHORT');
};

const stepDelaySummary = step =>
  t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DELAY_SUMMARY', {
    delay: step.delay,
    unit: shortUnitLabel(step.unit),
  });

const stepModeLabel = step =>
  step.mode === 'ai'
    ? t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_AI')
    : t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_STATIC');

const serializedStep = step => {
  const delaySeconds = Math.round(
    Number(step.delay) * secondsByUnit[step.unit]
  );
  if (!Number.isFinite(delaySeconds) || delaySeconds <= 0) return null;

  if (step.mode === 'static') {
    const message = step.message.trim();
    return message
      ? { delay_seconds: delaySeconds, mode: 'static', message }
      : null;
  }

  const objective = step.objective.trim();
  return objective
    ? { delay_seconds: delaySeconds, mode: 'ai', objective }
    : null;
};

const save = async () => {
  if (!props.canEdit || state.isSaving) return false;

  const steps = state.steps.map(serializedStep).filter(Boolean);
  const hasAiSteps = steps.some(step => step.mode === 'ai');
  const prompt = state.prompt.trim();

  if (state.enabled && !steps.length) {
    useAlert(t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.VALIDATION'));
    return false;
  }
  if (state.enabled && hasAiSteps && !prompt) {
    useAlert(t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_VALIDATION'));
    return false;
  }

  const assistantId = props.assistant.id;
  const submittedSnapshot = currentDraftSnapshot();
  state.isSaving = true;
  try {
    const response = await CaptainAssistantAPI.update(assistantId, {
      config: {
        follow_up_settings: { enabled: state.enabled, prompt, steps },
      },
    });
    draftBaseline.value = submittedSnapshot;
    let refreshed = null;
    try {
      refreshed = await store.dispatch('captainAssistants/show', assistantId);
    } catch {
      // The change is saved; the next load brings the fresh record.
    }
    emit('saved', refreshed || response?.data || props.assistant);
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'));
    return true;
  } catch {
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE'));
    return false;
  } finally {
    state.isSaving = false;
  }
};

defineExpose({ isDirty, save });
</script>

<template>
  <div
    class="flex w-full flex-col gap-6"
    data-testid="follow-ups-tab"
  >
    <SettingsToggleSection
      v-model="state.enabled"
      :header="t('CAPTAIN.AGENT_TABS.FOLLOW_UPS.TITLE')"
      :description="t('CAPTAIN.AGENT_TABS.FOLLOW_UPS.DESCRIPTION')"
      :disabled="!canEdit"
      data-testid="follow-up-toggle"
    >
      <template #editor>
        <div class="flex flex-col gap-1" data-testid="follow-up-editor">
          <TextArea
            id="follow-up-prompt"
            v-model="state.prompt"
            :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_LABEL')"
            :placeholder="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_PLACEHOLDER')"
            :max-length="4000"
            :disabled="editorDisabled"
            show-character-count
            auto-height
            min-height="6rem"
            max-height="16rem"
            data-testid="follow-up-prompt"
          />
          <p class="mb-0 text-body-main text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_DESCRIPTION') }}
          </p>
        </div>
      </template>
    </SettingsToggleSection>

    <section
      class="flex flex-col gap-4"
      :aria-disabled="!state.enabled"
      data-testid="follow-up-steps"
    >
      <div class="flex flex-col gap-1">
        <h3 class="mb-0 text-heading-2 text-n-slate-12">
          {{ t('CAPTAIN.AGENT_TABS.FOLLOW_UPS.STEPS_TITLE') }}
        </h3>
        <p class="mb-0 text-body-main text-n-slate-11">
          {{ t('CAPTAIN.AGENT_TABS.FOLLOW_UPS.STEPS_DESCRIPTION') }}
        </p>
      </div>

      <div class="flex flex-col gap-4">
        <CardLayout
          v-for="(step, index) in state.steps"
          :key="index"
          compact
          data-testid="follow-up-step"
        >
          <div class="flex min-w-0 items-start gap-2">
            <button
              type="button"
              class="flex min-w-0 flex-1 items-start gap-3 p-0 text-left disabled:cursor-not-allowed"
              :disabled="!state.enabled"
              :aria-expanded="isExpanded(index)"
              data-testid="follow-up-step-toggle"
              @click="toggleStep(index)"
            >
              <span class="flex min-w-0 flex-1 flex-col gap-1">
                <span class="flex min-w-0 flex-wrap items-baseline gap-x-2">
                  <span class="text-heading-3 text-n-slate-12">
                    {{
                      t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.STEP', {
                        number: index + 1,
                      })
                    }}
                  </span>
                  <span class="text-body-main text-n-slate-11">
                    {{ stepDelaySummary(step) }}
                  </span>
                  <span
                    class="text-body-main"
                    :class="
                      step.mode === 'ai' ? 'text-n-brand' : 'text-n-slate-11'
                    "
                  >
                    {{ stepModeLabel(step) }}
                  </span>
                </span>
                <span
                  class="block min-w-0 truncate text-body-main text-n-slate-11"
                >
                  {{ stepSummary(step) }}
                </span>
              </span>
              <span
                class="i-lucide-chevron-down mt-0.5 size-4 shrink-0 text-n-slate-10 transition-transform"
                :class="{ 'rotate-180': isExpanded(index) }"
                aria-hidden="true"
              />
              <span class="sr-only">
                {{
                  isExpanded(index)
                    ? t('CAPTAIN.AGENT_TABS.FOLLOW_UPS.COLLAPSE')
                    : t('CAPTAIN.AGENT_TABS.FOLLOW_UPS.EXPAND')
                }}
              </span>
            </button>
            <Button
              v-if="state.steps.length > 1"
              ghost
              slate
              sm
              icon="i-lucide-trash-2"
              class="shrink-0"
              :disabled="editorDisabled"
              :aria-label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.REMOVE_STEP')"
              data-testid="follow-up-step-remove"
              @click="removeStep(index)"
            />
          </div>

          <div
            v-if="isExpanded(index)"
            class="flex flex-col gap-4 border-t border-n-weak pt-4"
            data-testid="follow-up-step-details"
          >
            <div
              class="grid gap-4 sm:grid-cols-[minmax(0,7rem)_minmax(0,1fr)_minmax(0,1fr)]"
            >
              <Input
                :id="`follow-up-delay-${index}`"
                v-model.number="step.delay"
                type="number"
                :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DELAY')"
                :disabled="editorDisabled"
                data-testid="follow-up-delay"
              />
              <div class="flex min-w-0 flex-col gap-1">
                <label
                  :for="`follow-up-unit-${index}`"
                  class="mb-0.5 text-heading-3 text-n-slate-12"
                >
                  {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.UNIT') }}
                </label>
                <Select
                  :id="`follow-up-unit-${index}`"
                  v-model="step.unit"
                  :options="unitOptions"
                  :disabled="editorDisabled"
                  class="w-full"
                  data-testid="follow-up-unit"
                />
              </div>
              <div class="flex min-w-0 flex-col gap-1">
                <label
                  :for="`follow-up-mode-${index}`"
                  class="mb-0.5 text-heading-3 text-n-slate-12"
                >
                  {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE') }}
                </label>
                <Select
                  :id="`follow-up-mode-${index}`"
                  v-model="step.mode"
                  :options="modeOptions"
                  :disabled="editorDisabled"
                  class="w-full"
                  data-testid="follow-up-mode"
                />
              </div>
            </div>
            <TextArea
              v-if="step.mode === 'ai'"
              :id="`follow-up-objective-${index}`"
              v-model="step.objective"
              :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.OBJECTIVE_LABEL')"
              :placeholder="
                t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.OBJECTIVE_PLACEHOLDER')
              "
              :max-length="1000"
              :disabled="editorDisabled"
              show-character-count
              auto-height
              data-testid="follow-up-objective"
            />
            <TextArea
              v-else
              :id="`follow-up-message-${index}`"
              v-model="step.message"
              :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.STATIC_MESSAGE_LABEL')"
              :placeholder="
                t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MESSAGE_PLACEHOLDER')
              "
              :max-length="2000"
              :disabled="editorDisabled"
              show-character-count
              auto-height
              data-testid="follow-up-message"
            />
          </div>
        </CardLayout>
      </div>

      <div>
        <Button
          ghost
          slate
          icon="i-lucide-plus"
          :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.ADD_STEP')"
          :disabled="editorDisabled"
          data-testid="follow-up-add-step"
          @click="addStep"
        />
      </div>
    </section>

    <div v-if="canEdit" class="flex justify-end">
      <Button
        :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.SAVE')"
        :is-loading="state.isSaving"
        :disabled="!isDirty || state.isSaving"
        data-testid="follow-up-save"
        @click="save"
      />
    </div>
  </div>
</template>
