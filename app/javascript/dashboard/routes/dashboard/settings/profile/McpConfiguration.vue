<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import McpSettingsAPI from 'dashboard/api/mcpSettings';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
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
  blocked_groups: [],
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
const uniqueValues = values => [...new Set(values.map(String).filter(Boolean))];
const selectedGroupIds = computed({
  get() {
    const blockedIds = new Set(accessForm.blocked_groups.map(String));
    const allowedIds = accessForm.allowed_groups.length
      ? accessForm.allowed_groups.map(String)
      : allGroupIds.value.map(String);

    return allowedIds.filter(id => !blockedIds.has(id));
  },
  set(values) {
    const normalizedValues = uniqueValues(values);
    const allIds = allGroupIds.value.map(String);

    if (normalizedValues.length === allIds.length) {
      accessForm.allowed_groups = [];
      accessForm.blocked_groups = [];
      return;
    }

    if (normalizedValues.length === 0) {
      accessForm.allowed_groups = [];
      accessForm.blocked_groups = allIds;
      return;
    }

    accessForm.allowed_groups = normalizedValues;
    accessForm.blocked_groups = [];
  },
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
const groupKeyFor = tool =>
  tool.group_key || `${tool.source || 'tool'}:${tool.group_name || 'Other'}`;
const groupIsSelected = groupId =>
  selectedGroupIds.value.map(String).includes(String(groupId));
const sourceIsEnabled = source => accessForm.sources[source] !== false;
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
const sourceIdsForGroup = group =>
  uniqueValues((group.tools || []).map(tool => tool.source));
const sourceSummaryForGroup = group =>
  sourceIdsForGroup(group).map(sourceLabelFor).join(' · ');
const toolIdsForGroup = (group, openApi) =>
  uniqueValues(
    (group.tools || [])
      .filter(tool => isOpenApiTool(tool) === openApi)
      .map(toolPolicyId)
  );
const toolTitle = tool => tool.title || tool.name || toolPolicyId(tool);
const stateLabel = enabled => {
  if (enabled) {
    return t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.STATE_ENABLED');
  }

  return t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.STATE_DISABLED');
};
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
const groupedCatalogTools = computed(() => {
  const groups = new Map();

  catalogTools.value.forEach(tool => {
    const groupId = groupKeyFor(tool);
    const existing = groups.get(groupId) || {
      id: groupId,
      name:
        tool.group_name ||
        t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.OTHER_GROUP'),
      tools: [],
    };

    existing.tools.push(tool);
    groups.set(groupId, existing);
  });

  return Array.from(groups.values()).sort((left, right) =>
    left.name.localeCompare(right.name)
  );
});

const setSelectedIds = (key, ids) => {
  accessForm[key] = uniqueValues(ids);
};

const setGroupSelected = (group, selected) => {
  markCustomAccessMode();
  const selectedGroupSet = new Set(selectedGroupIds.value.map(String));
  const normalizedGroupId = String(group.id);
  const selectedNativeToolIds = new Set(
    accessForm.selected_tool_ids.map(String)
  );
  const selectedOpenApiToolIds = new Set(
    accessForm.selected_openapi_operation_ids.map(String)
  );

  if (selected) {
    selectedGroupSet.add(normalizedGroupId);
    sourceIdsForGroup(group).forEach(source => {
      accessForm.sources[source] = true;
    });
    toolIdsForGroup(group, false).forEach(id => selectedNativeToolIds.add(id));
    toolIdsForGroup(group, true).forEach(id => selectedOpenApiToolIds.add(id));
  } else {
    selectedGroupSet.delete(normalizedGroupId);
    toolIdsForGroup(group, false).forEach(id =>
      selectedNativeToolIds.delete(id)
    );
    toolIdsForGroup(group, true).forEach(id =>
      selectedOpenApiToolIds.delete(id)
    );
  }

  selectedGroupIds.value = [...selectedGroupSet];
  setSelectedIds('selected_tool_ids', [...selectedNativeToolIds]);
  setSelectedIds('selected_openapi_operation_ids', [...selectedOpenApiToolIds]);
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

const groupIsEnabled = group =>
  group.tools.length > 0 &&
  groupIsSelected(group.id) &&
  group.tools.every(tool => isToolSelected(tool));
const selectedToolCount = computed(
  () => catalogTools.value.filter(tool => isToolSelected(tool)).length
);
const toolCountLabel = computed(() =>
  t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.TOOLS_ENABLED_COUNT', {
    enabled: selectedToolCount.value,
    total: catalogTools.value.length,
  })
);

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
  accessForm.blocked_groups = Array.isArray(access.blocked_groups)
    ? [...access.blocked_groups]
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
  accessForm.blocked_groups = [];
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
    blocked_groups: [...accessForm.blocked_groups],
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
const copyEndpointUrl = () => copyValue(endpointUrl.value);

onMounted(fetchMcpSettings);
</script>

<template>
  <div class="flex w-full flex-col gap-4">
    <section class="flex flex-col gap-4">
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
          <div
            class="flex items-center overflow-hidden rounded-lg border border-n-weak bg-n-alpha-1"
          >
            <code
              class="min-w-0 flex-1 select-all truncate px-3 py-2 font-mono text-xs text-n-slate-12"
            >
              {{ endpointUrl }}
            </code>
            <button
              type="button"
              class="flex size-9 shrink-0 items-center justify-center border-l border-n-weak text-n-slate-10 transition hover:bg-n-alpha-2 hover:text-n-slate-12"
              :aria-label="
                t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.COPY_URL')
              "
              @click="copyEndpointUrl"
            >
              <span class="i-lucide-copy size-4" />
            </button>
          </div>
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
        <div
          v-if="canManageMcpAccess"
          class="flex items-center justify-between gap-3 rounded-lg bg-n-alpha-1 px-3 py-2 sm:justify-end"
        >
          <span class="text-sm font-medium text-n-slate-12">
            {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_ENABLED') }}
          </span>
          <span class="text-xs font-normal text-n-slate-10">
            {{ stateLabel(accessForm.enabled) }}
          </span>
          <Switch
            v-model="accessForm.enabled"
            :disabled="accessControlsDisabled"
            :aria-label="
              t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_ENABLED')
            "
          />
        </div>
      </div>

      <div v-if="settingsLoadFailed" class="text-xs leading-5 text-n-ruby-11">
        {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.ACCESS_LOAD_ERROR') }}
      </div>

      <div class="grid gap-4">
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

        <div
          class="flex items-center justify-between gap-3 rounded-lg bg-n-alpha-1 p-3"
        >
          <span class="text-sm font-medium text-n-slate-12">
            {{
              t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.MUTATION_CONFIRMATION')
            }}
          </span>
          <div class="flex items-center gap-2">
            <span class="text-xs font-normal text-n-slate-10">
              {{ stateLabel(accessForm.require_confirmation_for_mutations) }}
            </span>
            <Switch
              v-model="accessForm.require_confirmation_for_mutations"
              :disabled="accessControlsDisabled"
              :aria-label="
                t(
                  'PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.MUTATION_CONFIRMATION'
                )
              "
              @change="markCustomAccessMode"
            />
          </div>
        </div>

        <div v-if="groupedCatalogTools.length">
          <div class="mb-2 flex items-center justify-between gap-2">
            <div class="text-xs font-medium uppercase text-n-slate-10">
              {{ t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.CATALOG_TITLE') }}
            </div>
            <span
              class="shrink-0 rounded-full bg-n-alpha-1 px-2 py-0.5 text-xs font-medium text-n-slate-10"
            >
              {{ toolCountLabel }}
            </span>
          </div>
          <div
            class="max-h-[28rem] overflow-auto rounded-xl border border-n-weak"
          >
            <div
              v-for="group in groupedCatalogTools"
              :key="group.id"
              class="border-b border-n-weak last:border-b-0"
            >
              <div class="flex h-11 items-center justify-between gap-3 px-3">
                <div class="flex min-w-0 items-center gap-2">
                  <span
                    class="min-w-0 truncate text-sm font-semibold text-n-slate-12"
                  >
                    {{ group.name }}
                  </span>
                  <span
                    class="shrink-0 rounded-full bg-n-alpha-1 px-2 py-0.5 text-[11px] font-medium text-n-slate-9"
                  >
                    {{ sourceSummaryForGroup(group) }}
                  </span>
                </div>
                <div class="flex shrink-0 items-center gap-2">
                  <span class="text-xs font-normal text-n-slate-10">
                    {{ stateLabel(groupIsEnabled(group)) }}
                  </span>
                  <Switch
                    :model-value="groupIsEnabled(group)"
                    :disabled="accessControlsDisabled"
                    :aria-label="group.name"
                    @change="value => setGroupSelected(group, value)"
                  />
                </div>
              </div>
              <div class="divide-y divide-n-weak">
                <div
                  v-for="tool in group.tools"
                  :key="toolPolicyId(tool)"
                  class="flex h-10 items-center justify-between gap-3 px-3 ltr:pl-6 rtl:pr-6 transition-colors hover:bg-n-alpha-1"
                >
                  <span
                    class="min-w-0 truncate text-xs font-normal text-n-slate-11"
                  >
                    {{ toolTitle(tool) }}
                  </span>
                  <div class="flex shrink-0 items-center gap-2">
                    <span class="text-xs font-normal text-n-slate-10">
                      {{ stateLabel(isToolSelected(tool)) }}
                    </span>
                    <Switch
                      :model-value="isToolSelected(tool)"
                      :disabled="toolCheckboxDisabled(tool)"
                      :aria-label="toolTitle(tool)"
                      @change="value => setToolSelected(tool, value)"
                    />
                  </div>
                </div>
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

        <div v-if="canManageMcpAccess" class="flex justify-end pt-2">
          <Button
            size="sm"
            color="blue"
            icon="i-lucide-save"
            :is-loading="isSavingSettings"
            :disabled="isFetchingSettings || settingsLoadFailed"
            :label="t('PROFILE_SETTINGS.FORM.MCP_CONFIGURATION.SAVE_ACCESS')"
            @click="saveMcpSettings"
          />
        </div>
      </div>
    </section>
  </div>
</template>
