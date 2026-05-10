<script setup>
import { ref, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import ToolsDropdown from 'dashboard/components-next/captain/assistant/ToolsDropdown.vue';
import CaptainContextFieldsAPI from 'dashboard/api/captain/contextFields';
import { useKeyboardNavigableList } from 'dashboard/composables/useKeyboardNavigableList';
import {
  filterAndSortCatalogItems,
  localizeCatalogField,
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
  usedItemIds: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['close', 'selectField']);

const { t, te } = useI18n();

const selectedIndex = ref(0);
const fields = ref([]);
const searchQuery = ref(props.searchKey || '');

const FIELD_GROUP_ORDER = [
  'Contact',
  'Contact Attributes',
  'Conversation',
  'Conversation Attributes',
  'Appointment',
  'Appointment Attributes',
  'Deal',
  'Deal Attributes',
  'Task',
  'Task Attributes',
];

const loadFields = async () => {
  try {
    const response = await CaptainContextFieldsAPI.get({
      assistantId: props.assistantId,
    });
    fields.value = response.data || [];
  } catch (error) {
    fields.value = [];
  }
};

const usedItemIdSet = computed(() => new Set(props.usedItemIds || []));

const normalizedFields = computed(() =>
  fields.value.map(field => ({
    ...localizeCatalogField(field, { t, te }),
    isUsed: usedItemIdSet.value.has(field.id),
  }))
);

const filteredFields = computed(() => {
  return filterAndSortCatalogItems(normalizedFields.value, {
    search: searchQuery.value,
    groupOrder: FIELD_GROUP_ORDER,
  });
});

const onSelect = idx => {
  if (idx !== undefined) selectedIndex.value = idx;
  emit('selectField', filteredFields.value[selectedIndex.value]);
  emit('close');
};

useKeyboardNavigableList({
  items: filteredFields,
  onSelect,
  adjustScroll: () => {},
  selectedIndex,
});

watch(
  () => props.assistantId,
  () => {
    loadFields();
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

watch(filteredFields, newFields => {
  if (newFields.length < selectedIndex.value + 1) {
    selectedIndex.value = 0;
  }
});
</script>

<template>
  <ToolsDropdown
    v-model:search-value="searchQuery"
    :items="filteredFields"
    overlay
    :selected-index="selectedIndex"
    @close="emit('close')"
    @select="onSelect"
  />
</template>
