<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const { t } = useI18n();
const NO_REASON_VALUE = '__crm_no_reason__';
const CANCELLED = Symbol('crm-stage-reason-cancelled');
const dialogRef = ref(null);
const stage = ref(null);
const selectedReason = ref('');
const pendingResolver = ref(null);

const normalizeReasons = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];
const configuredReasons = computed(() =>
  normalizeReasons(stage.value?.closingReasonOptions)
);
const reasonRequired = computed(() =>
  Boolean(stage.value?.closingReasonRequired)
);
const stageName = computed(
  () => stage.value?.name || t('CRM.DEALS.CLOSING_REASONS.STAGE_FALLBACK')
);
const hasSelectedReason = computed(() => Boolean(selectedReason.value));
const disableConfirm = computed(() => !hasSelectedReason.value);
const showRequiredHint = computed(
  () => reasonRequired.value && !hasSelectedReason.value
);
const titleText = computed(() =>
  t('CRM.DEALS.CLOSING_REASONS.TITLE', { stage: stageName.value })
);
const confirmText = computed(() => t('CRM.DEALS.CLOSING_REASONS.CONFIRM'));
const reasonOptions = computed(() => [
  ...(!reasonRequired.value
    ? [
        {
          label: t('CRM.DEALS.CLOSING_REASONS.NO_REASON'),
          value: NO_REASON_VALUE,
        },
      ]
    : []),
  ...configuredReasons.value.map(reason => ({ label: reason, value: reason })),
]);
const reasonOptionValues = computed(
  () => new Set(reasonOptions.value.map(option => option.value))
);
const descriptionText = computed(() =>
  reasonRequired.value
    ? t('CRM.DEALS.CLOSING_REASONS.REQUIRED_DESCRIPTION', {
        stage: stageName.value,
      })
    : t('CRM.DEALS.CLOSING_REASONS.OPTIONAL_DESCRIPTION', {
        stage: stageName.value,
      })
);
const placeholderText = computed(() =>
  t('CRM.DEALS.CLOSING_REASONS.PLACEHOLDER')
);
const searchPlaceholderText = computed(() =>
  t('CRM.DEALS.CLOSING_REASONS.SEARCH_PLACEHOLDER')
);
const emptyStateText = computed(() =>
  t('CRM.DEALS.CLOSING_REASONS.EMPTY_STATE')
);
const requiredHintText = computed(() =>
  t('CRM.DEALS.CLOSING_REASONS.REQUIRED_HINT')
);

const resolvePending = value => {
  const resolver = pendingResolver.value;
  pendingResolver.value = null;
  resolver?.(value);
};
const handleClose = () => {
  resolvePending(CANCELLED);
  stage.value = null;
  selectedReason.value = '';
};
const handleConfirm = () => {
  if (disableConfirm.value) return;
  resolvePending(
    selectedReason.value === NO_REASON_VALUE ? [] : [selectedReason.value]
  );
  dialogRef.value?.close();
};
const open = ({ currentReasons = [], targetStage } = {}) => {
  if (targetStage?.outcome !== 'lost') return Promise.resolve([]);
  stage.value = targetStage;
  const candidate = normalizeReasons(currentReasons).find(reason =>
    reasonOptionValues.value.has(reason)
  );
  selectedReason.value =
    candidate || (reasonRequired.value ? '' : NO_REASON_VALUE);
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
