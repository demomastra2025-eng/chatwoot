<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

// «Выключить?» confirmation shared by the agent gallery and the agent page.
// The page gives the warning texts (see agentSwitchOff.js) and does the
// switching itself on `confirm`.
defineProps({
  description: { type: String, default: '' },
});

const emit = defineEmits(['confirm']);

const { t } = useI18n();
const dialogRef = ref(null);

const open = () => dialogRef.value?.open();
const close = () => dialogRef.value?.close();

const handleConfirm = () => {
  close();
  emit('confirm');
};

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="alert"
    :title="t('CAPTAIN.GALLERY.CONFIRM_DISABLE_TITLE')"
    :description="description"
    :confirm-button-label="t('CAPTAIN.GALLERY.CONFIRM_DISABLE_ACTION')"
    @confirm="handleConfirm"
  />
</template>
