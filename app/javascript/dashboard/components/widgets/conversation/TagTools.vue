<script setup>
import { ref, computed, watch } from 'vue';
import ToolsDropdown from 'dashboard/components-next/captain/assistant/ToolsDropdown.vue';
import CaptainToolsAPI from 'dashboard/api/captain/tools';
import { useKeyboardNavigableList } from 'dashboard/composables/useKeyboardNavigableList';

const props = defineProps({
  searchKey: {
    type: String,
    default: '',
  },
  assistantId: {
    type: Number,
    default: null,
  },
  toolAccess: {
    type: Object,
    default: null,
  },
  toolScope: {
    type: String,
    default: 'agent',
  },
});

const emit = defineEmits(['selectTool']);

const selectedIndex = ref(0);
const tools = ref([]);

const loadTools = async () => {
  try {
    const response = await CaptainToolsAPI.get({
      assistantId: props.assistantId,
      scope: props.toolScope,
    });
    tools.value = response.data || [];
  } catch (error) {
    tools.value = [];
  }
};

const hasDraftToolAccess = computed(() =>
  Object.prototype.hasOwnProperty.call(props.toolAccess || {}, props.toolScope)
);

const selectedTools = computed(() => {
  if (!hasDraftToolAccess.value) {
    return tools.value.filter(tool => tool.selected !== false);
  }

  const rawScope = props.toolAccess?.[props.toolScope] || {};
  const availableToolIds = tools.value.map(tool => tool.id);
  const defaultToolIds = tools.value
    .filter(tool => tool.selected !== false)
    .map(tool => tool.id);
  const hasToolIds = Object.prototype.hasOwnProperty.call(rawScope, 'tool_ids');
  const enabled =
    Object.prototype.hasOwnProperty.call(rawScope, 'enabled') &&
    typeof rawScope.enabled === 'boolean'
      ? rawScope.enabled
      : true;

  if (!enabled) {
    return [];
  }

  const selectedToolIds = (
    hasToolIds ? rawScope.tool_ids : defaultToolIds
  ).filter(toolId => availableToolIds.includes(toolId));
  const selectedSet = new Set(selectedToolIds);

  return tools.value.filter(tool => selectedSet.has(tool.id));
});

const filteredTools = computed(() => {
  const search = props.searchKey?.trim().toLowerCase() || '';

  return [...selectedTools.value]
    .filter(tool => {
      const titleMatches = tool.title.toLowerCase().includes(search);
      const groupMatches = (tool.group_name || '')
        .toLowerCase()
        .includes(search);
      return titleMatches || groupMatches;
    })
    .sort((leftTool, rightTool) => {
      const leftGroup = leftTool.group_name || 'zzzzzzzz';
      const rightGroup = rightTool.group_name || 'zzzzzzzz';
      const groupComparison = leftGroup.localeCompare(rightGroup);
      if (groupComparison !== 0) {
        return groupComparison;
      }

      return leftTool.title.localeCompare(rightTool.title);
    });
});

const adjustScroll = () => {};

const onSelect = idx => {
  if (idx) selectedIndex.value = idx;
  emit('selectTool', filteredTools.value[selectedIndex.value]);
};

useKeyboardNavigableList({
  items: filteredTools,
  onSelect,
  adjustScroll,
  selectedIndex,
});

watch(
  () => [props.assistantId, props.toolScope],
  () => {
    loadTools();
  },
  { immediate: true }
);

watch(filteredTools, newListOfTools => {
  if (newListOfTools.length < selectedIndex.value + 1) {
    selectedIndex.value = 0;
  }
});
</script>

<template>
  <ToolsDropdown
    v-if="filteredTools.length"
    :items="filteredTools"
    :selected-index="selectedIndex"
    @select="onSelect"
  />
  <template v-else />
</template>
