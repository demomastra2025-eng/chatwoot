<script setup>
import { ref, computed } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import CustomToolForm from './CustomToolForm.vue';

const props = defineProps({
  selectedTool: {
    type: Object,
    default: () => ({}),
  },
  type: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit', 'duplicate'].includes(value),
  },
});

const emit = defineEmits(['close']);
const { t } = useI18n();
const store = useStore();

const dialogRef = ref(null);
const formRenderKey = ref(0);

const updateTool = toolDetails =>
  store.dispatch('captainCustomTools/update', {
    id: props.selectedTool.id,
    ...toolDetails,
  });

const dialogCopy = computed(() => {
  if (props.type === 'edit') {
    return {
      title: t('CAPTAIN.CUSTOM_TOOLS.EDIT.TITLE'),
      successMessage: t('CAPTAIN.CUSTOM_TOOLS.EDIT.SUCCESS_MESSAGE'),
      errorMessage: t('CAPTAIN.CUSTOM_TOOLS.EDIT.ERROR_MESSAGE'),
    };
  }

  if (props.type === 'duplicate') {
    return {
      title: t('CAPTAIN.CUSTOM_TOOLS.DUPLICATE.TITLE'),
      successMessage: t('CAPTAIN.CUSTOM_TOOLS.DUPLICATE.SUCCESS_MESSAGE'),
      errorMessage: t('CAPTAIN.CUSTOM_TOOLS.DUPLICATE.ERROR_MESSAGE'),
    };
  }

  return {
    title: t('CAPTAIN.CUSTOM_TOOLS.CREATE.TITLE'),
    successMessage: t('CAPTAIN.CUSTOM_TOOLS.CREATE.SUCCESS_MESSAGE'),
    errorMessage: t('CAPTAIN.CUSTOM_TOOLS.CREATE.ERROR_MESSAGE'),
  };
});

const createTool = toolDetails =>
  store.dispatch('captainCustomTools/create', toolDetails);

const handleSubmit = async updatedTool => {
  try {
    if (props.type === 'edit') {
      await updateTool(updatedTool);
    } else {
      await createTool(updatedTool);
    }
    useAlert(dialogCopy.value.successMessage);
    dialogRef.value.close();
  } catch (error) {
    const errorMessage =
      parseAPIErrorResponse(error) || dialogCopy.value.errorMessage;
    useAlert(errorMessage);
  }
};

const handleClose = () => {
  formRenderKey.value += 1;
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
    width="2xl"
    :render-on-open-only="false"
    :title="dialogCopy.title"
    :description="$t('CAPTAIN.CUSTOM_TOOLS.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="handleClose"
  >
    <CustomToolForm
      :key="`${type}-${selectedTool?.id || 'new'}-${formRenderKey}`"
      :mode="type"
      :tool="selectedTool"
      @submit="handleSubmit"
      @cancel="handleCancel"
    />
    <template #footer />
  </Dialog>
</template>
