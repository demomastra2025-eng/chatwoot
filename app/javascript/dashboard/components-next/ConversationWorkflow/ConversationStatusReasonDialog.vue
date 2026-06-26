<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const STATUS_KEYS = ['open', 'resolved', 'pending', 'snoozed'];
const CANCELLED = Symbol('conversation-status-reason-cancelled');

const { t } = useI18n();
const { currentAccount } = useAccount();

const dialogRef = ref(null);
const targetStatus = ref('');
const selectedReason = ref('');
const pendingResolver = ref(null);

const normalizeReasons = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];

const normalizedConfig = computed(() => {
  const config =
    currentAccount.value?.settings?.conversation_status_reason_config;
  const safeConfig = config && typeof config === 'object' ? config : {};

  return STATUS_KEYS.reduce((result, status) => {
    const statusConfig = safeConfig[status] || {};
    result[status] = {
      options: normalizeReasons(statusConfig.options),
      required: Boolean(statusConfig.required),
    };
    return result;
  }, {});
});

const statusConfig = computed(
  () =>
    normalizedConfig.value[targetStatus.value] || {
      options: [],
      required: false,
    }
);

const reasonOptions = computed(() =>
  statusConfig.value.options.map(reason => ({ label: reason, value: reason }))
);

const statusLabel = computed(() => {
  switch (targetStatus.value) {
    case 'resolved':
      return t('CONVERSATION.STATUS_REASONS.STATUS.RESOLVED');
    case 'pending':
      return t('CONVERSATION.STATUS_REASONS.STATUS.PENDING');
    case 'snoozed':
      return t('CONVERSATION.STATUS_REASONS.STATUS.SNOOZED');
    case 'open':
    default:
      return t('CONVERSATION.STATUS_REASONS.STATUS.OPEN');
  }
});

const disableConfirm = computed(() => !selectedReason.value);
const showRequiredHint = computed(
  () => statusConfig.value.required && !selectedReason.value
);

const shouldAskForReason = status => {
  const config = normalizedConfig.value[status] || {
    options: [],
    required: false,
  };
  return config.required || config.options.length > 0;
};

const resolvePending = value => {
  const resolver = pendingResolver.value;
  pendingResolver.value = null;
  resolver?.(value);
};

const reset = () => {
  targetStatus.value = '';
  selectedReason.value = '';
};

const handleClose = () => {
  resolvePending(CANCELLED);
  reset();
};

const handleConfirm = () => {
  resolvePending(selectedReason.value || null);
  dialogRef.value?.close();
};

const handleNoReason = () => {
  resolvePending(null);
  dialogRef.value?.close();
};

const open = ({ status, currentReason = '' } = {}) => {
  if (!status || !shouldAskForReason(status)) return Promise.resolve(null);

  targetStatus.value = status;
  const candidate = normalizeReasons([currentReason])[0] || '';
  const configuredValues = new Set(
    reasonOptions.value.map(option => option.value)
  );
  selectedReason.value = configuredValues.has(candidate) ? candidate : '';

  return new Promise(resolve => {
    pendingResolver.value = resolve;
    dialogRef.value?.open();
  });
};

defineExpose({ CANCELLED, open, shouldAskForReason });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="md"
    :title="
      $t('CONVERSATION.STATUS_REASONS.MODAL.TITLE', { status: statusLabel })
    "
    :confirm-button-label="$t('CONVERSATION.STATUS_REASONS.MODAL.CONFIRM')"
    :disable-confirm-button="disableConfirm"
    :show-cancel-button="false"
    show-close-button
    @close="handleClose"
    @confirm="handleConfirm"
  >
    <div class="grid gap-3">
      <p class="mb-0 text-sm text-n-slate-11">
        {{
          statusConfig.required
            ? $t('CONVERSATION.STATUS_REASONS.MODAL.REQUIRED_DESCRIPTION', {
                status: statusLabel,
              })
            : $t('CONVERSATION.STATUS_REASONS.MODAL.OPTIONAL_DESCRIPTION', {
                status: statusLabel,
              })
        }}
      </p>
      <ComboBox
        :model-value="selectedReason"
        :options="reasonOptions"
        :placeholder="$t('CONVERSATION.STATUS_REASONS.MODAL.PLACEHOLDER')"
        :search-placeholder="
          $t('CONVERSATION.STATUS_REASONS.MODAL.SEARCH_PLACEHOLDER')
        "
        :empty-state="$t('CONVERSATION.STATUS_REASONS.MODAL.EMPTY_STATE')"
        input-like
        @update:model-value="selectedReason = $event"
      />
      <p v-if="showRequiredHint" class="mb-0 text-xs text-n-ruby-10">
        {{ $t('CONVERSATION.STATUS_REASONS.MODAL.REQUIRED_HINT') }}
      </p>
    </div>
    <template #footer>
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          v-if="!statusConfig.required"
          variant="faded"
          color="slate"
          class="w-full"
          type="button"
          :label="$t('CONVERSATION.STATUS_REASONS.MODAL.NO_REASON')"
          @click="handleNoReason"
        />
        <Button
          color="blue"
          class="w-full"
          type="submit"
          :label="$t('CONVERSATION.STATUS_REASONS.MODAL.CONFIRM')"
          :disabled="disableConfirm"
        />
      </div>
    </template>
  </Dialog>
</template>
