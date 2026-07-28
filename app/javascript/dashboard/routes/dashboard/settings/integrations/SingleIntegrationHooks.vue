<script setup>
import { computed, defineProps, defineEmits, ref } from 'vue';
import { useRoute } from 'vue-router';
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
const route = useRoute();
const { replaceInstallationName } = useBranding();
const { t, locale } = useI18n();

const backButtonUrl = computed(() => ({
  name: 'settings_applications',
  params: { accountId: route.params.accountId },
}));

const connectedHook = computed(() => integration.value?.hooks?.[0]);
const uiFlags = computed(() => store.getters['integrations/getUIFlags']);
const isMedelement = computed(() => props.integrationId === 'medelement');
const isMacrocrm = computed(() => props.integrationId === 'macrocrm');
const medelementMetadata = computed(() => connectedHook.value?.metadata || {});
const macrocrmMetadata = computed(() => connectedHook.value?.metadata || {});
const medelementCatalogFileInput = ref(null);
const medelementCatalogFile = ref(null);
const medelementCatalogMaxBytes = 5 * 1024 * 1024;

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

  if (normalizedHours < 1) {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.EVERY_MINUTES', {
      count: normalizedHours * 60,
    });
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

function resetMedelementCatalogFile() {
  medelementCatalogFile.value = null;
  if (medelementCatalogFileInput.value) {
    medelementCatalogFileInput.value.value = '';
  }
}

function openMedelementCatalogFilePicker() {
  medelementCatalogFileInput.value?.click();
}

function selectMedelementCatalogFile(event) {
  const file = event.target.files?.[0];
  if (!file) return;

  if (!file.name.toLowerCase().endsWith('.json')) {
    resetMedelementCatalogFile();
    useAlert(t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.INVALID_TYPE'));
    return;
  }

  if (file.size > medelementCatalogMaxBytes) {
    resetMedelementCatalogFile();
    useAlert(t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.FILE_TOO_LARGE'));
    return;
  }

  medelementCatalogFile.value = file;
}

function importErrorMessage(error) {
  const errorCode = error?.response?.data?.code;
  const messages = {
    missing_file: t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.MISSING_FILE'),
    file_too_large: t(
      'INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.FILE_TOO_LARGE'
    ),
    invalid_json: t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.INVALID_JSON'),
    invalid_payload: t(
      'INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.INVALID_PAYLOAD'
    ),
    import_in_progress: t(
      'INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.IMPORT_IN_PROGRESS'
    ),
  };
  return (
    messages[errorCode] ||
    t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.GENERIC')
  );
}

async function importMedelementCatalog() {
  if (!medelementCatalogFile.value) return;

  try {
    const response = await store.dispatch('integrations/importHookCatalog', {
      hookId: connectedHook.value.id,
      file: medelementCatalogFile.value,
    });
    useAlert(
      t('INTEGRATION_APPS.MEDELEMENT.IMPORT.SUCCESS', {
        specialists: response?.result?.specialists?.imported_count || 0,
        services: response?.result?.services?.imported_count || 0,
        links: response?.result?.services?.linked_count || 0,
      })
    );
    resetMedelementCatalogFile();
  } catch (error) {
    useAlert(importErrorMessage(error));
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
      :back-button-label="$t('GENERAL_SETTINGS.BACK')"
      :back-button-url="backButtonUrl"
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
          <div class="flex flex-wrap items-start justify-end gap-3">
            <span
              class="inline-flex shrink-0 items-center rounded-full px-3 py-1 text-xs font-medium"
              :class="hookStatusClass"
            >
              {{ hookStatusLabel }}
            </span>
          </div>

          <div
            class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3"
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

          <div v-if="isMedelement" class="mt-4 rounded-md bg-n-alpha-2 p-4">
            <p class="text-sm font-medium text-n-slate-12">
              {{ $t('INTEGRATION_APPS.MEDELEMENT.IMPORT.TITLE') }}
            </p>
            <p class="mt-1 text-sm leading-6 text-n-slate-11">
              {{ $t('INTEGRATION_APPS.MEDELEMENT.IMPORT.DESCRIPTION') }}
              <a
                href="/downloads/medelement-catalog-sample.json"
                download="medelement-catalog-sample.json"
                class="text-n-blue-11"
              >
                {{ $t('INTEGRATION_APPS.MEDELEMENT.IMPORT.DOWNLOAD_SAMPLE') }}
              </a>
            </p>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <NextButton
                faded
                slate
                size="sm"
                icon="i-lucide-upload"
                :label="$t('INTEGRATION_APPS.MEDELEMENT.IMPORT.CHOOSE_FILE')"
                :disabled="uiFlags.isImportingHookCatalog"
                @click="openMedelementCatalogFilePicker"
              />
              <span
                v-if="medelementCatalogFile"
                class="max-w-64 truncate text-sm text-n-slate-11"
              >
                {{ medelementCatalogFile.name }}
              </span>
              <NextButton
                v-if="medelementCatalogFile"
                blue
                size="sm"
                :label="$t('INTEGRATION_APPS.MEDELEMENT.IMPORT.BUTTON')"
                :is-loading="uiFlags.isImportingHookCatalog"
                @click="importMedelementCatalog"
              />
              <input
                ref="medelementCatalogFileInput"
                type="file"
                accept=".json,application/json"
                class="hidden"
                @change="selectMedelementCatalogFile"
              />
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
