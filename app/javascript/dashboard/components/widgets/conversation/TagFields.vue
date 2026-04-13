<script setup>
import { ref, computed, watch } from 'vue';
import ToolsDropdown from 'dashboard/components-next/captain/assistant/ToolsDropdown.vue';
import CaptainContextFieldsAPI from 'dashboard/api/captain/contextFields';
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
  contextAccess: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['close', 'selectField']);

const selectedIndex = ref(0);
const fields = ref([]);
const TABLES = Object.freeze(['contact', 'conversation']);

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

const hasDraftContextAccess = computed(() =>
  TABLES.some(tableName =>
    Object.prototype.hasOwnProperty.call(props.contextAccess || {}, tableName)
  )
);

const selectedFields = computed(() => {
  if (!hasDraftContextAccess.value) {
    return fields.value.filter(field => field.selected);
  }

  const selectedFieldIds = new Set();

  TABLES.forEach(tableName => {
    const rawScope = props.contextAccess?.[tableName] || {};
    const tableFields = fields.value.filter(
      field => field.table_name === tableName
    );
    const availableFieldIds = tableFields.map(field => field.id);
    const hasFieldIds = Object.prototype.hasOwnProperty.call(
      rawScope,
      'field_ids'
    );
    const defaultFieldIds = tableFields
      .filter(field => field.selected !== false)
      .map(field => field.id);
    const enabled =
      Object.prototype.hasOwnProperty.call(rawScope, 'enabled') &&
      typeof rawScope.enabled === 'boolean'
        ? rawScope.enabled
        : true;

    if (!enabled) {
      return;
    }

    const fieldIds = (
      hasFieldIds ? rawScope.field_ids : defaultFieldIds
    ).filter(fieldId => availableFieldIds.includes(fieldId));
    fieldIds.forEach(fieldId => selectedFieldIds.add(fieldId));
  });

  return fields.value.filter(field => selectedFieldIds.has(field.id));
});

const filteredFields = computed(() => {
  const search = props.searchKey?.trim().toLowerCase() || '';

  return [...selectedFields.value]
    .filter(field => {
      const titleMatches = field.title.toLowerCase().includes(search);
      const groupMatches = (field.group_name || '')
        .toLowerCase()
        .includes(search);
      const descriptionMatches = (field.description || '')
        .toLowerCase()
        .includes(search);

      return titleMatches || groupMatches || descriptionMatches;
    })
    .sort((leftField, rightField) => {
      const leftGroup = leftField.group_name || 'zzzzzzzz';
      const rightGroup = rightField.group_name || 'zzzzzzzz';
      const groupComparison = leftGroup.localeCompare(rightGroup);
      if (groupComparison !== 0) {
        return groupComparison;
      }

      return leftField.title.localeCompare(rightField.title);
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

watch(filteredFields, newFields => {
  if (newFields.length < selectedIndex.value + 1) {
    selectedIndex.value = 0;
  }
});
</script>

<template>
  <ToolsDropdown
    v-if="filteredFields.length"
    :items="filteredFields"
    overlay
    :selected-index="selectedIndex"
    @close="emit('close')"
    @select="onSelect"
  />
  <template v-else />
</template>
