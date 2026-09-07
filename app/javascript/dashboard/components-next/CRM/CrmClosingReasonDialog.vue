<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const { t } = useI18n();

const REASON_KIND = {
  CLOSING: 'closing',
  TRANSITION: 'transition',
};
const NO_REASON_VALUE = '__crm_no_reason__';
const CANCELLED = Symbol('crm-stage-reason-cancelled');

const dialogRef = ref(null);
const stage = ref(null);
const reasonKind = ref(REASON_KIND.CLOSING);
const selectedReason = ref('');
const pendingResolver = ref(null);

const normalizeReasons = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];

const isTransitionReason = computed(
  () => reasonKind.value === REASON_KIND.TRANSITION
);

const configuredReasons = computed(() =>
  isTransitionReason.value
    ? normalizeReasons(stage.value?.transitionReasonOptions)
    : normalizeReasons(stage.value?.closingReasonOptions)
);

const reasonRequired = computed(() =>
  isTransitionReason.value
    ? Boolean(stage.value?.transitionReasonRequired)
    : Boolean(stage.value?.closingReasonRequired)
);

const stageName = computed(() => {
  if (stage.value?.name) return stage.value.name;

  return isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.STAGE_FALLBACK')
    : t('CRM.DEALS.CLOSING_REASONS.STAGE_FALLBACK');
});

const hasSelectedReason = computed(() => Boolean(selectedReason.value));

const disableConfirm = computed(() => !hasSelectedReason.value);

const showRequiredHint = computed(
  () => reasonRequired.value && !hasSelectedReason.value
);

const titleText = computed(() =>
  isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.TITLE', { stage: stageName.value })
    : t('CRM.DEALS.CLOSING_REASONS.TITLE', { stage: stageName.value })
);

const confirmText = computed(() =>
  isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.CONFIRM')
    : t('CRM.DEALS.CLOSING_REASONS.CONFIRM')
);

const noReasonText = computed(() =>
  isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.NO_REASON')
    : t('CRM.DEALS.CLOSING_REASONS.NO_REASON')
);

const reasonOptions = computed(() => [
  ...(!reasonRequired.value
    ? [{ label: noReasonText.value, value: NO_REASON_VALUE }]
    : []),
  ...configuredReasons.value.map(reason => ({
    label: reason,
    value: reason,
  })),
]);

const reasonOptionValues = computed(
  () => new Set(reasonOptions.value.map(option => option.value))
);

const descriptionText = computed(() => {
  if (isTransitionReason.value) {
    return reasonRequired.value
      ? t('CRM.DEALS.TRANSITION_REASONS.REQUIRED_DESCRIPTION', {
          stage: stageName.value,
        })
      : t('CRM.DEALS.TRANSITION_REASONS.OPTIONAL_DESCRIPTION', {
          stage: stageName.value,
        });
  }

  return reasonRequired.value
    ? t('CRM.DEALS.CLOSING_REASONS.REQUIRED_DESCRIPTION', {
        stage: stageName.value,
      })
    : t('CRM.DEALS.CLOSING_REASONS.OPTIONAL_DESCRIPTION', {
        stage: stageName.value,
      });
});

const placeholderText = computed(() =>
  isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.PLACEHOLDER')
    : t('CRM.DEALS.CLOSING_REASONS.PLACEHOLDER')
);

const searchPlaceholderText = computed(() =>
  isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.SEARCH_PLACEHOLDER')
    : t('CRM.DEALS.CLOSING_REASONS.SEARCH_PLACEHOLDER')
);

const emptyStateText = computed(() =>
  isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.EMPTY_STATE')
    : t('CRM.DEALS.CLOSING_REASONS.EMPTY_STATE')
);

const requiredHintText = computed(() =>
  isTransitionReason.value
    ? t('CRM.DEALS.TRANSITION_REASONS.REQUIRED_HINT')
    : t('CRM.DEALS.CLOSING_REASONS.REQUIRED_HINT')
);

const resolvePending = value => {
  const resolver = pendingResolver.value;
  pendingResolver.value = null;
  resolver?.(value);
};

const reset = () => {
  stage.value = null;
  reasonKind.value = REASON_KIND.CLOSING;
  selectedReason.value = '';
};

const handleClose = () => {
  resolvePending(CANCELLED);
  reset();
};

const handleConfirm = () => {
  const noReasonSelected = selectedReason.value === NO_REASON_VALUE;
  let resolvedValue = selectedReason.value;

  if (noReasonSelected) {
    resolvedValue = isTransitionReason.value ? '' : [];
  } else if (!isTransitionReason.value) {
    resolvedValue = [selectedReason.value];
  }

  resolvePending(resolvedValue);
  dialogRef.value?.close();
};

const open = ({
  currentReason = '',
  currentReasons = [],
  kind = REASON_KIND.CLOSING,
  targetStage,
} = {}) => {
  stage.value = targetStage || null;
  reasonKind.value =
    kind === REASON_KIND.TRANSITION ? kind : REASON_KIND.CLOSING;

  if (isTransitionReason.value) {
    const candidate = normalizeReasons([currentReason])[0] || '';
    const fallback = reasonRequired.value ? '' : NO_REASON_VALUE;
    selectedReason.value = reasonOptionValues.value.has(candidate)
      ? candidate
      : fallback;
  } else {
    const candidate = normalizeReasons(currentReasons).find(reason =>
      reasonOptionValues.value.has(reason)
    );
    selectedReason.value =
      candidate || (reasonRequired.value ? '' : NO_REASON_VALUE);
  }

  return new Promise(resolve => {
    pendingResolver.value = resolve;
    dialogRef.value?.open();
  });
};

defineExpose({ CANCELLED, open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="md"
    :title="titleText"
    :confirm-button-label="confirmText"
    :disable-confirm-button="disableConfirm"
    :show-cancel-button="false"
    show-close-button
    @close="handleClose"
    @confirm="handleConfirm"
  >
    <div class="grid gap-3">
      <p class="mb-0 text-sm text-n-slate-11">
        {{ descriptionText }}
      </p>
      <ComboBox
        v-if="isTransitionReason"
        :model-value="selectedReason"
        :options="reasonOptions"
        :placeholder="placeholderText"
        :search-placeholder="searchPlaceholderText"
        :empty-state="emptyStateText"
        input-like
        @update:model-value="selectedReason = $event"
      />
      <ComboBox
        v-else
        :model-value="selectedReason"
        :options="reasonOptions"
        :placeholder="placeholderText"
        :search-placeholder="searchPlaceholderText"
        :empty-state="emptyStateText"
        input-like
        @update:model-value="selectedReason = $event"
      />
      <p v-if="showRequiredHint" class="mb-0 text-xs text-n-ruby-10">
        {{ requiredHintText }}
      </p>
    </div>
  </Dialog>
</template>
