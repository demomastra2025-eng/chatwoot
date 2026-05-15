<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CompanyForm from './CompanyForm.vue';
import { useCompaniesStore } from 'dashboard/stores/companies';

const emit = defineEmits(['create']);

const { t } = useI18n();
const companiesStore = useCompaniesStore();

const dialogRef = ref(null);
const companyFormRef = ref(null);
const company = ref(null);
const companyData = ref(null);

const uiFlags = computed(() => companiesStore.getUIFlags);
const isCreatingCompany = computed(() => uiFlags.value.creatingItem);

const createNewCompany = companyItem => {
  company.value = companyItem;
};

const handleDialogConfirm = async () => {
  if (!company.value || companyFormRef.value?.isFormInvalid) return;
  emit('create', company.value);
};

const onSuccess = () => {
  companyFormRef.value?.resetForm();
  company.value = null;
  companyData.value = null;
  dialogRef.value?.close();
};

const openWithPrefill = prefill => {
  companyData.value = prefill || null;
  company.value = prefill || null;
  dialogRef.value?.open();
};

const closeDialog = () => {
  dialogRef.value?.close();
};

defineExpose({ dialogRef, companyFormRef, onSuccess, openWithPrefill });
</script>

<template>
  <Dialog ref="dialogRef" width="xl" @confirm="handleDialogConfirm">
    <CompanyForm
      ref="companyFormRef"
      :company-data="companyData"
      is-new-company
      @update="createNewCompany"
    />
    <template #footer>
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          :label="t('DIALOG.BUTTONS.CANCEL')"
          variant="link"
          type="reset"
          class="h-10 hover:!no-underline hover:text-n-brand"
          @click="closeDialog"
        />
        <Button
          type="submit"
          :label="t('COMPANIES.ACTIONS.ADD')"
          :disabled="companyFormRef?.isFormInvalid"
          :is-loading="isCreatingCompany"
        />
      </div>
    </template>
  </Dialog>
</template>
