<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['confirm']);
const { t } = useI18n();
const dialogRef = ref(null);
const selectedTask = ref(null);
const reason = ref('');

const isDisabled = computed(() => !selectedTask.value || !reason.value.trim());

const open = task => {
  selectedTask.value = task;
  reason.value = '';
  dialogRef.value?.open();
};

const close = () => {
  dialogRef.value?.close();
  selectedTask.value = null;
  reason.value = '';
};

const confirm = () => {
  if (isDisabled.value) return;
  emit('confirm', { task: selectedTask.value, reason: reason.value.trim() });
};

defineExpose({ close, open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="lg"
    :title="t('CRM.TASKS.LIFECYCLE.CANCEL_TITLE')"
    :description="t('CRM.TASKS.LIFECYCLE.CANCEL_DESCRIPTION')"
    :confirm-button-label="t('CRM.TASKS.LIFECYCLE.CANCEL_ACTION')"
    :disable-confirm-button="isDisabled"
    :is-loading="props.isLoading"
    @confirm="confirm"
  >
    <TextArea
      :label="t('CRM.TASKS.LIFECYCLE.CANCEL_REASON')"
      :model-value="reason"
      auto-height
      min-height="6rem"
      @update:model-value="reason = $event"
    />
  </Dialog>
</template>
