<script setup>
import { ref, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import ToolsDropdown from 'dashboard/components-next/captain/assistant/ToolsDropdown.vue';
import CaptainToolsAPI from 'dashboard/api/captain/tools';
import { useKeyboardNavigableList } from 'dashboard/composables/useKeyboardNavigableList';
import {
  filterAndSortCatalogItems,
  localizeCatalogTool,
} from 'dashboard/helper/captainCatalog';

const props = defineProps({
  searchKey: {
    type: String,
    default: '',
  },
  assistantId: {
    type: Number,
    default: null,
  },
  toolScope: {
    type: String,
    default: 'agent',
  },
});

const emit = defineEmits(['close', 'selectTool']);

const { t, te } = useI18n();

const selectedIndex = ref(0);
const tools = ref([]);
const searchQuery = ref(props.searchKey || '');

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

const localizedTools = computed(() =>
  tools.value.map(tool => localizeCatalogTool(tool, { t, te }))
);

const filteredTools = computed(() => {
  return filterAndSortCatalogItems(localizedTools.value, {
    search: searchQuery.value,
  });
});

const adjustScroll = () => {};

const onSelect = idx => {
  if (idx !== undefined) selectedIndex.value = idx;
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

watch(
  () => props.searchKey,
  newValue => {
    searchQuery.value = newValue || '';
  }
);

watch(searchQuery, () => {
  selectedIndex.value = 0;
});

watch(filteredTools, newListOfTools => {
  if (newListOfTools.length < selectedIndex.value + 1) {
    selectedIndex.value = 0;
  }
});
</script>

<template>
  <ToolsDropdown
    v-model:search-value="searchQuery"
    :items="filteredTools"
    overlay
    :selected-index="selectedIndex"
    @close="emit('close')"
    @select="onSelect"
  />
</template>
