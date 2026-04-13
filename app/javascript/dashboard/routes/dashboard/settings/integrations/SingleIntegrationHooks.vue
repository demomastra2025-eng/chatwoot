<script setup>
import { computed, defineProps, defineEmits } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import { useIntegrationHook } from 'dashboard/composables/useIntegrationHook';
import { useBranding } from 'shared/composables/useBranding';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  integrationId: {
    type: String,
    required: true,
  },
});

defineEmits(['add', 'edit', 'delete']);

const { integration, hasConnectedHooks } = useIntegrationHook(
  props.integrationId
);

const store = useStore();
const { replaceInstallationName } = useBranding();
const { t, locale } = useI18n();

const connectedHook = computed(() => integration.value?.hooks?.[0]);
const uiFlags = computed(() => store.getters['integrations/getUIFlags']);
const isMedelement = computed(() => props.integrationId === 'medelement');
const isMacrocrm = computed(() => props.integrationId === 'macrocrm');
const medelementMetadata = computed(() => connectedHook.value?.metadata || {});
const macrocrmMetadata = computed(() => connectedHook.value?.metadata || {});

const hasCustomLogo = computed(
  () =>
    !!integration.value?.logo &&
    integration.value.logo !== `${props.integrationId}.png`
);

const lightLogoSource = computed(() =>
  integration.value?.logo
    ? `/dashboard/images/integrations/${integration.value.logo}`
    : `/dashboard/images/integrations/${props.integrationId}.png`
);

const darkLogoSource = computed(() =>
  hasCustomLogo.value
    ? lightLogoSource.value
    : `/dashboard/images/integrations/${props.integrationId}-dark.png`
);

const visibleProperties = computed(
  () => integration.value?.visible_properties || []
);

const formItemLabelMap = computed(() =>
  Object.fromEntries(
    (integration.value?.settings_form_schema || []).map(item => [
      item.name,
      item.label,
    ])
  )
);

const headerDescription = computed(() =>
  replaceInstallationName(
    integration.value?.short_description || integration.value?.description || ''
  )
);

const headerFeatureName = computed(() =>
  ['dashboard_apps', 'webhook'].includes(props.integrationId)
    ? props.integrationId
    : 'integrations'
);

function humanizeProperty(property) {
  return property
    .split('_')
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function formatFrequency(hours) {
  const normalizedHours = Number(hours);
  if (!normalizedHours) {
    return '--';
  }

  if (normalizedHours === 24) {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.DAILY');
  }

  if (normalizedHours === 1) {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.HOURLY');
  }

  if (locale.value === 'ru') {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.EVERY_HOURS_RU', {
      count: normalizedHours,
    });
  }

  return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.EVERY_HOURS', {
    count: normalizedHours,
  });
}

function formatValue(value, key = null) {
  if (key === 'sync_interval_hours') {
    return formatFrequency(value);
  }

  if (typeof value === 'boolean') {
    return value
      ? t('INTEGRATION_APPS.STATUS.ENABLED')
      : t('INTEGRATION_APPS.STATUS.DISABLED');
  }

  return value || '--';
}

const hookStatusLabel = computed(() =>
  connectedHook.value?.status
    ? t('INTEGRATION_APPS.STATUS.ENABLED')
    : t('INTEGRATION_APPS.STATUS.DISABLED')
);

const hookStatusClass = computed(() =>
  connectedHook.value?.status
    ? 'bg-n-teal-9 text-white'
    : 'bg-n-slate-8 text-white'
);

const hookDetails = computed(() => {
  if (!connectedHook.value) {
    return [];
  }

  return visibleProperties.value.map(property => ({
    key: property,
    label: formItemLabelMap.value[property] || humanizeProperty(property),
    value: formatValue(connectedHook.value.settings?.[property], property),
  }));
});

const medelementScheduleDetails = computed(() => {
  if (!isMedelement.value || !connectedHook.value) {
    return [];
  }

  return [
    {
      key: 'next_sync_at',
      label: t('INTEGRATION_APPS.MEDELEMENT.NEXT_SYNC'),
      value: medelementMetadata.value.next_sync_at_display || '--',
    },
    {
      key: 'last_scheduled_sync_at',
      label: t('INTEGRATION_APPS.MEDELEMENT.LAST_SYNC'),
      value: medelementMetadata.value.last_scheduled_sync_at_display || '--',
    },
  ];
});

const macrocrmWebhookUrl = computed(
  () => macrocrmMetadata.value.webhook_url || ''
);

const macrocrmWebhookKey = computed(
  () => connectedHook.value?.reference_id || ''
);

async function runSyncNow() {
  try {
    const response = await store.dispatch(
      'integrations/runHookSync',
      connectedHook.value.id
    );
    useAlert(
      response?.message || t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.SUCCESS')
    );
  } catch (error) {
    const errorMessage =
      error?.response?.data?.message ||
      t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.ERROR');
    useAlert(errorMessage);
  }
}

async function copyMacrocrmWebhookUrl() {
  if (!macrocrmWebhookUrl.value) {
    return;
  }

  try {
    await copyTextToClipboard(macrocrmWebhookUrl.value);
    useAlert(t('INTEGRATION_APPS.MACROCRM.WEBHOOK.COPY_SUCCESS'));
  } catch (error) {
    useAlert(error.message);
  }
}
</script>

<template>
  <div class="flex flex-col flex-1 gap-8 overflow-auto">
    <BaseSettingsHeader
      :title="integration.name"
      :description="headerDescription"
      :feature-name="headerFeatureName"
      :back-button-label="$t('INTEGRATION_SETTINGS.HEADER')"
    >
      <template #actions>
        <div v-if="hasConnectedHooks" class="flex gap-2">
          <NextButton
            v-if="isMedelement && connectedHook?.status"
            blue
            :label="$t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.BUTTON')"
            :is-loading="uiFlags.isRunningHookSync"
            @click="runSyncNow"
          />
          <NextButton
            faded
            slate
            :label="$t('INTEGRATION_APPS.CONFIGURE')"
            @click="$emit('edit', connectedHook)"
          />
          <NextButton
            faded
            ruby
            :label="$t('INTEGRATION_APPS.DISCONNECT.BUTTON_TEXT')"
            @click="$emit('delete', connectedHook)"
          />
        </div>
        <NextButton
          v-else
          blue
          :label="$t('INTEGRATION_APPS.CONNECT.BUTTON_TEXT')"
          @click="$emit('add')"
        />
      </template>
    </BaseSettingsHeader>

    <div
      v-if="hasConnectedHooks"
      class="outline outline-n-container outline-1 bg-n-alpha-3 rounded-md shadow p-6"
    >
      <div class="flex flex-col gap-6 lg:flex-row lg:items-start">
        <div class="flex h-16 w-16 shrink-0 items-center justify-center">
          <img
            :src="lightLogoSource"
            class="max-w-full rounded-md border border-n-weak shadow-sm block dark:hidden bg-n-alpha-3 dark:bg-n-alpha-2"
          />
          <img
            :src="darkLogoSource"
            class="max-w-full rounded-md border border-n-weak shadow-sm hidden dark:block bg-n-alpha-3 dark:bg-n-alpha-2"
          />
        </div>
        <div class="min-w-0 flex-1">
          <div
            class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between"
          >
            <div class="min-w-0">
              <h3 class="text-xl font-medium text-n-slate-12">
                {{ integration.name }}
              </h3>
              <p class="mt-2 text-sm leading-6 text-n-slate-11">
                {{ replaceInstallationName(integration.description) }}
              </p>
            </div>
            <span
              class="inline-flex shrink-0 items-center rounded-full px-3 py-1 text-xs font-medium"
              :class="hookStatusClass"
            >
              {{ hookStatusLabel }}
            </span>
          </div>

          <div
            class="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3"
          >
            <div
              v-for="detail in hookDetails"
              :key="detail.key"
              class="rounded-md bg-n-alpha-2 px-4 py-3"
            >
              <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                {{ detail.label }}
              </p>
              <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                {{ detail.value }}
              </p>
            </div>
          </div>

          <div
            v-if="medelementScheduleDetails.length"
            class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2"
          >
            <div
              v-for="detail in medelementScheduleDetails"
              :key="detail.key"
              class="rounded-md bg-n-alpha-2 px-4 py-3"
            >
              <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                {{ detail.label }}
              </p>
              <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                {{ detail.value }}
              </p>
            </div>
          </div>

          <div
            v-if="isMacrocrm && macrocrmWebhookUrl"
            class="mt-4 rounded-md bg-n-alpha-2 p-4"
          >
            <p class="text-sm leading-6 text-n-slate-11">
              {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.DESCRIPTION') }}
            </p>

            <div class="mt-3 flex flex-wrap gap-2">
              <span
                class="inline-flex items-center rounded-full bg-n-alpha-3 px-3 py-1 text-xs font-medium text-n-slate-12"
              >
                {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.METHOD') }}
              </span>
              <span
                class="inline-flex items-center rounded-full bg-n-alpha-3 px-3 py-1 text-xs font-medium text-n-slate-12"
              >
                {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.EVENT') }}
              </span>
            </div>

            <div
              class="mt-4 flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between"
            >
              <div class="min-w-0 flex-1">
                <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                  {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.URL_LABEL') }}
                </p>
                <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                  {{ macrocrmWebhookUrl }}
                </p>
              </div>
              <NextButton
                faded
                slate
                size="sm"
                icon="i-lucide-clipboard"
                :label="$t('INTEGRATION_APPS.MACROCRM.WEBHOOK.COPY')"
                @click="copyMacrocrmWebhookUrl"
              />
            </div>

            <div v-if="macrocrmWebhookKey" class="mt-4">
              <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.KEY_LABEL') }}
              </p>
              <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                {{ macrocrmWebhookKey }}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-else
      class="outline outline-n-container outline-1 bg-n-alpha-3 rounded-md shadow p-8 text-center text-sm text-n-slate-11"
    >
      {{
        $t('INTEGRATION_APPS.NO_HOOK_CONFIGURED', {
          integrationId: integration.id,
        })
      }}
    </div>
  </div>
</template>
