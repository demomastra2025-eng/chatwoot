<script setup>
import { computed, onMounted, ref, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import CustomToolsPageEmptyState from 'dashboard/components-next/captain/pageComponents/emptyStates/CustomToolsPageEmptyState.vue';
import CreateCustomToolDialog from 'dashboard/components-next/captain/pageComponents/customTool/CreateCustomToolDialog.vue';
import CustomToolCard from 'dashboard/components-next/captain/pageComponents/customTool/CustomToolCard.vue';
import CreateMcpServerDialog from 'dashboard/components-next/captain/pageComponents/mcpServer/CreateMcpServerDialog.vue';
import McpServerCard from 'dashboard/components-next/captain/pageComponents/mcpServer/McpServerCard.vue';
import McpServerSurfaceDialog from 'dashboard/components-next/captain/pageComponents/mcpServer/McpServerSurfaceDialog.vue';
import DeleteDialog from 'dashboard/components-next/captain/pageComponents/DeleteDialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CaptainToolsAPI from 'dashboard/api/captain/tools';

const store = useStore();
const { t } = useI18n();

const customToolFlags = useMapGetter('captainCustomTools/getUIFlags');
const customTools = useMapGetter('captainCustomTools/getRecords');
const customToolsMeta = useMapGetter('captainCustomTools/getMeta');
const mcpServerFlags = useMapGetter('captainMcpServers/getUIFlags');
const mcpServers = useMapGetter('captainMcpServers/getRecords');
const catalogTools = ref([]);

const TOOL_SOURCE_TYPES = Object.freeze({
  SYSTEM: 'system',
  CUSTOM: 'custom',
  MCP: 'mcp',
  SKILL: 'skill',
});

const EMPTY_SELECTED_TOOL = Object.freeze({});
const EMPTY_SELECTED_SERVER = Object.freeze({});
const TOOL_META_SEPARATOR = ' · ';

const createDialogRef = ref(null);
const createMcpDialogRef = ref(null);
const mcpSurfaceDialogRef = ref(null);
const deleteDialogRef = ref(null);
const selectedTool = ref(null);
const selectedServer = ref(null);
const dialogType = ref('');
const serverDialogType = ref('');

const isFetching = computed(
  () => customToolFlags.value.fetchingList || mcpServerFlags.value.fetchingList
);

const activeDialogType = computed(() => dialogType.value || 'create');
const dialogSelectedTool = computed(
  () => selectedTool.value || EMPTY_SELECTED_TOOL
);
const activeServerDialogType = computed(
  () => serverDialogType.value || 'create'
);
const dialogSelectedServer = computed(
  () => selectedServer.value || EMPTY_SELECTED_SERVER
);

const isSystemTool = tool => tool.source_type === TOOL_SOURCE_TYPES.SYSTEM;
const isCustomCatalogTool = tool =>
  tool.source_type === TOOL_SOURCE_TYPES.CUSTOM;

const sortTools = tools =>
  [...tools].sort((leftTool, rightTool) => {
    const leftTitle = leftTool.title?.toLowerCase() || '';
    const rightTitle = rightTool.title?.toLowerCase() || '';
    return leftTitle.localeCompare(rightTitle);
  });

const publicTools = computed(() =>
  sortTools(
    catalogTools.value.filter(
      tool => !isSystemTool(tool) && !isCustomCatalogTool(tool)
    )
  )
);

const toolSourceLabel = tool => {
  const sourceType = tool.source_type || TOOL_SOURCE_TYPES.SYSTEM;
  if (sourceType === TOOL_SOURCE_TYPES.CUSTOM) {
    return t('CAPTAIN.CUSTOM_TOOLS.SOURCE_TYPES.CUSTOM');
  }
  if (sourceType === TOOL_SOURCE_TYPES.MCP) {
    return t('CAPTAIN.CUSTOM_TOOLS.SOURCE_TYPES.MCP');
  }
  if (sourceType === TOOL_SOURCE_TYPES.SKILL) {
    return t('CAPTAIN.CUSTOM_TOOLS.SOURCE_TYPES.SKILL');
  }
  return t('CAPTAIN.CUSTOM_TOOLS.SOURCE_TYPES.SYSTEM');
};

const toolSourceMeta = (tool, extraLabel) =>
  [toolSourceLabel(tool), extraLabel].filter(Boolean).join(TOOL_META_SEPARATOR);

const groupedCustomTools = computed(() => {
  const grouped = customTools.value.reduce((accumulator, tool) => {
    const key = tool.group_name || '';
    if (!accumulator[key]) {
      accumulator[key] = [];
    }
    accumulator[key].push(tool);
    return accumulator;
  }, {});

  return Object.entries(grouped)
    .sort(([leftKey], [rightKey]) => {
      if (!leftKey) return 1;
      if (!rightKey) return -1;
      return leftKey.localeCompare(rightKey);
    })
    .map(([groupName, tools]) => ({
      key: groupName ? `group:${groupName}` : '__ungrouped__',
      label: groupName || t('CAPTAIN.CUSTOM_TOOLS.UNGROUPED'),
      tools: sortTools(tools),
    }));
});

const fetchCustomTools = (page = 1) => {
  store.dispatch('captainCustomTools/get', { page });
};

const fetchMcpServers = () => {
  store.dispatch('captainMcpServers/get', { page: 1 });
};

const fetchCatalogTools = async () => {
  try {
    const response = await CaptainToolsAPI.get();
    catalogTools.value = response.data || [];
  } catch (error) {
    catalogTools.value = [];
  }
};

const onPageChange = page => fetchCustomTools(page);

const openCreateDialog = () => {
  dialogType.value = 'create';
  selectedTool.value = null;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const openCreateMcpDialog = () => {
  serverDialogType.value = 'create';
  selectedServer.value = null;
  nextTick(() => createMcpDialogRef.value.dialogRef.open());
};

const handleEdit = tool => {
  dialogType.value = 'edit';
  selectedTool.value = tool;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleDuplicate = tool => {
  dialogType.value = 'duplicate';
  selectedTool.value = tool;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleEditMcpServer = async server => {
  try {
    const response = await store.dispatch('captainMcpServers/show', server.id);
    serverDialogType.value = 'edit';
    selectedServer.value = response;
    nextTick(() => createMcpDialogRef.value.dialogRef.open());
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.EDIT.ERROR_MESSAGE')
    );
  }
};

const handleDelete = tool => {
  selectedTool.value = tool;
  selectedServer.value = null;
  nextTick(() => deleteDialogRef.value.dialogRef.open());
};

const handleDeleteMcpServer = server => {
  selectedServer.value = server;
  selectedTool.value = null;
  nextTick(() => deleteDialogRef.value.dialogRef.open());
};

const handleAction = ({ action, id }) => {
  const tool = customTools.value.find(customTool => customTool.id === id);
  if (action === 'edit') {
    handleEdit(tool);
  } else if (action === 'duplicate') {
    handleDuplicate(tool);
  } else if (action === 'delete') {
    handleDelete(tool);
  }
};

const handleMcpAction = ({ action, id }) => {
  const server = mcpServers.value.find(mcpServer => mcpServer.id === id);
  if (action === 'edit') {
    handleEditMcpServer(server);
  } else if (action === 'manage') {
    selectedServer.value = server;
    selectedTool.value = null;
    nextTick(() => mcpSurfaceDialogRef.value.open());
  } else if (action === 'delete') {
    handleDeleteMcpServer(server);
  }
};

const handleDialogClose = () => {
  dialogType.value = '';
  selectedTool.value = null;
};

const handleMcpDialogClose = () => {
  serverDialogType.value = '';
  selectedServer.value = null;
};

const onDeleteSuccess = () => {
  if (selectedTool.value) {
    selectedTool.value = null;
    if (customTools.value.length === 1 && customToolsMeta.value.page > 1) {
      onPageChange(customToolsMeta.value.page - 1);
    } else {
      fetchCustomTools(customToolsMeta.value.page);
    }
    return;
  }

  selectedServer.value = null;
  fetchMcpServers();
};

const notifyOAuthRedirectStatus = () => {
  const currentUrl = new URL(window.location.href);
  const oauthStatus = currentUrl.searchParams.get('mcp_oauth');
  const oauthError = currentUrl.searchParams.get('mcp_oauth_error');

  if (!oauthStatus) {
    return;
  }

  if (oauthStatus === 'connected') {
    useAlert(t('CAPTAIN.MCP_SERVERS.OAUTH.CONNECTED_SUCCESS'));
  } else {
    useAlert(oauthError || t('CAPTAIN.MCP_SERVERS.OAUTH.CALLBACK_ERROR'));
  }

  currentUrl.searchParams.delete('mcp_oauth');
  currentUrl.searchParams.delete('mcp_oauth_error');
  window.history.replaceState(
    {},
    document.title,
    `${currentUrl.pathname}${currentUrl.search}${currentUrl.hash}`
  );
};

onMounted(() => {
  notifyOAuthRedirectStatus();
  fetchCatalogTools();
  fetchCustomTools();
  fetchMcpServers();
});
</script>

<template>
  <PageLayout
    :header-title="$t('CAPTAIN.CUSTOM_TOOLS.HEADER')"
    :button-label="$t('CAPTAIN.CUSTOM_TOOLS.ADD_NEW')"
    :button-policy="['administrator']"
    :total-count="customToolsMeta.totalCount"
    :current-page="customToolsMeta.page"
    :show-pagination-footer="
      !customToolFlags.fetchingList && !!customTools.length
    "
    :is-fetching="isFetching"
    :is-empty="!customTools.length && !mcpServers.length && !publicTools.length"
    :feature-flag="FEATURE_FLAGS.CAPTAIN_V2"
    :show-know-more="false"
    :show-assistant-switcher="false"
    @update:current-page="onPageChange"
    @click="openCreateDialog"
  >
    <template #paywall>
      <CaptainPaywall />
    </template>

    <template #emptyState>
      <CustomToolsPageEmptyState @click="openCreateDialog" />
    </template>

    <template #body>
      <div class="flex flex-col gap-6">
        <section class="grid gap-3 md:grid-cols-2">
          <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-4">
            <p
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              {{ $t('CAPTAIN.CUSTOM_TOOLS.CATEGORIES.CUSTOM') }}
            </p>
            <p class="mt-2 text-2xl font-semibold text-n-slate-12">
              {{ customTools.length }}
            </p>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ $t('CAPTAIN.CUSTOM_TOOLS.CATEGORIES.CUSTOM_DESCRIPTION') }}
            </p>
          </div>
          <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-4">
            <p
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              {{ $t('CAPTAIN.CUSTOM_TOOLS.CATEGORIES.PUBLIC') }}
            </p>
            <p class="mt-2 text-2xl font-semibold text-n-slate-12">
              {{ publicTools.length + mcpServers.length }}
            </p>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ $t('CAPTAIN.CUSTOM_TOOLS.CATEGORIES.PUBLIC_DESCRIPTION') }}
            </p>
          </div>
        </section>

        <section v-if="publicTools.length" class="flex flex-col gap-3">
          <div class="flex items-center gap-2 px-1">
            <span
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-11"
            >
              {{ $t('CAPTAIN.CUSTOM_TOOLS.CATEGORIES.PUBLIC') }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{ publicTools.length }}
            </span>
          </div>
          <div class="grid gap-3 md:grid-cols-2">
            <article
              v-for="tool in publicTools"
              :key="tool.id"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <h3 class="truncate text-sm font-medium text-n-slate-12">
                {{ tool.title || tool.id }}
              </h3>
              <p class="mt-1 line-clamp-2 text-sm text-n-slate-11">
                {{ tool.description }}
              </p>
              <p class="mt-2 text-xs text-n-slate-10">
                {{ toolSourceMeta(tool, tool.group_name || tool.scope_name) }}
              </p>
            </article>
          </div>
        </section>

        <section class="flex flex-col gap-3">
          <div class="flex items-center justify-between gap-2 px-1">
            <div class="flex items-center gap-2">
              <span
                class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-11"
              >
                {{ $t('CAPTAIN.MCP_SERVERS.HEADER') }}
              </span>
              <span class="text-xs text-n-slate-11">
                {{ mcpServers.length }}
              </span>
            </div>
            <Button
              size="sm"
              color="slate"
              class="!px-3"
              :label="$t('CAPTAIN.MCP_SERVERS.ADD_NEW')"
              @click="openCreateMcpDialog"
            />
          </div>
          <div class="flex flex-col gap-4">
            <McpServerCard
              v-for="server in mcpServers"
              :id="server.id"
              :key="server.id"
              :name="server.name"
              :description="server.description"
              :transport-type="server.transport_type"
              :allowed-scopes="server.allowed_scopes"
              :oauth-status="server.oauth_status"
              :created-at="server.created_at"
              :updated-at="server.updated_at"
              @action="handleMcpAction"
            />
          </div>
        </section>

        <section
          v-for="group in groupedCustomTools"
          :key="group.key"
          class="flex flex-col gap-3"
        >
          <div class="flex items-center gap-2 px-1">
            <span
              class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-11"
            >
              {{ group.label }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{ group.tools.length }}
            </span>
          </div>
          <div class="flex flex-col gap-4">
            <CustomToolCard
              v-for="tool in group.tools"
              :id="tool.id"
              :key="tool.id"
              :title="tool.title"
              :group-name="tool.group_name"
              :description="tool.description"
              :endpoint-url="tool.endpoint_url"
              :http-method="tool.http_method"
              :auth-type="tool.auth_type"
              :param-schema="tool.param_schema"
              :enabled="tool.enabled"
              :created-at="tool.created_at"
              :updated-at="tool.updated_at"
              @action="handleAction"
            />
          </div>
        </section>
      </div>
    </template>
  </PageLayout>

  <CreateCustomToolDialog
    ref="createDialogRef"
    :type="activeDialogType"
    :selected-tool="dialogSelectedTool"
    @close="handleDialogClose"
  />

  <CreateMcpServerDialog
    ref="createMcpDialogRef"
    :type="activeServerDialogType"
    :selected-server="dialogSelectedServer"
    @close="handleMcpDialogClose"
  />

  <McpServerSurfaceDialog
    ref="mcpSurfaceDialogRef"
    :server="dialogSelectedServer"
    @oauth-started="fetchMcpServers"
    @oauth-updated="fetchMcpServers"
    @close="handleMcpDialogClose"
  />

  <DeleteDialog
    v-if="selectedTool || selectedServer"
    ref="deleteDialogRef"
    :entity="selectedTool || selectedServer"
    :type="selectedTool ? 'CustomTools' : 'McpServers'"
    :translation-key="selectedTool ? 'CUSTOM_TOOLS' : 'MCP_SERVERS'"
    @delete-success="onDeleteSuccess"
  />
</template>
