<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import McpSettingsAPI from 'dashboard/api/mcpSettings';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

import {
  accessPolicyForMode,
  allowsToolForAccessMode,
  MCP_ACCESS_MODE_IDS,
  modeFromAccessPolicy,
} from './mcpAccessModes';

const props = defineProps({
  accessToken: { type: String, default: '' },
});

const { t } = useI18n();
const { accountId, currentAccount } = useAccount();

const MCP_SETTINGS_TIMEOUT_MS = 8000;
const CUSTOM_ACCESS_MODE_ID = 'custom';
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
const selectedAccessMode = ref(MCP_ACCESS_MODE_IDS.BASIC);
const accessForm = reactive({
  enabled: true,
  sources: {
    captain: true,
    openapi_read: true,
    openapi_write: false,
  },
  max_risk_level: 'medium',
  require_confirmation_for_mutations: true,
  allowed_groups: [],
  selected_tool_ids: [],
  selected_openapi_operation_ids: [],
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
const mcpGroups = computed(() => settingsPayload.value?.groups || []);
const catalogTools = computed(() => settingsPayload.value?.tools || []);
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

const toolCountLabel = (enabled, total) =>
  t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.TOOLS_ENABLED_COUNT', {
    enabled,
    total,
  });

const sourceLabelFor = source => {
  if (source === 'captain') {
    return t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.captain');
  }

  if (source === 'openapi_read') {
    return t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.openapi_read');
  }

  if (source === 'openapi_write') {
    return t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SOURCES.openapi_write');
  }

  return t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.OTHER_GROUP');
};

const sourceItems = computed(() => {
  const sourceCounts = settingsPayload.value?.sources || [];
  const sourceById = sourceCounts.reduce((acc, source) => {
    acc[source.id] = source;
    return acc;
  }, {});

  return [
    {
      id: 'captain',
      label: sourceLabelFor('captain'),
    },
    {
      id: 'openapi_read',
      label: sourceLabelFor('openapi_read'),
    },
    {
      id: 'openapi_write',
      label: sourceLabelFor('openapi_write'),
    },
  ].map(source => ({
    ...source,
    toolsCount: sourceById[source.id]?.tools_count || 0,
    enabledToolsCount: sourceById[source.id]?.enabled_tools_count || 0,
  }));
});

const accessModeOptions = computed(() => [
  {
    id: MCP_ACCESS_MODE_IDS.BASIC,
    icon: 'i-lucide-shield-check',
    title: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.MODES.BASIC_TITLE'),
  },
  {
    id: MCP_ACCESS_MODE_IDS.FULL,
    icon: 'i-lucide-unlock',
    title: t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.MODES.FULL_TITLE'),
  },
]);

const toolPolicyId = tool => String(tool.id || tool.operation_id || tool.name);
const isOpenApiTool = tool => String(tool.source || '').startsWith('openapi');
const uniqueValues = values => [...new Set(values.map(String).filter(Boolean))];
const groupKeyFor = tool =>
  tool.group_key || `${tool.source || 'tool'}:${tool.group_name || 'Other'}`;
const groupIsSelected = groupId => selectedGroupIds.value.includes(groupId);
const sourceIsEnabled = source => accessForm.sources[source] !== false;
const toolTitle = tool => tool.title || tool.name || toolPolicyId(tool);
const hasCustomAccessFilters = access =>
  [
    'allowed_groups',
    'blocked_groups',
    'allowed_tool_ids',
    'blocked_tool_ids',
    'allowed_openapi_operation_ids',
    'blocked_openapi_operation_ids',
  ].some(key => Array.isArray(access?.[key]) && access[key].length > 0);
const markCustomAccessMode = () => {
  selectedAccessMode.value = CUSTOM_ACCESS_MODE_ID;
};

const allNativeToolIds = computed(() =>
  uniqueValues(
    catalogTools.value.filter(tool => !isOpenApiTool(tool)).map(toolPolicyId)
  )
);
const allOpenApiToolIds = computed(() =>
  uniqueValues(
    catalogTools.value.filter(tool => isOpenApiTool(tool)).map(toolPolicyId)
  )
);

const activeSelectedNativeToolIds = computed(() => {
  const selectedIds = new Set(accessForm.selected_tool_ids.map(String));
  return uniqueValues(
    catalogTools.value
      .filter(tool => !isOpenApiTool(tool))
      .filter(tool => selectedIds.has(toolPolicyId(tool)))
      .filter(tool => sourceIsEnabled(tool.source))
      .filter(tool => groupIsSelected(groupKeyFor(tool)))
      .map(toolPolicyId)
  );
});
const activeSelectedOpenApiToolIds = computed(() => {
  const selectedIds = new Set(
    accessForm.selected_openapi_operation_ids.map(String)
  );
  return uniqueValues(
    catalogTools.value
      .filter(tool => isOpenApiTool(tool))
      .filter(tool => selectedIds.has(toolPolicyId(tool)))
      .filter(tool => sourceIsEnabled(tool.source))
      .filter(tool => groupIsSelected(groupKeyFor(tool)))
      .map(toolPolicyId)
  );
});
const selectedToolCount = computed(
  () =>
    activeSelectedNativeToolIds.value.length +
    activeSelectedOpenApiToolIds.value.length
);

const groupedCatalogTools = computed(() => {
  const groups = new Map();

  catalogTools.value.forEach(tool => {
    const groupId = groupKeyFor(tool);
    const existing = groups.get(groupId) || {
      id: groupId,
      name:
        tool.group_name ||
        t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.OTHER_GROUP'),
      source: tool.source,
      sourceLabel: sourceLabelFor(tool.source),
      tools: [],
    };

    existing.tools.push(tool);
    groups.set(groupId, existing);
  });

  return Array.from(groups.values()).sort((left, right) =>
    [left.sourceLabel, left.name]
      .join(' ')
      .localeCompare([right.sourceLabel, right.name].join(' '))
  );
});

const setSelectedIds = (key, ids) => {
  accessForm[key] = uniqueValues(ids);
};

const setToolSelected = (tool, selected) => {
  markCustomAccessMode();
  const key = isOpenApiTool(tool)
    ? 'selected_openapi_operation_ids'
    : 'selected_tool_ids';
  const id = toolPolicyId(tool);
  const selectedIds = new Set(accessForm[key].map(String));

  if (selected) {
    selectedIds.add(id);
  } else {
    selectedIds.delete(id);
  }

  setSelectedIds(key, [...selectedIds]);
};

const isToolSelected = tool => {
  if (!sourceIsEnabled(tool.source) || !groupIsSelected(groupKeyFor(tool))) {
    return false;
  }

  const selectedIds = isOpenApiTool(tool)
    ? accessForm.selected_openapi_operation_ids
    : accessForm.selected_tool_ids;

  return selectedIds.map(String).includes(toolPolicyId(tool));
};

const toolCheckboxDisabled = tool =>
  accessControlsDisabled.value ||
  !sourceIsEnabled(tool.source) ||
  !groupIsSelected(groupKeyFor(tool));

const applySelectedToolsFromPolicy = policy => {
  setSelectedIds(
    'selected_tool_ids',
    catalogTools.value
      .filter(tool => !isOpenApiTool(tool))
      .filter(tool => allowsToolForAccessMode(tool, selectedAccessMode.value))
      .filter(tool => policy.sources?.[tool.source] !== false)
      .map(toolPolicyId)
  );
  setSelectedIds(
    'selected_openapi_operation_ids',
    catalogTools.value
      .filter(tool => isOpenApiTool(tool))
      .filter(tool => allowsToolForAccessMode(tool, selectedAccessMode.value))
      .filter(tool => policy.sources?.[tool.source] !== false)
      .map(toolPolicyId)
  );
};

const hydrateAccessForm = payload => {
  const access = payload?.mcp_access || {};
  accessForm.enabled = access.enabled !== false;
  accessForm.sources = {
    captain: access.sources?.captain !== false,
    openapi_read: access.sources?.openapi_read !== false,
    openapi_write: access.sources?.openapi_write === true,
  };
  accessForm.max_risk_level = access.max_risk_level || 'medium';
  accessForm.require_confirmation_for_mutations =
    access.require_confirmation_for_mutations !== false;
  accessForm.allowed_groups = Array.isArray(access.allowed_groups)
    ? [...access.allowed_groups]
    : [];
  setSelectedIds(
    'selected_tool_ids',
    catalogTools.value
      .filter(tool => !isOpenApiTool(tool) && tool.enabled_by_policy !== false)
      .map(toolPolicyId)
  );
  setSelectedIds(
    'selected_openapi_operation_ids',
    catalogTools.value
      .filter(tool => isOpenApiTool(tool) && tool.enabled_by_policy !== false)
      .map(toolPolicyId)
  );
  selectedAccessMode.value = hasCustomAccessFilters(access)
    ? CUSTOM_ACCESS_MODE_ID
    : modeFromAccessPolicy(access);
};

const applyAccessMode = modeId => {
  selectedAccessMode.value = modeId;
  const policy = accessPolicyForMode(modeId, {
    enabled: accessForm.enabled,
  });

  accessForm.sources = { ...policy.sources };
  accessForm.max_risk_level = policy.max_risk_level;
  accessForm.require_confirmation_for_mutations =
    policy.require_confirmation_for_mutations;
  accessForm.allowed_groups = [];
  applySelectedToolsFromPolicy(policy);
};

const serializedAccessForm = () => {
  if (Object.values(MCP_ACCESS_MODE_IDS).includes(selectedAccessMode.value)) {
    return accessPolicyForMode(selectedAccessMode.value, {
      enabled: accessForm.enabled,
    });
  }

  const selectedNativeIds = new Set(activeSelectedNativeToolIds.value);
  const selectedOpenApiIds = new Set(activeSelectedOpenApiToolIds.value);

  return {
    enabled: accessForm.enabled,
    sources: { ...accessForm.sources },
    max_risk_level: accessForm.max_risk_level,
    require_confirmation_for_mutations:
      accessForm.require_confirmation_for_mutations,
    allowed_groups: [...accessForm.allowed_groups],
    blocked_groups: [],
    allowed_tool_ids: [...selectedNativeIds],
    blocked_tool_ids: allNativeToolIds.value.filter(
      id => !selectedNativeIds.has(id)
    ),
    allowed_openapi_operation_ids: [...selectedOpenApiIds],
    blocked_openapi_operation_ids: allOpenApiToolIds.value.filter(
      id => !selectedOpenApiIds.has(id)
    ),
  };
};

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
  <div class="flex w-full flex-col gap-4">
    <section
      class="flex flex-col gap-4 rounded-xl border border-n-weak bg-n-background p-4"
    >
      <div class="flex flex-col gap-1">
        <div class="flex items-center gap-2">
          <span class="i-lucide-plug-zap size-4 text-n-slate-10" />
          <h5 class="mb-0 text-heading-3 text-n-slate-12">
            {{ accountName }}
          </h5>
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

    <section
      class="flex flex-col gap-4 rounded-xl border border-n-weak bg-n-background p-4"
    >
      <div
        class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
      >
        <div class="min-w-0">
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
              @change="markCustomAccessMode"
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
              {{ toolCountLabel(selectedToolCount, catalogTools.length) }}
            </div>
          </div>
        </div>

        <div class="grid gap-3 md:grid-cols-2">
          <button
            v-for="mode in accessModeOptions"
            :key="mode.id"
            type="button"
            :disabled="accessControlsDisabled"
            class="flex items-center gap-3 rounded-lg border p-3 text-left transition disabled:cursor-not-allowed disabled:opacity-60"
            :class="
              selectedAccessMode === mode.id
                ? 'border-n-brand bg-n-brand/10 text-n-slate-12'
                : 'border-n-weak bg-n-solid-1 text-n-slate-11 hover:border-n-slate-7'
            "
            @click="applyAccessMode(mode.id)"
          >
            <span
              class="mt-0.5 size-5 shrink-0"
              :class="[
                mode.icon,
                selectedAccessMode === mode.id
                  ? 'text-n-brand'
                  : 'text-n-slate-9',
              ]"
            />
            <span class="min-w-0">
              <span class="block text-sm font-medium text-n-slate-12">
                {{ mode.title }}
              </span>
            </span>
          </button>
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
                @change="markCustomAccessMode"
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
                @change="markCustomAccessMode"
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

        <div v-if="groupedCatalogTools.length">
          <div class="mb-2 flex flex-wrap items-end justify-between gap-2">
            <div class="text-xs font-medium uppercase text-n-slate-10">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.TOOLS_TITLE') }}
            </div>
            <span class="text-xs text-n-slate-9">
              {{ toolCountLabel(selectedToolCount, catalogTools.length) }}
            </span>
          </div>
          <div class="grid max-h-96 gap-2 overflow-auto pr-1 lg:grid-cols-2">
            <div
              v-for="group in groupedCatalogTools"
              :key="group.id"
              class="rounded-lg border border-n-weak bg-n-solid-1 p-3"
            >
              <div class="mb-2 flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <div class="truncate text-sm font-medium text-n-slate-12">
                    {{ group.name }}
                  </div>
                  <div class="mt-1 text-xs text-n-slate-10">
                    {{ group.sourceLabel }}
                  </div>
                </div>
                <span
                  class="shrink-0 rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
                >
                  {{ group.tools.length }}
                </span>
              </div>
              <div class="flex flex-col gap-1">
                <label
                  v-for="tool in group.tools"
                  :key="toolPolicyId(tool)"
                  class="flex items-start gap-2 rounded-md p-1.5 transition-colors hover:bg-n-alpha-1"
                >
                  <Checkbox
                    :model-value="isToolSelected(tool)"
                    :disabled="toolCheckboxDisabled(tool)"
                    class="mt-0.5 shrink-0"
                    @change="
                      event => setToolSelected(tool, event.target.checked)
                    "
                  />
                  <span class="min-w-0">
                    <span
                      class="block truncate text-sm font-medium text-n-slate-12"
                    >
                      {{ toolTitle(tool) }}
                    </span>
                  </span>
                </label>
              </div>
            </div>
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
