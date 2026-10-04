<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  canUndo: {
    type: Boolean,
    default: false,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  disabledReason: {
    type: String,
    default: '',
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
  outcome: {
    type: String,
    default: 'open',
  },
});

const emit = defineEmits(['closeLost', 'closeWon', 'reopen', 'undo']);
const { t } = useI18n();
const dialogRef = ref(null);
const pendingAction = ref('');

const isTerminal = computed(() => ['won', 'lost'].includes(props.outcome));
const actionCopy = computed(() => {
  const copies = {
    closeLost: {
      confirm: t('CRM.DEALS.LIFECYCLE.CLOSE_LOST.CONFIRM'),
      description: t('CRM.DEALS.LIFECYCLE.CLOSE_LOST.DESCRIPTION'),
      title: t('CRM.DEALS.LIFECYCLE.CLOSE_LOST.TITLE'),
    },
    closeWon: {
      confirm: t('CRM.DEALS.LIFECYCLE.CLOSE_WON.CONFIRM'),
      description: t('CRM.DEALS.LIFECYCLE.CLOSE_WON.DESCRIPTION'),
      title: t('CRM.DEALS.LIFECYCLE.CLOSE_WON.TITLE'),
    },
    reopen: {
      confirm: t('CRM.DEALS.LIFECYCLE.REOPEN.CONFIRM'),
      description: t('CRM.DEALS.LIFECYCLE.REOPEN.DESCRIPTION'),
      title: t('CRM.DEALS.LIFECYCLE.REOPEN.TITLE'),
    },
    undo: {
      confirm: t('CRM.DEALS.LIFECYCLE.UNDO.CONFIRM'),
      description: t('CRM.DEALS.LIFECYCLE.UNDO.DESCRIPTION'),
      title: t('CRM.DEALS.LIFECYCLE.UNDO.TITLE'),
    },
  };
  return copies[pendingAction.value] || copies.undo;
});

const requestAction = action => {
  pendingAction.value = action;
  dialogRef.value?.open();
};

const confirmAction = () => {
  const action = pendingAction.value;
  dialogRef.value?.close();
  pendingAction.value = '';
  if (action === 'closeLost') emit('closeLost');
  if (action === 'closeWon') emit('closeWon');
  if (action === 'reopen') emit('reopen');
  if (action === 'undo') emit('undo');
};

const clearPendingAction = () => {
  pendingAction.value = '';
};
</script>

<template>
  <div
    class="border-b border-n-weak bg-n-surface-1 px-4 py-2"
    data-test="deal-lifecycle-actions"
  >
    <div class="flex flex-wrap items-center gap-2">
      <Button
        v-if="!isTerminal"
        size="sm"
        color="teal"
        variant="faded"
        icon="i-lucide-trophy"
        :disabled="disabled || isLoading"
        :label="$t('CRM.DEALS.LIFECYCLE.CLOSE_WON.ACTION')"
        data-test="close-won"
        @click="requestAction('closeWon')"
      />
      <Button
        v-if="!isTerminal"
        size="sm"
        color="ruby"
        variant="faded"
        icon="i-lucide-circle-x"
        :disabled="disabled || isLoading"
        :label="$t('CRM.DEALS.LIFECYCLE.CLOSE_LOST.ACTION')"
        data-test="close-lost"
        @click="requestAction('closeLost')"
      />
      <Button
        v-if="isTerminal"
        size="sm"
        color="blue"
        variant="faded"
        icon="i-lucide-rotate-ccw"
        :disabled="disabled || isLoading"
        :label="$t('CRM.DEALS.LIFECYCLE.REOPEN.ACTION')"
        data-test="reopen"
        @click="requestAction('reopen')"
      />
      <Button
        v-if="canUndo"
        size="sm"
        color="slate"
        variant="ghost"
        icon="i-lucide-undo-2"
        :disabled="disabled || isLoading"
        :label="$t('CRM.DEALS.LIFECYCLE.UNDO.ACTION')"
        data-test="undo"
        @click="requestAction('undo')"
      />
      <span
        v-if="disabled && disabledReason"
        class="text-xs text-n-slate-10"
        data-test="disabled-reason"
      >
        {{ disabledReason }}
      </span>
    </div>

    <Dialog
      ref="dialogRef"
      type="alert"
      width="md"
      :title="actionCopy.title"
      :description="actionCopy.description"
      :confirm-button-label="actionCopy.confirm"
      :is-loading="isLoading"
      @close="clearPendingAction"
      @confirm="confirmAction"
    />
  </div>
</template>
