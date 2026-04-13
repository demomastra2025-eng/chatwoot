<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';

import TouchesAPI from 'dashboard/api/touches';
import { useAlert } from 'dashboard/composables';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  selectedTouch: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['deleted']);

const { t } = useI18n();
const dialogRef = ref(null);

const handleDialogConfirm = async () => {
  if (!props.selectedTouch?.id) {
    dialogRef.value?.close();
    return;
  }

  try {
    await TouchesAPI.delete(props.selectedTouch.id);
    useAlert(
      t('OUTBOUND_WORKSPACE.TOUCHES.CONFIRM_DELETE.API.SUCCESS_MESSAGE')
    );
    emit('deleted', props.selectedTouch);
    dialogRef.value?.close();
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('OUTBOUND_WORKSPACE.TOUCHES.CONFIRM_DELETE.API.ERROR_MESSAGE')
    );
  }
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="alert"
    :title="t('OUTBOUND_WORKSPACE.TOUCHES.CONFIRM_DELETE.TITLE')"
    :description="t('OUTBOUND_WORKSPACE.TOUCHES.CONFIRM_DELETE.DESCRIPTION')"
    :confirm-button-label="
      t('OUTBOUND_WORKSPACE.TOUCHES.CONFIRM_DELETE.CONFIRM')
    "
    @confirm="handleDialogConfirm"
  />
</template>
