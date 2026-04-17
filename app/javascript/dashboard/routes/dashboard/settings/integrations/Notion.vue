<script setup>
import { ref, computed, onMounted } from 'vue';
import {
  useFunctionGetter,
  useMapGetter,
  useStore,
} from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';

import ButtonNext from 'next/button/Button.vue';
import notionClient from 'dashboard/api/notion_auth.js';

import Integration from './Integration.vue';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';

const { t } = useI18n();
const store = useStore();
const integrationLoaded = ref(false);

const integration = useFunctionGetter('integrations/getIntegration', 'notion');

const uiFlags = useMapGetter('integrations/getUIFlags');

const integrationAction = computed(() => {
  if (integration.value.enabled) {
    return 'disconnect';
  }

  return '';
});

const authorize = async () => {
  const response = await notionClient.generateAuthorization();
  const {
    data: { url },
  } = response;

  window.location.href = url;
};

const initializeNotionIntegration = async () => {
  await store.dispatch('integrations/get', 'notion');
  integrationLoaded.value = true;
};

onMounted(() => {
  initializeNotionIntegration();
});
</script>

<template>
  <SettingsLayout :is-loading="!integrationLoaded || uiFlags.isCreatingNotion">
    <template #header>
      <BaseSettingsHeader
        :title="$t('INTEGRATION_SETTINGS.NOTION.HEADER')"
        :description="integration.description || ''"
        :back-button-label="$t('GENERAL_SETTINGS.BACK')"
        :back-button-url="{
          name: 'settings_applications',
          params: { accountId: $route.params.accountId },
        }"
        feature-name="notion_integration"
      />
    </template>
    <template #body>
      <Integration
        :integration-id="integration.id"
        :integration-logo="integration.logo"
        :integration-name="integration.name"
        :integration-description="integration.description"
        :integration-enabled="integration.enabled"
        :integration-action="integrationAction"
        :show-identity="false"
        :delete-confirmation-text="{
          title: t('INTEGRATION_SETTINGS.NOTION.DELETE.TITLE'),
          message: t('INTEGRATION_SETTINGS.NOTION.DELETE.MESSAGE'),
        }"
      >
        <template #action>
          <ButtonNext
            faded
            blue
            :label="t('INTEGRATION_SETTINGS.CONNECT.BUTTON_TEXT')"
            @click="authorize"
          />
        </template>
      </Integration>
    </template>
  </SettingsLayout>
</template>
