<script setup>
import { ref } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import DocumentForm from './DocumentForm.vue';

defineProps({
  assistantId: {
    type: [Number, String],
    default: null,
  },
});

const emit = defineEmits(['close']);
const { t } = useI18n();
const store = useStore();

const dialogRef = ref(null);

const i18nKey = 'CAPTAIN.DOCUMENTS.CREATE';

const handleSubmit = async newDocument => {
  try {
    await store.dispatch('captainDocuments/create', newDocument);
    useAlert(t(`${i18nKey}.SUCCESS_MESSAGE`));
    dialogRef.value.close();
  } catch (error) {
    const errorMessage =
      parseAPIErrorResponse(error) || t(`${i18nKey}.ERROR_MESSAGE`);
    useAlert(errorMessage);
  }
};

const handleClose = () => {
  emit('close');
};

const handleCancel = () => {
  dialogRef.value.close();
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    :title="$t(`${i18nKey}.TITLE`)"
    :description="$t('CAPTAIN.DOCUMENTS.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    overflow-y-auto
    position="top"
    width="xl"
    @close="handleClose"
  >
    <div
      class="flex max-h-[calc(100vh-11rem)] min-h-0 flex-col overflow-hidden"
    >
      <DocumentForm
        class="min-h-0 overflow-y-auto pr-1"
        :assistant-id="assistantId"
        @submit="handleSubmit"
        @cancel="handleCancel"
      />
    </div>
    <template #footer />
  </Dialog>
</template>
