<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import CaptainContextFieldsAPI from 'dashboard/api/captain/contextFields';

const props = defineProps({
  modelValue: {
    type: Object,
    default: () => ({}),
  },
  assistantId: {
    type: Number,
    default: null,
  },
});

const emit = defineEmits(['update:modelValue']);

const { t } = useI18n();

const availableFields = ref([]);
const isLoading = ref(false);

const TABLES = Object.freeze(['contact', 'conversation']);

const tableMetadata = computed(() => ({
  contact: {
    title: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONTACT.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONTACT.DESCRIPTION'
    ),
  },
  conversation: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONVERSATION.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONVERSATION.DESCRIPTION'
    ),
  },
}));

const loadFields = async () => {
  isLoading.value = true;

  try {
    const response = await CaptainContextFieldsAPI.get({
      assistantId: props.assistantId,
    });
    availableFields.value = response.data || [];
  } catch (error) {
    availableFields.value = [];
  } finally {
    isLoading.value = false;
  }
};

const fieldsByTable = computed(() => {
  return TABLES.reduce((result, tableName) => {
    const groups = new Map();

    availableFields.value
      .filter(field => field.table_name === tableName)
      .sort((leftField, rightField) => {
        const groupComparison = (leftField.group_name || '').localeCompare(
          rightField.group_name || ''
        );
        if (groupComparison !== 0) {
          return groupComparison;
        }

        return leftField.title.localeCompare(rightField.title);
      })
      .forEach(field => {
        const groupName =
          field.group_name || tableMetadata.value[tableName].title;
        if (!groups.has(groupName)) {
          groups.set(groupName, []);
        }

        groups.get(groupName).push(field);
      });

    result[tableName] = Array.from(groups.entries()).map(
      ([groupName, fields]) => ({
        groupName,
        fields,
      })
    );

    return result;
  }, {});
});

const normalizedAccess = computed(() => {
  return TABLES.reduce((result, tableName) => {
    const rawScope = props.modelValue?.[tableName] || {};
    const tableFields = availableFields.value.filter(
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

    result[tableName] = {
      enabled:
        Object.prototype.hasOwnProperty.call(rawScope, 'enabled') &&
        typeof rawScope.enabled === 'boolean'
          ? rawScope.enabled
          : true,
      fieldIds: (hasFieldIds ? rawScope.field_ids : defaultFieldIds).filter(
        fieldId => availableFieldIds.includes(fieldId)
      ),
    };

    return result;
  }, {});
});

const serializedAccess = computed(() => {
  return TABLES.reduce((result, tableName) => {
    result[tableName] = {
      enabled: normalizedAccess.value[tableName].enabled,
      field_ids: normalizedAccess.value[tableName].fieldIds,
    };

    return result;
  }, {});
});

const updateAccess = nextAccess => {
  emit('update:modelValue', nextAccess);
};

const updateTableEnabled = (tableName, enabled) => {
  updateAccess({
    ...serializedAccess.value,
    [tableName]: {
      ...serializedAccess.value[tableName],
      enabled,
    },
  });
};

const toggleFieldSelection = (tableName, fieldId, checked) => {
  const selectedIds = new Set(serializedAccess.value[tableName].field_ids);

  if (checked) {
    selectedIds.add(fieldId);
  } else {
    selectedIds.delete(fieldId);
  }

  updateAccess({
    ...serializedAccess.value,
    [tableName]: {
      ...serializedAccess.value[tableName],
      field_ids: Array.from(selectedIds),
    },
  });
};

watch(
  () => props.assistantId,
  () => {
    loadFields();
  },
  { immediate: true }
);

watch(
  [availableFields, serializedAccess],
  () => {
    if (!availableFields.value.length) return;

    const currentValue = JSON.stringify(props.modelValue || {});
    const nextValue = JSON.stringify(serializedAccess.value);
    if (currentValue !== nextValue) {
      emit('update:modelValue', serializedAccess.value);
    }
  },
  { deep: true, immediate: true }
);
</script>

<template>
  <div class="flex flex-col gap-4">
    <div class="flex flex-col gap-1">
      <h4 class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TITLE') }}
      </h4>
      <p class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.DESCRIPTION') }}
      </p>
      <p class="text-xs text-n-slate-10">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.HINT') }}
      </p>
    </div>

    <div
      v-for="tableName in TABLES"
      :key="tableName"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-4"
    >
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <h5 class="text-sm font-medium text-n-slate-12">
            {{ tableMetadata[tableName].title }}
          </h5>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ tableMetadata[tableName].description }}
          </p>
        </div>

        <Switch
          :model-value="normalizedAccess[tableName].enabled"
          class="data-[state=checked]:!bg-n-violet-9"
          @update:model-value="value => updateTableEnabled(tableName, value)"
        />
      </div>

      <div v-if="isLoading" class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.LOADING') }}
      </div>

      <div
        v-else-if="normalizedAccess[tableName].enabled"
        class="grid grid-cols-1 gap-4 md:grid-cols-2"
      >
        <div
          v-for="group in fieldsByTable[tableName]"
          :key="group.groupName"
          class="rounded-lg border border-n-weak bg-n-alpha-2 p-3 flex flex-col gap-3"
        >
          <div class="text-sm font-medium text-n-slate-12">
            {{ group.groupName }}
          </div>

          <div class="flex flex-col gap-2">
            <label
              v-for="field in group.fields"
              :key="field.id"
              class="flex items-start gap-2"
            >
              <Checkbox
                :model-value="
                  normalizedAccess[tableName].fieldIds.includes(field.id)
                "
                @update:model-value="
                  value => toggleFieldSelection(tableName, field.id, value)
                "
              />
              <span class="min-w-0">
                <span class="block text-sm font-medium text-n-slate-12">
                  {{ field.title }}
                </span>
                <span class="block text-xs text-n-slate-10">
                  {{ field.description }}
                </span>
              </span>
            </label>
          </div>
        </div>

        <p
          v-if="!fieldsByTable[tableName]?.length"
          class="text-sm text-n-slate-11"
        >
          {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.EMPTY') }}
        </p>
      </div>

      <p v-else class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.DISABLED_MESSAGE') }}
      </p>
    </div>
  </div>
</template>
