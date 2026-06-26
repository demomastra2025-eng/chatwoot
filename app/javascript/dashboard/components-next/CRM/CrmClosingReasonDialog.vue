<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';

const { t } = useI18n();

const REASON_KIND = {
  CLOSING: 'closing',
  TRANSITION: 'transition',
};
const CANCELLED = Symbol('crm-stage-reason-cancelled');

const dialogRef = ref(null);
const stage = ref(null);
const reasonKind = ref(REASON_KIND.CLOSING);
const selectedReasons = ref([]);
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

const reasonOptions = computed(() =>
  configuredReasons.value.map(reason => ({
    label: reason,
    value: reason,
  }))
);

const reasonOptionValues = computed(
  () => new Set(reasonOptions.value.map(option => option.value))
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

const hasSelectedReason = computed(() =>
  isTransitionReason.value
    ? Boolean(selectedReason.value)
    : selectedReasons.value.length > 0
);

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
  selectedReasons.value = [];
  selectedReason.value = '';
};

const handleClose = () => {
  resolvePending(CANCELLED);
  reset();
};

const handleConfirm = () => {
  resolvePending(
    isTransitionReason.value ? selectedReason.value : [...selectedReasons.value]
  );
  dialogRef.value?.close();
};

const handleNoReason = () => {
  resolvePending(isTransitionReason.value ? '' : []);
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
    selectedReason.value = reasonOptionValues.value.has(candidate)
      ? candidate
      : '';
    selectedReasons.value = [];
  } else {
    selectedReasons.value = normalizeReasons(currentReasons).filter(reason =>
      reasonOptionValues.value.has(reason)
    );
    selectedReason.value = '';
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
      <TagMultiSelectComboBox
        v-else
        v-model="selectedReasons"
        :options="reasonOptions"
        :placeholder="placeholderText"
        :search-placeholder="searchPlaceholderText"
        :empty-state="emptyStateText"
        dropdown-placement="auto"
      />
      <p v-if="showRequiredHint" class="mb-0 text-xs text-n-ruby-10">
        {{ requiredHintText }}
      </p>
    </div>
    <template #footer>
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          v-if="!reasonRequired"
          variant="faded"
          color="slate"
          class="w-full"
          type="button"
          :label="noReasonText"
          @click="handleNoReason"
        />
        <Button
          color="blue"
          class="w-full"
          type="submit"
          :label="confirmText"
          :disabled="disableConfirm"
        />
      </div>
    </template>
  </Dialog>
</template>
