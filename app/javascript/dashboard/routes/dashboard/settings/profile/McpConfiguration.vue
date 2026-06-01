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
const curlCommand = computed(() =>
  [
    `curl -X POST ${endpointUrl.value}`,
    '-H "Content-Type: application/json"',
    `-H "Authorization: Bearer ${props.accessToken || tokenPlaceholder}"`,
    '-d \'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\'',
  ].join(' ')
);

const canManageMcpAccess = computed(
  () => settingsPayload.value?.permissions?.manage === true
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
      description: t(
        'PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCE_NOTES.captain'
      ),
    },
    {
      id: 'openapi_read',
      label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.openapi_read'),
      description: t(
        'PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCE_NOTES.openapi_read'
      ),
    },
    {
      id: 'openapi_write',
      label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.openapi_write'),
      description: t(
        'PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCE_NOTES.openapi_write'
      ),
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

const statusItems = computed(() => [
  {
    icon: 'i-lucide-building-2',
    label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.BADGES.WORKSPACE'),
  },
  {
    icon: 'i-lucide-key-round',
    label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.BADGES.BEARER'),
  },
  {
    icon: 'i-lucide-radio',
    label: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.BADGES.TRANSPORT'),
  },
]);

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
    const { data } = await McpSettingsAPI.get();
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
    const { data } = await McpSettingsAPI.update({
      mcp_access: serializedAccessForm(),
    });
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

const copyEndpoint = () => copyValue(endpointUrl.value);
const copyConfig = () => copyValue(configForClipboard.value);
const copyCurl = () => copyValue(curlCommand.value);

onMounted(fetchMcpSettings);
</script>

<template>
  <div
    class="overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1 shadow-sm"
  >
    <div class="flex flex-col gap-5 p-5">
      <div
        class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between"
      >
        <div class="flex min-w-0 gap-3">
          <div
            class="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-n-brand/10 text-n-brand"
          >
            <span class="i-lucide-plug-zap size-5" />
          </div>
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="mb-0 text-base font-semibold text-n-slate-12">
                {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CARD_TITLE') }}
              </h3>
              <span
                class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
              >
                {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.STATUS') }}
              </span>
            </div>
            <p class="mb-0 mt-1 text-sm leading-5 text-n-slate-11">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CARD_NOTE') }}
            </p>
          </div>
        </div>

        <Button
          size="sm"
          color="slate"
          variant="outline"
          icon="i-lucide-copy"
          :label="t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.COPY_CONFIG')"
          class="shrink-0 rounded-xl"
          @click="copyConfig"
        />
      </div>

      <div class="grid gap-2 sm:grid-cols-3">
        <div
          v-for="item in statusItems"
          :key="item.label"
          class="flex items-center gap-2 rounded-xl bg-n-alpha-2 px-3 py-2 text-xs font-medium text-n-slate-11"
        >
          <span class="size-4 shrink-0" :class="[item.icon]" />
          <span class="min-w-0 leading-4">{{ item.label }}</span>
        </div>
      </div>

      <div class="grid gap-3">
        <div class="rounded-xl border border-n-weak bg-n-alpha-2 p-3">
          <div class="mb-2 flex items-center justify-between gap-2">
            <span
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ENDPOINT_LABEL') }}
            </span>
            <Button
              size="xs"
              color="slate"
              variant="ghost"
              icon="i-lucide-copy"
              :label="
                t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.COPY_ENDPOINT')
              "
              @click="copyEndpoint"
            />
          </div>
          <code
            class="block break-all rounded-lg bg-n-alpha-black2 px-3 py-2 font-mono text-xs text-n-slate-12"
          >
            {{ endpointUrl }}
          </code>
        </div>

        <div class="grid gap-3 sm:grid-cols-2">
          <div class="rounded-xl border border-n-weak bg-n-alpha-2 p-3">
            <span
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCOUNT_LABEL') }}
            </span>
            <div class="mt-2 truncate text-sm font-medium text-n-slate-12">
              {{ accountName }}
            </div>
            <div class="mt-1 text-xs text-n-slate-10">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCOUNT_HINT') }}
            </div>
          </div>
          <div class="rounded-xl border border-n-weak bg-n-alpha-2 p-3">
            <span
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.TOKEN_LABEL') }}
            </span>
            <div class="mt-2 text-sm font-medium text-n-slate-12">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.TOKEN_SOURCE') }}
            </div>
            <div class="mt-1 text-xs text-n-slate-10">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.TOKEN_HINT') }}
            </div>
          </div>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-alpha-2 p-3">
          <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
            <div>
              <div class="text-sm font-medium text-n-slate-12">
                {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CONFIG_TITLE') }}
              </div>
              <div class="text-xs leading-5 text-n-slate-10">
                {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CONFIG_NOTE') }}
              </div>
            </div>
            <div class="flex gap-2">
              <Button
                size="xs"
                color="slate"
                variant="ghost"
                icon="i-lucide-terminal"
                :label="t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.COPY_CURL')"
                @click="copyCurl"
              />
              <Button
                size="xs"
                color="slate"
                variant="ghost"
                icon="i-lucide-copy"
                :label="
                  t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.COPY_CONFIG')
                "
                @click="copyConfig"
              />
            </div>
          </div>
          <pre
            class="max-h-72 overflow-auto rounded-xl bg-n-alpha-black2 p-3 text-xs text-n-slate-12"
          ><code>{{ configPreview }}</code></pre>
        </div>
      </div>

      <div
        class="flex items-start gap-2 rounded-xl border border-n-weak bg-n-alpha-2 px-3 py-2 text-xs leading-5 text-n-slate-11"
      >
        <span
          class="i-lucide-shield-check mt-0.5 size-4 shrink-0 text-n-slate-10"
        />
        <span>{{
          t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SECURITY_NOTE')
        }}</span>
      </div>

      <div class="rounded-2xl border border-n-weak bg-n-alpha-2 p-4">
        <div
          class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
        >
          <div>
            <div class="flex items-center gap-2">
              <span
                class="i-lucide-sliders-horizontal size-4 text-n-slate-10"
              />
              <h4 class="mb-0 text-sm font-semibold text-n-slate-12">
                {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_TITLE') }}
              </h4>
            </div>
            <p class="mb-0 mt-1 text-xs leading-5 text-n-slate-10">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_NOTE') }}
            </p>
          </div>
          <Button
            v-if="canManageMcpAccess"
            size="sm"
            color="blue"
            icon="i-lucide-save"
            :is-loading="isSavingSettings"
            :label="t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SAVE_ACCESS')"
            @click="saveMcpSettings"
          />
        </div>

        <div
          v-if="settingsLoadFailed"
          class="mt-3 rounded-xl border border-n-ruby-5 bg-n-ruby-2 px-3 py-2 text-xs text-n-ruby-11"
        >
          {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_LOAD_ERROR') }}
        </div>

        <div
          v-else-if="isFetchingSettings"
          class="mt-3 rounded-xl bg-n-alpha-2 px-3 py-2 text-xs text-n-slate-10"
        >
          {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_LOADING') }}
        </div>

        <div v-else class="mt-4 grid gap-4">
          <div class="grid gap-3 sm:grid-cols-3">
            <label
              class="flex items-start gap-2 rounded-xl border border-n-weak bg-n-solid-1 p-3"
            >
              <Checkbox
                v-model="accessForm.enabled"
                :disabled="!canManageMcpAccess"
                class="mt-0.5 shrink-0"
              />
              <span class="min-w-0">
                <span class="block text-sm font-medium text-n-slate-12">
                  {{
                    t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_ENABLED')
                  }}
                </span>
                <span class="mt-1 block text-xs leading-5 text-n-slate-10">
                  {{
                    t(
                      'PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_ENABLED_NOTE'
                    )
                  }}
                </span>
              </span>
            </label>

            <label
              class="flex items-start gap-2 rounded-xl border border-n-weak bg-n-solid-1 p-3"
            >
              <Checkbox
                v-model="accessForm.require_confirmation_for_mutations"
                :disabled="!canManageMcpAccess"
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
                <span class="mt-1 block text-xs leading-5 text-n-slate-10">
                  {{
                    t(
                      'PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.MUTATION_CONFIRMATION_NOTE'
                    )
                  }}
                </span>
              </span>
            </label>

            <div class="rounded-xl border border-n-weak bg-n-solid-1 p-3">
              <div class="text-sm font-medium text-n-slate-12">
                {{
                  t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_SUMMARY')
                }}
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
                class="flex items-start gap-2 rounded-xl border border-n-weak bg-n-solid-1 p-3"
              >
                <Checkbox
                  v-model="accessForm.sources[source.id]"
                  :disabled="!canManageMcpAccess"
                  class="mt-0.5 shrink-0"
                />
                <span class="min-w-0">
                  <span class="block text-sm font-medium text-n-slate-12">
                    {{ source.label }}
                  </span>
                  <span class="mt-1 block text-xs leading-5 text-n-slate-10">
                    {{ source.description }}
                  </span>
                  <span class="mt-2 block text-xs text-n-slate-9">
                    {{
                      toolCountLabel(
                        source.enabledToolsCount,
                        source.toolsCount
                      )
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
                :disabled="!canManageMcpAccess"
                class="rounded-full border px-3 py-1 text-xs font-medium disabled:cursor-not-allowed disabled:opacity-60"
                :class="
                  accessForm.max_risk_level === risk.value
                    ? 'border-n-brand bg-n-brand/10 text-n-brand'
                    : 'border-n-weak bg-n-solid-1 text-n-slate-11'
                "
                @click="accessForm.max_risk_level = risk.value"
              >
                {{ risk.label }}
              </button>
            </div>
          </div>

          <div>
            <div class="mb-2 flex flex-wrap items-end justify-between gap-2">
              <div>
                <div class="text-xs font-medium uppercase text-n-slate-10">
                  {{
                    t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.GROUPS_TITLE')
                  }}
                </div>
                <div class="mt-1 text-xs leading-5 text-n-slate-10">
                  {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.GROUPS_NOTE') }}
                </div>
              </div>
              <span class="text-xs text-n-slate-9">
                {{
                  toolCountLabel(selectedGroupIds.length, allGroupIds.length)
                }}
              </span>
            </div>
            <div class="grid max-h-72 gap-2 overflow-auto pr-1 sm:grid-cols-2">
              <label
                v-for="group in mcpGroups"
                :key="group.id"
                class="flex items-start gap-2 rounded-xl border border-n-weak bg-n-solid-1 p-3"
              >
                <Checkbox
                  v-model="selectedGroupIds"
                  :value="group.id"
                  :disabled="!canManageMcpAccess"
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
                      toolCountLabel(
                        group.enabled_tools_count,
                        group.tools_count
                      )
                    }}
                  </span>
                </span>
              </label>
            </div>
          </div>

          <div
            v-if="!canManageMcpAccess"
            class="rounded-xl border border-n-weak bg-n-solid-1 px-3 py-2 text-xs leading-5 text-n-slate-10"
          >
            {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_READ_ONLY') }}
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
