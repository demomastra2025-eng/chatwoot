<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import { isWhatsAppTemplateCapableChannel } from 'dashboard/components-next/Outbound/touchContentModes';
import WhatsAppTemplateVariantField from './WhatsAppTemplateVariantField.vue';

const route = useRoute();
const store = useStore();
const { t } = useI18n();

const assistantId = computed(() => Number(route.params.assistantId));
const assistant = computed(() =>
  store.getters['captainAssistants/getRecord'](assistantId.value)
);
const inboxes = computed(() => store.getters['inboxes/getInboxes'] || []);
const connectedWhatsAppInboxes = computed(() =>
  inboxes.value.filter(
    inbox =>
      inbox?.captain_assistant?.id === assistantId.value &&
      isWhatsAppTemplateCapableChannel({
        channelType: inbox.channel_type,
        medium: inbox.medium || inbox.channel?.medium,
      })
  )
);
const approvedTemplatesForInbox = inboxId => {
  const getter = store.getters['inboxes/getFilteredWhatsAppTemplates'];
  const templates =
    typeof getter === 'function' ? getter(Number(inboxId)) || [] : [];
  return templates.filter(
    template =>
      String(template.category || '').toUpperCase() !== 'AUTHENTICATION'
  );
};
const state = reactive({
  enabled: false,
  prompt: '',
  steps: [],
  quietHours: {
    enabled: false,
    startTime: '23:00',
    endTime: '08:00',
    timezone: '',
  },
  isSaving: false,
});
const expandedStepIndex = ref(null);
const draftBaseline = ref(null);
const loadedAssistantId = ref(null);
const templateValidity = reactive({});

const defaultSteps = () => [
  {
    delay: 1,
    unit: 'hours',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_1'),
    message: '',
  },
  {
    delay: 6,
    unit: 'hours',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_2'),
    message: '',
  },
  {
    delay: 22,
    unit: 'hours',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_3'),
    message: '',
  },
  {
    delay: 3,
    unit: 'days',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_4'),
    message: '',
  },
  {
    delay: 7,
    unit: 'days',
    mode: 'ai',
    objective: t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_OBJECTIVE_5'),
    message: '',
  },
];

const secondsByUnit = { minutes: 60, hours: 3600, days: 86400 };
const defaultTemplateVariants = () => ({
  ru: { name: '', language: 'ru' },
  kk: { name: '', language: 'kk' },
  en: { name: '', language: 'en_US' },
});

const editableTemplateVariants = value => {
  const defaults = defaultTemplateVariants();
  Object.keys(defaults).forEach(language => {
    defaults[language] = {
      ...defaults[language],
      ...(value?.[language] || {}),
    };
  });
  return defaults;
};

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
    templateVariants: editableTemplateVariants(step.template_variants),
    templateVariantsByInbox: JSON.parse(
      JSON.stringify(step.template_variants_by_inbox || {})
    ),
  };
};

const incomingDraft = value => {
  const settings = value?.config?.follow_up_settings || {};
  return {
    enabled: Boolean(settings.enabled),
    prompt: String(
      settings.prompt || t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DEFAULT_PROMPT')
    ),
    quietHours: {
      enabled: settings.quiet_hours?.enabled === true,
      startTime: String(settings.quiet_hours?.start_time || '23:00'),
      endTime: String(settings.quiet_hours?.end_time || '08:00'),
      timezone: String(settings.quiet_hours?.timezone || ''),
    },
    steps:
      Array.isArray(settings.steps) && settings.steps.length
        ? settings.steps.slice(0, 5).map(editableStep)
        : defaultSteps(),
  };
};

const draftSnapshot = value => JSON.stringify(value);
const currentDraftSnapshot = () =>
  draftSnapshot({
    enabled: state.enabled,
    prompt: state.prompt,
    steps: state.steps,
    quietHours: state.quietHours,
  });

watch(
  assistant,
  value => {
    const nextDraft = incomingDraft(value);
    const nextSnapshot = draftSnapshot(nextDraft);
    const currentSnapshot = currentDraftSnapshot();
    const sameAssistant = loadedAssistantId.value === value?.id;
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

const addStep = () => {
  if (state.steps.length >= 5) return;
  state.steps.push({
    delay: 1,
    unit: 'days',
    mode: 'ai',
    objective: '',
    message: '',
    templateVariants: defaultTemplateVariants(),
    templateVariantsByInbox: {},
  });
  expandedStepIndex.value = state.steps.length - 1;
};

const removeStep = index => {
  state.steps.splice(index, 1);
  Object.keys(templateValidity).forEach(key => delete templateValidity[key]);
  if (expandedStepIndex.value === index) {
    expandedStepIndex.value = Math.min(index, state.steps.length - 1);
  } else if (expandedStepIndex.value > index) {
    expandedStepIndex.value -= 1;
  }
};

const toggleStep = index => {
  expandedStepIndex.value = expandedStepIndex.value === index ? null : index;
};

const updateTemplateVariant = (step, inboxId, language, value) => {
  const inboxKey = String(inboxId);
  const nextInboxVariants = {
    ...(step.templateVariantsByInbox?.[inboxKey] || {}),
  };
  if (value?.name) nextInboxVariants[language] = value;
  else delete nextInboxVariants[language];

  step.templateVariantsByInbox = {
    ...(step.templateVariantsByInbox || {}),
    [inboxKey]: nextInboxVariants,
  };
  if (!Object.keys(nextInboxVariants).length) {
    delete step.templateVariantsByInbox[inboxKey];
  }
};

const setTemplateValidity = (stepIndex, inboxId, language, valid) => {
  templateValidity[`${stepIndex}:${inboxId}:${language}`] = valid;
};

const stepSummary = step =>
  step.mode === 'ai' ? step.objective : step.message;

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

watch(
  () => state.enabled,
  enabled => {
    expandedStepIndex.value = enabled && state.steps.length ? 0 : null;
  }
);

const serializedStep = step => {
  const delaySeconds = Math.round(
    Number(step.delay) * secondsByUnit[step.unit]
  );
  if (!Number.isFinite(delaySeconds) || delaySeconds <= 0) return null;

  const templateVariants = Object.fromEntries(
    Object.entries(step.templateVariants || {})
      .filter(([, variant]) => variant?.name?.trim())
      .map(([language, variant]) => [
        language,
        { ...variant, name: variant.name.trim() },
      ])
  );
  const deliveryConfig = Object.keys(templateVariants).length
    ? { template_variants: templateVariants }
    : {};
  const templateVariantsByInbox = Object.fromEntries(
    Object.entries(step.templateVariantsByInbox || {}).filter(
      ([inboxId, variants]) =>
        connectedWhatsAppInboxes.value.some(
          inbox => inbox.id === Number(inboxId)
        ) && Object.keys(variants || {}).length
    )
  );
  if (Object.keys(templateVariantsByInbox).length) {
    deliveryConfig.template_variants_by_inbox = templateVariantsByInbox;
  }

  if (step.mode === 'static') {
    const message = step.message.trim();
    return message
      ? {
          delay_seconds: delaySeconds,
          mode: 'static',
          message,
          ...deliveryConfig,
        }
      : null;
  }

  const objective = step.objective.trim();
  return objective
    ? { delay_seconds: delaySeconds, mode: 'ai', objective, ...deliveryConfig }
    : null;
};

const quietHoursValid = () => {
  if (!state.quietHours.enabled) return true;
  if (
    !/^([01]\d|2[0-3]):[0-5]\d$/.test(state.quietHours.startTime) ||
    !/^([01]\d|2[0-3]):[0-5]\d$/.test(state.quietHours.endTime) ||
    state.quietHours.startTime === state.quietHours.endTime
  ) {
    return false;
  }

  if (!state.quietHours.timezone.trim()) return true;

  try {
    new Intl.DateTimeFormat('en-US', {
      timeZone: state.quietHours.timezone,
    }).format();
    return true;
  } catch {
    return false;
  }
};

const save = async () => {
  const steps = state.steps.map(serializedStep).filter(Boolean);
  const hasAiSteps = steps.some(step => step.mode === 'ai');
  const prompt = state.prompt.trim();

  if (state.enabled && !steps.length) {
    useAlert(t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.VALIDATION'));
    return;
  }
  if (state.enabled && hasAiSteps && !prompt) {
    useAlert(t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_VALIDATION'));
    return;
  }
  if (state.enabled && !quietHoursValid()) {
    useAlert(t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.QUIET_HOURS_VALIDATION'));
    return;
  }
  if (state.enabled && Object.values(templateValidity).includes(false)) {
    useAlert(t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.TEMPLATE_VALIDATION'));
    return;
  }

  const submittedSnapshot = currentDraftSnapshot();
  state.isSaving = true;
  try {
    await CaptainAssistantAPI.update(assistantId.value, {
      config: {
        follow_up_settings: {
          enabled: state.enabled,
          prompt,
          timing_mode: 'absolute_from_last_incoming',
          quiet_hours: {
            enabled: state.quietHours.enabled,
            start_time: state.quietHours.startTime,
            end_time: state.quietHours.endTime,
            ...(state.quietHours.timezone.trim()
              ? { timezone: state.quietHours.timezone.trim() }
              : {}),
          },
          steps,
        },
      },
    });
    draftBaseline.value = submittedSnapshot;
    await store.dispatch('captainAssistants/get');
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.API.SUCCESS_MESSAGE'));
  } catch {
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.API.ERROR_MESSAGE'));
  } finally {
    state.isSaving = false;
  }
};

store.dispatch('inboxes/get');
</script>

<template>
  <PageLayout
    show-assistant-switcher
    :show-pagination-footer="false"
    :show-know-more="false"
  >
    <template #body>
      <div class="flex max-w-4xl flex-col gap-6">
        <div class="rounded-2xl bg-n-solid-1 p-5 md:p-6">
          <div class="flex items-center justify-between gap-6">
            <SettingsHeader
              class="min-w-0 flex-1"
              :heading="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.HEADER')"
              :description="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DESCRIPTION')"
            />
            <Switch v-model="state.enabled" />
          </div>

          <fieldset
            data-testid="follow-up-editor"
            :disabled="!state.enabled"
            :aria-disabled="!state.enabled"
            class="m-0 min-w-0 border-0 p-0 transition-opacity"
            :class="!state.enabled && 'opacity-50'"
          >
            <div class="mt-6">
              <label
                for="follow-up-prompt"
                class="text-sm font-medium text-n-slate-12"
              >
                {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_LABEL') }}
              </label>
              <p class="mt-1 text-xs text-n-slate-11">
                {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_DESCRIPTION') }}
              </p>
              <textarea
                id="follow-up-prompt"
                v-model="state.prompt"
                :disabled="!state.enabled"
                maxlength="4000"
                rows="4"
                class="mt-3 w-full resize-y rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-sm text-n-slate-12 outline-none focus:border-n-brand"
                :placeholder="
                  t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.PROMPT_PLACEHOLDER')
                "
              />
            </div>

            <div class="mt-6 rounded-xl border border-n-weak bg-n-alpha-1 p-4">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <p class="text-sm font-medium text-n-slate-12">
                    {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.QUIET_HOURS') }}
                  </p>
                  <p class="mt-1 text-xs text-n-slate-11">
                    {{
                      t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.QUIET_HOURS_DESCRIPTION')
                    }}
                  </p>
                </div>
                <Switch v-model="state.quietHours.enabled" />
              </div>
              <div class="mt-4 grid gap-3 md:grid-cols-3">
                <label
                  class="flex flex-col gap-2 text-xs font-medium text-n-slate-11"
                >
                  {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.QUIET_START') }}
                  <input
                    v-model="state.quietHours.startTime"
                    type="time"
                    :disabled="!state.enabled || !state.quietHours.enabled"
                    data-testid="quiet-hours-start"
                    class="h-10 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-sm font-normal text-n-slate-12 outline-none focus:border-n-brand"
                  />
                </label>
                <label
                  class="flex flex-col gap-2 text-xs font-medium text-n-slate-11"
                >
                  {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.QUIET_END') }}
                  <input
                    v-model="state.quietHours.endTime"
                    type="time"
                    :disabled="!state.enabled || !state.quietHours.enabled"
                    data-testid="quiet-hours-end"
                    class="h-10 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-sm font-normal text-n-slate-12 outline-none focus:border-n-brand"
                  />
                </label>
                <label
                  class="flex flex-col gap-2 text-xs font-medium text-n-slate-11"
                >
                  {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.TIMEZONE') }}
                  <input
                    v-model.trim="state.quietHours.timezone"
                    type="text"
                    :disabled="!state.enabled || !state.quietHours.enabled"
                    data-testid="quiet-hours-timezone"
                    :placeholder="
                      t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.TIMEZONE_PLACEHOLDER')
                    "
                    class="h-10 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-sm font-normal text-n-slate-12 outline-none focus:border-n-brand"
                  />
                </label>
              </div>
            </div>

            <div class="mt-6 flex flex-col">
              <div
                v-for="(step, index) in state.steps"
                :key="index"
                data-testid="follow-up-step"
                class="relative pb-3 pl-9 last:pb-0"
              >
                <div
                  v-if="index < state.steps.length - 1"
                  class="absolute bottom-0 left-[0.9375rem] top-8 w-px bg-n-weak"
                />
                <div
                  class="absolute left-0 top-3 flex size-8 items-center justify-center rounded-full border border-n-weak bg-n-solid-1 text-xs font-medium text-n-slate-11"
                  :class="
                    expandedStepIndex === index &&
                    'border-n-brand bg-n-brand text-white'
                  "
                >
                  {{ index + 1 }}
                </div>
                <div
                  class="overflow-hidden rounded-xl border border-n-weak bg-n-alpha-1 transition-colors"
                  :class="expandedStepIndex === index && 'border-n-brand'"
                >
                  <div class="flex min-w-0 items-center">
                    <button
                      type="button"
                      data-testid="follow-up-step-toggle"
                      class="flex min-w-0 flex-1 items-center gap-3 px-4 py-3 text-left"
                      :disabled="!state.enabled"
                      :aria-expanded="expandedStepIndex === index"
                      @click="toggleStep(index)"
                    >
                      <span
                        class="shrink-0 rounded-md bg-n-alpha-2 px-2 py-1 text-xs font-medium text-n-slate-11"
                      >
                        {{ stepDelaySummary(step) }}
                      </span>
                      <span
                        class="shrink-0 rounded-md px-2 py-1 text-xs font-medium"
                        :class="
                          step.mode === 'ai'
                            ? 'bg-n-brand/10 text-n-brand'
                            : 'bg-n-alpha-2 text-n-slate-11'
                        "
                      >
                        {{
                          step.mode === 'ai'
                            ? t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_AI')
                            : t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_STATIC')
                        }}
                      </span>
                      <span
                        class="min-w-0 flex-1 truncate text-sm text-n-slate-12"
                      >
                        {{
                          stepSummary(step) ||
                          t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.EMPTY_STEP_SUMMARY')
                        }}
                      </span>
                      <span
                        class="i-lucide-chevron-down size-4 shrink-0 text-n-slate-10 transition-transform"
                        :class="expandedStepIndex === index && 'rotate-180'"
                      />
                    </button>
                    <Button
                      v-if="state.steps.length > 1"
                      :disabled="!state.enabled"
                      ghost
                      slate
                      sm
                      icon="i-lucide-trash-2"
                      class="mr-2 shrink-0"
                      :aria-label="
                        t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.REMOVE_STEP')
                      "
                      @click="removeStep(index)"
                    />
                  </div>

                  <div
                    v-if="expandedStepIndex === index"
                    data-testid="follow-up-step-details"
                    class="border-t border-n-weak p-4"
                  >
                    <div class="grid gap-3 md:grid-cols-[8rem_10rem_12rem]">
                      <label
                        class="flex flex-col gap-2 text-xs font-medium text-n-slate-11"
                      >
                        {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DELAY') }}
                        <input
                          v-model.number="step.delay"
                          :disabled="!state.enabled"
                          type="number"
                          min="1"
                          class="h-10 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-sm font-normal text-n-slate-12 outline-none focus:border-n-brand"
                        />
                      </label>
                      <label
                        class="flex flex-col gap-2 text-xs font-medium text-n-slate-11"
                      >
                        {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.UNIT') }}
                        <select
                          v-model="step.unit"
                          :disabled="!state.enabled"
                          class="h-10 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-sm font-normal text-n-slate-12 outline-none focus:border-n-brand"
                        >
                          <option value="minutes">
                            {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MINUTES') }}
                          </option>
                          <option value="hours">
                            {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.HOURS') }}
                          </option>
                          <option value="days">
                            {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.DAYS') }}
                          </option>
                        </select>
                      </label>
                      <label
                        class="flex flex-col gap-2 text-xs font-medium text-n-slate-11"
                      >
                        {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE') }}
                        <select
                          v-model="step.mode"
                          :disabled="!state.enabled"
                          data-testid="follow-up-mode"
                          class="h-10 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-sm font-normal text-n-slate-12 outline-none focus:border-n-brand"
                        >
                          <option value="ai">
                            {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_AI') }}
                          </option>
                          <option value="static">
                            {{ t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MODE_STATIC') }}
                          </option>
                        </select>
                      </label>
                    </div>
                    <div class="mt-4">
                      <label class="text-xs font-medium text-n-slate-11">
                        {{
                          step.mode === 'ai'
                            ? t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.OBJECTIVE_LABEL')
                            : t(
                                'CAPTAIN.ASSISTANTS.FOLLOW_UPS.STATIC_MESSAGE_LABEL'
                              )
                        }}
                      </label>
                      <textarea
                        v-if="step.mode === 'ai'"
                        v-model="step.objective"
                        :disabled="!state.enabled"
                        maxlength="1000"
                        data-testid="follow-up-objective"
                        rows="2"
                        class="mt-2 w-full resize-y rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-sm text-n-slate-12 outline-none focus:border-n-brand"
                        :placeholder="
                          t(
                            'CAPTAIN.ASSISTANTS.FOLLOW_UPS.OBJECTIVE_PLACEHOLDER'
                          )
                        "
                      />
                      <textarea
                        v-else
                        v-model="step.message"
                        :disabled="!state.enabled"
                        maxlength="10000"
                        data-testid="follow-up-message"
                        rows="2"
                        class="mt-2 w-full resize-y rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-sm text-n-slate-12 outline-none focus:border-n-brand"
                        :placeholder="
                          t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.MESSAGE_PLACEHOLDER')
                        "
                      />
                    </div>
                    <div class="mt-4 rounded-lg border border-n-weak p-3">
                      <p class="text-xs font-medium text-n-slate-11">
                        {{
                          t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.WHATSAPP_TEMPLATES')
                        }}
                      </p>
                      <p class="mt-1 text-xs text-n-slate-10">
                        {{
                          t(
                            'CAPTAIN.ASSISTANTS.FOLLOW_UPS.WHATSAPP_TEMPLATES_DESCRIPTION'
                          )
                        }}
                      </p>
                      <div
                        v-if="connectedWhatsAppInboxes.length"
                        class="mt-3 grid gap-4"
                      >
                        <div
                          v-for="inbox in connectedWhatsAppInboxes"
                          :key="inbox.id"
                          class="rounded-lg border border-n-weak p-3"
                        >
                          <p class="mb-3 text-sm font-medium text-n-slate-12">
                            {{ inbox.name }}
                          </p>
                          <div class="grid gap-3 md:grid-cols-3">
                            <WhatsAppTemplateVariantField
                              v-for="language in ['ru', 'kk', 'en']"
                              :key="`${inbox.id}-${language}`"
                              :language="language"
                              :templates="approvedTemplatesForInbox(inbox.id)"
                              :model-value="
                                step.templateVariantsByInbox?.[
                                  String(inbox.id)
                                ]?.[language] || {}
                              "
                              @update:model-value="
                                updateTemplateVariant(
                                  step,
                                  inbox.id,
                                  language,
                                  $event
                                )
                              "
                              @validity-change="
                                setTemplateValidity(
                                  index,
                                  inbox.id,
                                  language,
                                  $event
                                )
                              "
                            />
                          </div>
                        </div>
                      </div>
                      <p v-else class="mt-3 text-xs text-n-slate-10">
                        {{
                          t(
                            'CAPTAIN.ASSISTANTS.FOLLOW_UPS.WHATSAPP_TEMPLATES_EMPTY'
                          )
                        }}
                      </p>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div class="mt-4">
              <Button
                v-if="state.steps.length < 5"
                :disabled="!state.enabled"
                ghost
                slate
                icon="i-lucide-plus"
                :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.ADD_STEP')"
                @click="addStep"
              />
            </div>
          </fieldset>

          <div class="mt-4 flex justify-end">
            <Button
              data-testid="follow-up-save"
              :label="t('CAPTAIN.ASSISTANTS.FOLLOW_UPS.SAVE')"
              :is-loading="state.isSaving"
              @click="save"
            />
          </div>
        </div>
      </div>
    </template>
  </PageLayout>
</template>
