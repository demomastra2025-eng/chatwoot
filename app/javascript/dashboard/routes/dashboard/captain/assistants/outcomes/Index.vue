<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import OutcomeReasonSection from './OutcomeReasonSection.vue';
import {
  SYSTEM_REASON_ID,
  insertReason,
  isSystemReason,
  sortReasons,
} from './reasonOrder';

const props = defineProps({
  assistant: {
    type: Object,
    default: () => ({}),
  },
  handoffEnabled: {
    type: Boolean,
    default: true,
  },
  legacyReasons: {
    type: Object,
    default: () => ({}),
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
    [SYSTEM_REASON_ID, 'COMMON.OTHER'],
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
    [SYSTEM_REASON_ID, 'COMMON.OTHER'],
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
          active: isSystemReason(reason) || reason.active !== false,
        }))
    : [];

// Whatever order the API returns, every list is shown with the system reason
// last (see reasonOrder.js).
const withOtherFallback = (reasons, fallback) => {
  const normalized = editableReasons(reasons);
  const other = normalized.find(isSystemReason) || fallback;
  return sortReasons([
    ...normalized
      .filter(reason => !isSystemReason(reason))
      .slice(0, MAX_REASONS - 1),
    { ...other, id: SYSTEM_REASON_ID, active: true },
  ]);
};

const draftSnapshot = value => JSON.stringify(value);

const legacyReasonsFor = (status, type, fallback) => {
  const raw = props.legacyReasons?.[status]?.options;
  const labels = Array.isArray(raw)
    ? raw
        .map(item =>
          typeof item === 'string' ? item : item?.label || item?.value
        )
        .filter(Boolean)
    : [];
  if (!labels.length) return fallback;
  const other = fallback.find(isSystemReason);
  return [
    ...labels.map((label, index) => ({
      id: `legacy_${type}_${index + 1}`,
      label: String(label),
      active: true,
    })),
    other,
  ];
};

const incomingDraft = value => {
  const config = value?.config || {};
  const settings = config.outcome_reason_settings;
  const defaults = defaultReasons();
  const legacyCompletion = legacyReasonsFor(
    'resolved',
    'completion',
    defaults.completionReasons
  );
  const legacyHandoff = legacyReasonsFor(
    'open',
    'handoff',
    defaults.handoffReasons
  );

  return {
    autoCompletionEnabled: config.auto_completion_enabled !== false,
    completionReasons: withOtherFallback(
      settings?.completion_reasons || legacyCompletion,
      defaults.completionReasons.at(-1)
    ),
    handoffReasons: withOtherFallback(
      settings?.handoff_reasons || legacyHandoff,
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
  () => [props.assistant, props.legacyReasons],
  ([value]) => {
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
  state[type] = insertReason(
    state[type],
    createCustomReason(type === 'completionReasons' ? 'completion' : 'handoff')
  );
};

const removeReason = (type, reasonId) => {
  if (reasonId === SYSTEM_REASON_ID) return;
  state[type] = state[type].filter(reason => reason.id !== reasonId);
};

const serializedReasons = reasons =>
  reasons.map(reason => ({
    id: reason.id,
    label: reason.label.trim(),
    active: isSystemReason(reason) || reason.active !== false,
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

// The handoff card has no toggle and its title already names the reason list,
// so it has no separate reasons subheading.
const sections = computed(() => [
  ...(props.handoffEnabled
    ? [
        {
          type: 'handoffReasons',
          icon: 'i-lucide-user-round-forward',
          titleKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.HANDOFF.TITLE',
          descriptionKey: 'CAPTAIN.ASSISTANTS.OUTCOMES.HANDOFF.DESCRIPTION',
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

    <OutcomeReasonSection
      v-for="section in sections"
      :key="section.type"
      v-model:reasons="state[section.type]"
      :type="section.type"
      :icon="section.icon"
      :title="t(section.titleKey)"
      :description="t(section.descriptionKey)"
      :reasons-title="section.reasonsTitleKey ? t(section.reasonsTitleKey) : ''"
      :show-reasons="!section.enabledKey || state[section.enabledKey]"
      :max-reasons="MAX_REASONS"
      @add="addReason(section.type)"
      @remove="reasonId => removeReason(section.type, reasonId)"
    >
      <template v-if="section.enabledKey" #action>
        <Switch
          v-model="state[section.enabledKey]"
          :data-testid="`outcome-toggle-${section.type}`"
        />
      </template>
    </OutcomeReasonSection>
  </div>
</template>
