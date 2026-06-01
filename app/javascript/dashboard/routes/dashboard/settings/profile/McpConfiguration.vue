<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import McpSettingsAPI from 'dashboard/api/mcpSettings';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

const props = defineProps({
  accessToken: { type: String, default: '' },
});

const { t } = useI18n();
const { accountId, currentAccount } = useAccount();

const MCP_SETTINGS_TIMEOUT_MS = 8000;
const tokenPlaceholder = '<profile_access_token>';
const mcpServerName = computed(() => `onelink-account-${accountId.value}`);
const baseOrigin = computed(() => {
  if (typeof window === 'undefined') return '';

  return window.location.origin;
});
const endpointPath = computed(() => `/api/v1/accounts/${accountId.value}/mcp`);
const endpointUrl = computed(() => `${baseOrigin.value}${endpointPath.value}`);
const accountName = computed(
  () =>
    currentAccount.value?.name ||
    t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CURRENT_WORKSPACE')
);

const settingsPayload = ref(null);
const isFetchingSettings = ref(false);
const isSavingSettings = ref(false);
const settingsLoadFailed = ref(false);
const accessForm = reactive({
  enabled: true,
  sources: {
    captain: true,
    openapi_read: true,
    openapi_write: false,
  },
  max_risk_level: 'low',
  require_confirmation_for_mutations: true,
  allowed_groups: [],
});

const buildMcpConfig = token => ({
  mcpServers: {
    [mcpServerName.value]: {
      type: 'http',
      url: endpointUrl.value,
      headers: {
        Authorization: `Bearer ${token}`,
      },
    },
  },
});

const configPreview = computed(() =>
  JSON.stringify(buildMcpConfig(tokenPlaceholder), null, 2)
);
const configForClipboard = computed(() =>
  JSON.stringify(buildMcpConfig(props.accessToken || tokenPlaceholder), null, 2)
);

const hasLoadedSettings = computed(() => settingsPayload.value !== null);
const canManageMcpAccess = computed(
  () => settingsPayload.value?.permissions?.manage === true
);
const accessControlsDisabled = computed(
  () =>
    isFetchingSettings.value ||
    settingsLoadFailed.value ||
    !canManageMcpAccess.value
);
const showReadOnlyNotice = computed(
  () =>
    hasLoadedSettings.value &&
    !settingsLoadFailed.value &&
    !canManageMcpAccess.value
);
const mcpSummary = computed(() => settingsPayload.value?.summary || {});
const mcpGroups = computed(() => settingsPayload.value?.groups || []);
const allGroupIds = computed(() => mcpGroups.value.map(group => group.id));
const selectedGroupIds = computed({
  get() {
    return accessForm.allowed_groups.length
      ? accessForm.allowed_groups
      : allGroupIds.value;
  },
  set(values) {
    const normalizedValues = [...new Set(values)];
    accessForm.allowed_groups =
      normalizedValues.length === allGroupIds.value.length
        ? []
        : normalizedValues;
  },
});

const sourceItems = computed(() => {
  const sourceCounts = settingsPayload.value?.sources || [];
  const sourceById = sourceCounts.reduce((acc, source) => {
    acc[source.id] = source;
    return acc;
  }, {});

  return [
    {
      id: 'captain',
      label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.captain'),
    },
    {
      id: 'openapi_read',
      label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.openapi_read'),
    },
    {
      id: 'openapi_write',
      label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.openapi_write'),
    },
  ].map(source => ({
    ...source,
    toolsCount: sourceById[source.id]?.tools_count || 0,
    enabledToolsCount: sourceById[source.id]?.enabled_tools_count || 0,
  }));
});

const riskOptions = computed(() => [
  {
    value: 'low',
    label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.RISK.low'),
  },
  {
    value: 'medium',
    label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.RISK.medium'),
  },
  {
    value: 'high',
    label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.RISK.high'),
  },
  {
    value: 'custom',
    label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.RISK.custom'),
  },
]);

const toolCountLabel = (enabled, total) =>
  t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.TOOLS_ENABLED_COUNT', {
    enabled,
    total,
  });

const hydrateAccessForm = payload => {
  const access = payload?.mcp_access || {};
  accessForm.enabled = access.enabled !== false;
  accessForm.sources = {
    captain: access.sources?.captain !== false,
    openapi_read: access.sources?.openapi_read !== false,
    openapi_write: access.sources?.openapi_write === true,
  };
  accessForm.max_risk_level = access.max_risk_level || 'low';
  accessForm.require_confirmation_for_mutations =
    access.require_confirmation_for_mutations !== false;
  accessForm.allowed_groups = Array.isArray(access.allowed_groups)
    ? [...access.allowed_groups]
    : [];
};

const serializedAccessForm = () => ({
  enabled: accessForm.enabled,
  sources: { ...accessForm.sources },
  max_risk_level: accessForm.max_risk_level,
  require_confirmation_for_mutations:
    accessForm.require_confirmation_for_mutations,
  allowed_groups: [...accessForm.allowed_groups],
});

const fetchMcpSettings = async () => {
  isFetchingSettings.value = true;
  settingsLoadFailed.value = false;
  try {
    const { data } = await McpSettingsAPI.get({
      timeout: MCP_SETTINGS_TIMEOUT_MS,
    });
    settingsPayload.value = data;
    hydrateAccessForm(data);
  } catch (error) {
    settingsLoadFailed.value = true;
  } finally {
    isFetchingSettings.value = false;
  }
};

const saveMcpSettings = async () => {
  isSavingSettings.value = true;
  try {
    const { data } = await McpSettingsAPI.update(
      {
        mcp_access: serializedAccessForm(),
      },
      { timeout: MCP_SETTINGS_TIMEOUT_MS }
    );
    settingsPayload.value = data;
    hydrateAccessForm(data);
    useAlert(t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_SAVED'));
  } catch (error) {
    useAlert(t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_SAVE_ERROR'));
  } finally {
    isSavingSettings.value = false;
  }
};

const copyValue = async value => {
  await copyTextToClipboard(value);
  useAlert(t('COMPONENTS.CODE.COPY_SUCCESSFUL'));
};

const copyConfig = () => copyValue(configForClipboard.value);

onMounted(fetchMcpSettings);
</script>

<template>
  <div class="flex w-full flex-col gap-6">
    <section class="flex flex-col gap-4">
      <div class="flex flex-col gap-1">
        <div class="flex items-center gap-2">
          <span class="i-lucide-plug-zap size-4 text-n-slate-10" />
          <h5 class="mb-0 text-heading-3 text-n-slate-12">
            {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CARD_TITLE') }}
          </h5>
        </div>
        <div class="text-sm text-n-slate-11">
          {{ accountName }}
        </div>
      </div>

      <div class="grid gap-4">
        <div class="flex flex-col gap-1.5">
          <label
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ENDPOINT_LABEL') }}
          </label>
          <code class="break-all font-mono text-xs text-n-slate-12">
            {{ endpointUrl }}
          </code>
        </div>

        <div class="flex flex-col gap-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CONFIG_TITLE') }}
            </div>
            <Button
              size="sm"
              color="slate"
              variant="outline"
              icon="i-lucide-copy"
              :label="t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.COPY_CONFIG')"
              class="rounded-xl"
              @click="copyConfig"
            />
          </div>
          <pre
            class="max-h-64 overflow-auto rounded-xl bg-n-alpha-1 p-3 text-xs text-n-slate-12"
          ><code>{{ configPreview }}</code></pre>
        </div>
      </div>
    </section>

    <section class="flex flex-col gap-4">
      <div
        class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
      >
        <div class="flex items-center gap-2">
          <span class="i-lucide-sliders-horizontal size-4 text-n-slate-10" />
          <h5 class="mb-0 text-heading-3 text-n-slate-12">
            {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_TITLE') }}
          </h5>
          <span
            v-if="isFetchingSettings"
            class="i-lucide-loader-circle size-3.5 animate-spin text-n-slate-8"
          />
        </div>
        <Button
          v-if="canManageMcpAccess"
          size="sm"
          color="blue"
          icon="i-lucide-save"
          :is-loading="isSavingSettings"
          :disabled="isFetchingSettings || settingsLoadFailed"
          :label="t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SAVE_ACCESS')"
          @click="saveMcpSettings"
        />
      </div>

      <div v-if="settingsLoadFailed" class="text-xs leading-5 text-n-ruby-11">
        {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_LOAD_ERROR') }}
      </div>

      <div class="grid gap-4">
        <div class="grid gap-2 sm:grid-cols-3">
          <label
            class="flex items-start gap-3 rounded-lg p-2 transition-colors hover:bg-n-alpha-1"
          >
            <Checkbox
              v-model="accessForm.enabled"
              :disabled="accessControlsDisabled"
              class="mt-0.5 shrink-0"
            />
            <span class="min-w-0">
              <span class="block text-sm font-medium text-n-slate-12">
                {{
                  t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_ENABLED')
                }}
              </span>
            </span>
          </label>

          <label
            class="flex items-start gap-3 rounded-lg p-2 transition-colors hover:bg-n-alpha-1"
          >
            <Checkbox
              v-model="accessForm.require_confirmation_for_mutations"
              :disabled="accessControlsDisabled"
              class="mt-0.5 shrink-0"
            />
            <span class="min-w-0">
              <span class="block text-sm font-medium text-n-slate-12">
                {{
                  t(
                    'PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.MUTATION_CONFIRMATION'
                  )
                }}
              </span>
            </span>
          </label>

          <div class="rounded-lg p-2">
            <div class="text-sm font-medium text-n-slate-12">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_SUMMARY') }}
            </div>
            <div class="mt-1 text-xs leading-5 text-n-slate-10">
              {{
                toolCountLabel(
                  mcpSummary.enabled_tools || 0,
                  mcpSummary.total_tools || 0
                )
              }}
            </div>
          </div>
        </div>

        <div>
          <div class="mb-2 text-xs font-medium uppercase text-n-slate-10">
            {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES_TITLE') }}
          </div>
          <div class="grid gap-2 sm:grid-cols-3">
            <label
              v-for="source in sourceItems"
              :key="source.id"
              class="flex items-start gap-3 rounded-lg p-2 transition-colors hover:bg-n-alpha-1"
            >
              <Checkbox
                v-model="accessForm.sources[source.id]"
                :disabled="accessControlsDisabled"
                class="mt-0.5 shrink-0"
              />
              <span class="min-w-0">
                <span class="block text-sm font-medium text-n-slate-12">
                  {{ source.label }}
                </span>
                <span class="mt-1 block text-xs text-n-slate-9">
                  {{
                    toolCountLabel(source.enabledToolsCount, source.toolsCount)
                  }}
                </span>
              </span>
            </label>
          </div>
        </div>

        <div>
          <div class="mb-2 text-xs font-medium uppercase text-n-slate-10">
            {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.RISK_TITLE') }}
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="risk in riskOptions"
              :key="risk.value"
              type="button"
              :disabled="accessControlsDisabled"
              class="rounded-full border px-3 py-1 text-xs font-medium disabled:cursor-not-allowed disabled:opacity-60"
              :class="
                accessForm.max_risk_level === risk.value
                  ? 'border-n-brand bg-n-brand/10 text-n-brand'
                  : 'border-n-weak text-n-slate-11'
              "
              @click="accessForm.max_risk_level = risk.value"
            >
              {{ risk.label }}
            </button>
          </div>
        </div>

        <div v-if="mcpGroups.length">
          <div class="mb-2 flex flex-wrap items-end justify-between gap-2">
            <div class="text-xs font-medium uppercase text-n-slate-10">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.GROUPS_TITLE') }}
            </div>
            <span class="text-xs text-n-slate-9">
              {{ toolCountLabel(selectedGroupIds.length, allGroupIds.length) }}
            </span>
          </div>
          <div class="grid max-h-64 gap-1 overflow-auto pr-1 sm:grid-cols-2">
            <label
              v-for="group in mcpGroups"
              :key="group.id"
              class="flex items-start gap-3 rounded-lg p-2 transition-colors hover:bg-n-alpha-1"
            >
              <Checkbox
                v-model="selectedGroupIds"
                :value="group.id"
                :disabled="accessControlsDisabled"
                class="mt-0.5 shrink-0"
              />
              <span class="min-w-0">
                <span
                  class="block truncate text-sm font-medium text-n-slate-12"
                >
                  {{ group.name }}
                </span>
                <span class="mt-1 block text-xs text-n-slate-10">
                  {{
                    toolCountLabel(group.enabled_tools_count, group.tools_count)
                  }}
                </span>
              </span>
            </label>
          </div>
        </div>

        <div
          v-if="showReadOnlyNotice"
          class="text-xs leading-5 text-n-slate-10"
        >
          {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_READ_ONLY') }}
        </div>
      </div>
    </section>
  </div>
</template>
