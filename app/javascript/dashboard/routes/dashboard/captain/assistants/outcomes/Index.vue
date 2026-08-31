<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  assistant: {
    type: Object,
    default: () => ({}),
  },
  handoffEnabled: {
    type: Boolean,
    default: true,
  },
});

const MAX_REASONS = 20;

const { t } = useI18n();
const state = reactive({
  autoCompletionEnabled: true,
  completionReasons: [],
  handoffReasons: [],
});
const draftBaseline = ref(null);
const loadedAssistantId = ref(null);

const defaultReasons = () => ({
  completionReasons: [
    ['goal_achieved', 'COMPLETION.GOAL_ACHIEVED'],
    ['question_resolved', 'COMPLETION.QUESTION_RESOLVED'],
    ['customer_declined', 'COMPLETION.CUSTOMER_DECLINED'],
    ['no_response', 'COMPLETION.NO_RESPONSE'],
    ['other', 'COMMON.OTHER'],
  ].map(([id, key]) => ({
    id,
    label: t(`CAPTAIN.ASSISTANTS.OUTCOMES.DEFAULTS.${key}`),
    active: true,
  })),
  handoffReasons: [
    ['customer_requested_human', 'HANDOFF.CUSTOMER_REQUESTED_HUMAN'],
    ['low_confidence', 'HANDOFF.LOW_CONFIDENCE'],
    ['manual_action_required', 'HANDOFF.MANUAL_ACTION_REQUIRED'],
    ['complaint_or_conflict', 'HANDOFF.COMPLAINT_OR_CONFLICT'],
    ['tool_or_policy_limit', 'HANDOFF.TOOL_OR_POLICY_LIMIT'],
    ['other', 'COMMON.OTHER'],
  ].map(([id, key]) => ({
    id,
    label: t(`CAPTAIN.ASSISTANTS.OUTCOMES.DEFAULTS.${key}`),
    active: true,
  })),
});

const editableReasons = reasons =>
  Array.isArray(reasons)
    ? reasons
        .slice(0, MAX_REASONS)
        .filter(reason => reason?.id && reason?.label)
        .map(reason => ({
          id: String(reason.id),
          label: String(reason.label),
          active: reason.id === 'other' || reason.active !== false,
        }))
    : [];

const withOtherFallback = (reasons, fallback) => {
  const normalized = editableReasons(reasons);
  const other = normalized.find(reason => reason.id === 'other') || fallback;
  return [
    ...normalized
      .filter(reason => reason.id !== 'other')
      .slice(0, MAX_REASONS - 1),
    { ...other, id: 'other', active: true },
  ];
};

const draftSnapshot = value => JSON.stringify(value);

const incomingDraft = value => {
  const config = value?.config || {};
  const settings = config.outcome_reason_settings;
  const defaults = defaultReasons();

  return {
    autoCompletionEnabled: config.auto_completion_enabled !== false,
    completionReasons: withOtherFallback(
      settings?.completion_reasons || defaults.completionReasons,
      defaults.completionReasons.at(-1)
    ),
    handoffReasons: withOtherFallback(
      settings?.handoff_reasons || defaults.handoffReasons,
      defaults.handoffReasons.at(-1)
    ),
  };
};

const currentDraftSnapshot = () =>
  draftSnapshot({
    autoCompletionEnabled: state.autoCompletionEnabled,
    completionReasons: state.completionReasons,
    handoffReasons: state.handoffReasons,
  });

watch(
  () => props.assistant,
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
  },
  { immediate: true }
);

let customReasonSequence = 0;
const createCustomReason = type => {
  customReasonSequence += 1;
  return {
    id: `custom_${type}_${Date.now().toString(36)}_${customReasonSequence}`,
    label: '',
    active: true,
  };
};

const addReason = type => {
  if (state[type].length >= MAX_REASONS) return;
  state[type].push(
    createCustomReason(type === 'completionReasons' ? 'completion' : 'handoff')
  );
};

const removeReason = (type, index) => {
  if (state[type][index]?.id === 'other') return;
  state[type].splice(index, 1);
};

const serializedReasons = reasons =>
  reasons.map(reason => ({
    id: reason.id,
    label: reason.label.trim(),
    active: reason.id === 'other' || reason.active !== false,
  }));

const buildPayload = async () => {
  const completionReasons = serializedReasons(state.completionReasons);
  const handoffReasons = serializedReasons(state.handoffReasons);
  const persistedCompletionReasons = state.autoCompletionEnabled
    ? completionReasons
    : completionReasons.filter(reason => reason.label);
  const persistedHandoffReasons = props.handoffEnabled
    ? handoffReasons
    : handoffReasons.filter(reason => reason.label);
  const enabledReasons = [
    ...(state.autoCompletionEnabled ? completionReasons : []),
    ...(props.handoffEnabled ? handoffReasons : []),
  ];

  if (enabledReasons.some(reason => !reason.label)) return null;

  return {
    assistant: {
      config: {
        auto_completion_enabled: state.autoCompletionEnabled,
        outcome_reason_settings: {
          completion_reasons: persistedCompletionReasons,
          handoff_reasons: persistedHandoffReasons,
        },
      },
    },
  };
};

defineExpose({ buildPayload });

const sections = computed(() => [
  ...(props.handoffEnabled
    ? [
        {
          type: 'handoffReasons',
          icon: 'i-lucide-user-round-forward',
          titleKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.HANDOFF.TITLE',
          descriptionKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.HANDOFF.DESCRIPTION',
          reasonsTitleKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.HANDOFF.TITLE',
        },
      ]
    : []),
  {
    type: 'completionReasons',
    enabledKey: 'autoCompletionEnabled',
    icon: 'i-lucide-circle-check-big',
    titleKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.COMPLETION.ENABLE_TITLE',
    descriptionKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.COMPLETION.ENABLE_DESCRIPTION',
    reasonsTitleKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.COMPLETION.TITLE',
  },
]);
</script>

<template>
  <div class="flex flex-col gap-6">
    <SettingsHeader
      :heading="t('CAPTAIN.ASSISTANTS.OUTCOMES.HEADER')"
      :description="t('CAPTAIN.ASSISTANTS.OUTCOMES.DESCRIPTION')"
    />

    <section
      v-for="section in sections"
      :key="section.type"
      :data-testid="`outcome-section-${section.type}`"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <div class="flex items-start justify-between gap-4">
        <div class="flex min-w-0 gap-3">
          <span
            :class="section.icon"
            class="mt-0.5 size-5 shrink-0 text-n-slate-11"
          />
          <div>
            <h4 class="text-sm font-medium text-n-slate-12">
              {{ t(section.titleKey) }}
            </h4>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ t(section.descriptionKey) }}
            </p>
          </div>
        </div>
        <Switch
          v-if="section.type === 'completionReasons'"
          v-model="state.autoCompletionEnabled"
          :data-testid="`outcome-toggle-${section.type}`"
        />
      </div>

      <div
        v-if="section.type === 'handoffReasons' || state.autoCompletionEnabled"
        class="mt-5 flex flex-col gap-3"
      >
        <div class="flex items-center justify-between gap-3">
          <h5
            v-if="section.type === 'completionReasons'"
            class="text-sm font-medium text-n-slate-12"
          >
            {{ t(section.reasonsTitleKey) }}
          </h5>
          <Button
            sm
            slate
            faded
            icon="i-lucide-plus"
            :label="t('CAPTAIN.ASSISTANTS.OUTCOMES.ADD')"
            :disabled="state[section.type].length >= MAX_REASONS"
            :data-testid="`outcome-add-${section.type}`"
            @click="addReason(section.type)"
          />
        </div>

        <div
          v-for="(reason, index) in state[section.type]"
          :key="reason.id"
          data-testid="outcome-reason-row"
          :data-reason-id="reason.id"
          class="flex items-center gap-2 rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2"
        >
          <span class="size-1.5 shrink-0 rounded-full bg-n-slate-8" />
          <input
            v-model="reason.label"
            :aria-label="t(section.titleKey)"
            maxlength="255"
            class="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-n-slate-12 outline-none"
            :placeholder="t('CAPTAIN.ASSISTANTS.OUTCOMES.PLACEHOLDER')"
          />
          <Switch
            v-model="reason.active"
            :disabled="reason.id === 'other'"
            :aria-label="t('CAPTAIN.ASSISTANTS.OUTCOMES.ACTIVE')"
          />
          <button
            v-if="reason.id !== 'other'"
            type="button"
            data-testid="outcome-remove"
            class="flex size-7 shrink-0 items-center justify-center rounded-md text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
            :aria-label="t('CAPTAIN.ASSISTANTS.OUTCOMES.REMOVE')"
            @click="removeReason(section.type, index)"
          >
            <span class="i-lucide-trash-2 size-4" />
          </button>
        </div>
      </div>
    </section>
  </div>
</template>
