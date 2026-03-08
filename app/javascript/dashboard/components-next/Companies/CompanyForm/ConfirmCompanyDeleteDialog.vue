<script setup>
import { ref } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import { useCompaniesStore } from 'dashboard/stores/companies';

const props = defineProps({
  selectedCompany: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['goToCompaniesList']);

const { t } = useI18n();
const route = useRoute();
const companiesStore = useCompaniesStore();

const dialogRef = ref(null);

const deleteCompany = async id => {
  if (!id) return false;

  try {
    await companiesStore.delete(Number(id));
    useAlert(t('COMPANIES.FORM.SUCCESS.DELETE'));
    return true;
  } catch {
    useAlert(t('COMPANIES.FORM.ERROR.DELETE'));
    return false;
  }
};

const handleDialogConfirm = async () => {
  const companyId = route.params.companyId || props.selectedCompany?.id;
  const isDeleted = await deleteCompany(companyId);
  if (!isDeleted) return;
  emit('goToCompaniesList');
  dialogRef.value?.close();
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="alert"
    :title="t('COMPANIES.DETAILS.DELETE_DIALOG.TITLE')"
    :description="t('COMPANIES.DETAILS.DELETE_DIALOG.DESCRIPTION')"
    :confirm-button-label="t('COMPANIES.DETAILS.DELETE_DIALOG.CONFIRM')"
    @confirm="handleDialogConfirm"
  />
</template>
