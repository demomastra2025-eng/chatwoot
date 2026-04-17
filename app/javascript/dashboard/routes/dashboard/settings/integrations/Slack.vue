<script setup>
import { ref, computed, onMounted } from 'vue';
import { useStore } from 'vuex';
import { useRouter, useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Integration from './Integration.vue';
import SelectChannelWarning from './Slack/SelectChannelWarning.vue';
import SlackIntegrationHelpText from './Slack/SlackIntegrationHelpText.vue';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  code: { type: String, default: '' },
});

const store = useStore();
const router = useRouter();
const route = useRoute();
const { t } = useI18n();

const integrationLoaded = ref(false);
const isSlackConfigured = computed(
  () => !!window.chatwootConfig?.slackConfigured
);

const integration = computed(() => {
  return store.getters['integrations/getIntegration']('slack');
});

const areHooksAvailable = computed(() => {
  const { hooks = [] } = integration.value || {};
  return !!hooks.length;
});

const hook = computed(() => {
  const { hooks = [] } = integration.value || {};
  const [firstHook] = hooks;
  return firstHook || {};
});

const isIntegrationHookEnabled = computed(() => {
  return hook.value.status || false;
});

const hasConnectedAChannel = computed(() => {
  return !!hook.value.reference_id;
});

const selectedChannelName = computed(() => {
  if (hook.value.status) {
    const { settings: { channel_name: channelName = '' } = {} } = hook.value;
    return channelName || 'customer-conversations';
  }
  return t('INTEGRATION_SETTINGS.SLACK.HELP_TEXT.SELECTED');
});

const uiFlags = computed(() => store.getters['integrations/getUIFlags']);

const integrationAction = computed(() => {
  if (!isSlackConfigured.value) {
    return '';
  }
  if (integration.value.enabled) {
    return 'disconnect';
  }
  return integration.value.action;
});

const intializeSlackIntegration = async () => {
  await store.dispatch('integrations/get', 'slack');
  if (props.code) {
    await store.dispatch('integrations/connectSlack', props.code);
    // Clear the query param `code` from the URL as the
    // subsequent reloads would result in an error
    router.replace(route.path);
  }
  integrationLoaded.value = true;
};

onMounted(() => {
  intializeSlackIntegration();
});
</script>

<template>
  <SettingsLayout :is-loading="!integrationLoaded || uiFlags.isCreatingSlack">
    <template #header>
      <BaseSettingsHeader
        :title="$t('INTEGRATION_SETTINGS.SLACK.HEADER')"
        :description="integration.description || ''"
        :back-button-label="$t('GENERAL_SETTINGS.BACK')"
        :back-button-url="{
          name: 'settings_applications',
          params: { accountId: $route.params.accountId },
        }"
        feature-name="slack_integration"
      />
    </template>
    <template #body>
      <div class="space-y-5">
        <Integration
          :integration-id="integration.id"
          :integration-logo="integration.logo"
          :integration-name="integration.name"
          :integration-description="integration.description"
          :integration-enabled="integration.enabled"
          :integration-action="integrationAction"
          :show-identity="false"
          :action-button-text="$t('INTEGRATION_SETTINGS.SLACK.DELETE')"
          :delete-confirmation-text="{
            title: $t('INTEGRATION_SETTINGS.SLACK.DELETE_CONFIRMATION.TITLE'),
            message: $t(
              'INTEGRATION_SETTINGS.SLACK.DELETE_CONFIRMATION.MESSAGE'
            ),
          }"
        >
          <template v-if="!isSlackConfigured" #action>
            <Button
              faded
              slate
              disabled
              :label="$t('INTEGRATION_SETTINGS.SLACK.NOT_CONFIGURED.BUTTON')"
            />
          </template>
        </Integration>
        <div
          v-if="!isSlackConfigured"
          class="rounded-xl border border-n-weak bg-n-alpha-2 p-4 text-n-slate-11"
        >
          <p class="text-heading-3 text-n-slate-12">
            {{ $t('INTEGRATION_SETTINGS.SLACK.NOT_CONFIGURED.TITLE') }}
          </p>
          <p class="mt-1 text-body-main">
            {{ $t('INTEGRATION_SETTINGS.SLACK.NOT_CONFIGURED.DESCRIPTION') }}
          </p>
        </div>
        <div v-if="areHooksAvailable" class="flex-1">
          <SelectChannelWarning
            v-if="!isIntegrationHookEnabled"
            :has-connected-a-channel="hasConnectedAChannel"
          />
          <SlackIntegrationHelpText
            :selected-channel-name="selectedChannelName"
          />
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
