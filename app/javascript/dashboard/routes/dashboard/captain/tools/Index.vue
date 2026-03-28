<script setup>
import { computed, onMounted, ref, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import CustomToolsPageEmptyState from 'dashboard/components-next/captain/pageComponents/emptyStates/CustomToolsPageEmptyState.vue';
import CreateCustomToolDialog from 'dashboard/components-next/captain/pageComponents/customTool/CreateCustomToolDialog.vue';
import CustomToolCard from 'dashboard/components-next/captain/pageComponents/customTool/CustomToolCard.vue';
import DeleteDialog from 'dashboard/components-next/captain/pageComponents/DeleteDialog.vue';

const store = useStore();
const { t } = useI18n();

const uiFlags = useMapGetter('captainCustomTools/getUIFlags');
const customTools = useMapGetter('captainCustomTools/getRecords');
const isFetching = computed(() => uiFlags.value.fetchingList);
const customToolsMeta = useMapGetter('captainCustomTools/getMeta');
const EMPTY_SELECTED_TOOL = Object.freeze({});

const createDialogRef = ref(null);
const deleteDialogRef = ref(null);
const selectedTool = ref(null);
const dialogType = ref('');
const activeDialogType = computed(() => dialogType.value || 'create');
const dialogSelectedTool = computed(
  () => selectedTool.value || EMPTY_SELECTED_TOOL
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

const onPageChange = page => fetchCustomTools(page);

const openCreateDialog = () => {
  dialogType.value = 'create';
  selectedTool.value = null;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleEdit = tool => {
  dialogType.value = 'edit';
  selectedTool.value = tool;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleDelete = tool => {
  selectedTool.value = tool;
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

const handleDialogClose = () => {
  dialogType.value = '';
  selectedTool.value = null;
};

const onDeleteSuccess = () => {
  selectedTool.value = null;
  // Check if page will be empty after deletion
  if (customTools.value.length === 1 && customToolsMeta.value.page > 1) {
    // Go to previous page if current page will be empty
    onPageChange(customToolsMeta.value.page - 1);
  } else {
    // Refresh current page
    fetchCustomTools(customToolsMeta.value.page);
  }
};

onMounted(() => {
  fetchCustomTools();
});
</script>

<template>
  <PageLayout
    :header-title="$t('CAPTAIN.CUSTOM_TOOLS.HEADER')"
    :button-label="$t('CAPTAIN.CUSTOM_TOOLS.ADD_NEW')"
    :button-policy="['administrator']"
    :total-count="customToolsMeta.totalCount"
    :current-page="customToolsMeta.page"
    :show-pagination-footer="!isFetching && !!customTools.length"
    :is-fetching="isFetching"
    :is-empty="!customTools.length"
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

  <DeleteDialog
    v-if="selectedTool"
    ref="deleteDialogRef"
    :entity="selectedTool"
    type="CustomTools"
    translation-key="CUSTOM_TOOLS"
    @delete-success="onDeleteSuccess"
  />
</template>
