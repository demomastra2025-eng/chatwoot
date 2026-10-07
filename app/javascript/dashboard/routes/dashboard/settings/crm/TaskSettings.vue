<script setup>
import { computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';

import { usePolicy } from 'dashboard/composables/usePolicy';
import CrmTaskCatalogSettings from 'dashboard/components-next/CRM/CrmTaskCatalogSettings.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';

const referencesStore = useCrmReferencesStore();
const { checkPermissions } = usePolicy();
const { t } = useI18n();

const canManage = computed(() =>
  checkPermissions(['administrator', 'crm_settings_manage'])
);
const loadTaskSettings = () =>
  referencesStore.loadTaskTypes({ include_inactive: true });
const formatErrorMessage = error => formatCrmErrorMessage(error, t);

onMounted(loadTaskSettings);
</script>

<template>
  <SettingsLayout
    :is-loading="referencesStore.ui.isLoadingTaskTypes"
    :loading-message="$t('CRM.SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('CRM.SETTINGS.TASK_SETTINGS.TITLE')"
        :description="$t('CRM.SETTINGS.TASK_SETTINGS.DESCRIPTION')"
      />
    </template>

    <template #loading>
      <div class="flex justify-center py-16">
        <Spinner class="!h-8 !w-8" />
      </div>
    </template>

    <template #body>
      <SchedulingErrorState
        v-if="referencesStore.ui.error"
        :title="$t('CRM.ERRORS.LOAD_TITLE')"
        :description="formatErrorMessage(referencesStore.ui.error)"
        @retry="loadTaskSettings"
      />
      <CrmTaskCatalogSettings :can-manage="canManage" />
    </template>
  </SettingsLayout>
</template>
