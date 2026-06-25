<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';

const { t } = useI18n();

const dialogRef = ref(null);
const stage = ref(null);
const selectedReasons = ref([]);
const pendingResolver = ref(null);

const normalizeReasons = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];

const reasonOptions = computed(() =>
  normalizeReasons(stage.value?.closingReasonOptions).map(reason => ({
    label: reason,
    value: reason,
  }))
);

const reasonOptionValues = computed(
  () => new Set(reasonOptions.value.map(option => option.value))
);

const closingReasonRequired = computed(() =>
  Boolean(stage.value?.closingReasonRequired)
);

const stageName = computed(
  () => stage.value?.name || t('CRM.DEALS.CLOSING_REASONS.STAGE_FALLBACK')
);

const disableConfirm = computed(
  () => closingReasonRequired.value && selectedReasons.value.length === 0
);

const descriptionText = computed(() =>
  closingReasonRequired.value
    ? t('CRM.DEALS.CLOSING_REASONS.REQUIRED_DESCRIPTION', {
        stage: stageName.value,
      })
    : t('CRM.DEALS.CLOSING_REASONS.OPTIONAL_DESCRIPTION', {
        stage: stageName.value,
      })
);

const resolvePending = value => {
  const resolver = pendingResolver.value;
  pendingResolver.value = null;
  resolver?.(value);
};

const reset = () => {
  stage.value = null;
  selectedReasons.value = [];
};

const handleClose = () => {
  resolvePending(null);
  reset();
};

const handleConfirm = () => {
  resolvePending([...selectedReasons.value]);
  dialogRef.value?.close();
};

const open = ({ targetStage, currentReasons = [] } = {}) => {
  stage.value = targetStage || null;
  selectedReasons.value = normalizeReasons(currentReasons).filter(reason =>
    reasonOptionValues.value.has(reason)
  );

  return new Promise(resolve => {
    pendingResolver.value = resolve;
    dialogRef.value?.open();
  });
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="md"
    :title="$t('CRM.DEALS.CLOSING_REASONS.TITLE', { stage: stageName })"
    :confirm-button-label="$t('CRM.DEALS.CLOSING_REASONS.CONFIRM')"
    :disable-confirm-button="disableConfirm"
    @close="handleClose"
    @confirm="handleConfirm"
  >
    <div class="grid gap-3">
      <p class="mb-0 text-sm text-n-slate-11">
        {{ descriptionText }}
      </p>
      <TagMultiSelectComboBox
        v-model="selectedReasons"
        :options="reasonOptions"
        :placeholder="$t('CRM.DEALS.CLOSING_REASONS.PLACEHOLDER')"
        :search-placeholder="$t('CRM.DEALS.CLOSING_REASONS.SEARCH_PLACEHOLDER')"
        :empty-state="$t('CRM.DEALS.CLOSING_REASONS.EMPTY_STATE')"
        dropdown-placement="auto"
      />
      <p
        v-if="closingReasonRequired && selectedReasons.length === 0"
        class="mb-0 text-xs text-n-ruby-10"
      >
        {{ $t('CRM.DEALS.CLOSING_REASONS.REQUIRED_HINT') }}
      </p>
    </div>
  </Dialog>
</template>
