<script setup>
import { computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { useAccount } from 'dashboard/composables/useAccount';

import CaptainAiEditorSettings from './components/CaptainAiEditorSettings.vue';
import MediaTranscription from './components/MediaTranscription.vue';
import WorkspaceAssignmentPolicySettings from './components/WorkspaceAssignmentPolicySettings.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';

const { t } = useI18n();
const store = useStore();
const { currentAccount } = useAccount();
const { checkPermissions } = usePolicy();
const isWorkspaceReadOnly = computed(
  () => !checkPermissions(['administrator'])
);

onMounted(() => {
  if (!currentAccount.value?.id) store.dispatch('accounts/get');
});
</script>

<template>
  <SettingsLayout :no-records-found="false" class="gap-8">
    <template #header>
      <BaseSettingsHeader
        :title="t('GENERAL_SETTINGS.CONVERSATIONS.TITLE')"
        :description="t('GENERAL_SETTINGS.CONVERSATIONS.DESCRIPTION')"
        feature-name="conversation-settings"
      />
    </template>

    <template #body>
      <div class="flex flex-col gap-8">
        <WorkspaceAssignmentPolicySettings />
        <CaptainAiEditorSettings :disabled="isWorkspaceReadOnly" />
      </div>
      <div class="mt-4 rounded-xl border border-n-weak bg-n-solid-2 px-4">
        <MediaTranscription :disabled="isWorkspaceReadOnly" />
      </div>
    </template>
  </SettingsLayout>
</template>
