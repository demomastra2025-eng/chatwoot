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

const store = useStore();
const { t } = useI18n();

const customToolFlags = useMapGetter('captainCustomTools/getUIFlags');
const customTools = useMapGetter('captainCustomTools/getRecords');
const customToolsMeta = useMapGetter('captainCustomTools/getMeta');
const mcpServerFlags = useMapGetter('captainMcpServers/getUIFlags');
const mcpServers = useMapGetter('captainMcpServers/getRecords');

const EMPTY_SELECTED_TOOL = Object.freeze({});
const EMPTY_SELECTED_SERVER = Object.freeze({});

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

const sortTools = tools =>
  [...tools].sort((leftTool, rightTool) => {
    const leftTitle = leftTool.title?.toLowerCase() || '';
    const rightTitle = rightTool.title?.toLowerCase() || '';
    return leftTitle.localeCompare(rightTitle);
  });

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
    :is-empty="!customTools.length && !mcpServers.length"
    :feature-flag="FEATURE_FLAGS.CAPTAIN_V2"
    :show-know-more="false"
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
