<script setup>
import { computed, ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { loadContextFieldCatalog } from 'dashboard/helper/contextFieldCatalog';

const props = defineProps({
  searchKey: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['selectField']);

const { t } = useI18n();

const fields = ref([]);
const isLoading = ref(false);

const loadFields = async () => {
  isLoading.value = true;

  try {
    fields.value = await loadContextFieldCatalog();
  } catch {
    fields.value = [];
  } finally {
    isLoading.value = false;
  }
};

const filteredFields = computed(() => {
  const search = props.searchKey.trim().toLowerCase();

  return [...fields.value]
    .filter(field => {
      if (!search) return true;

      return [field.title, field.group_name, field.description]
        .filter(Boolean)
        .some(value => value.toLowerCase().includes(search));
    })
    .sort((leftField, rightField) => {
      const groupComparison = (leftField.group_name || '').localeCompare(
        rightField.group_name || ''
      );
      if (groupComparison !== 0) {
        return groupComparison;
      }

      return leftField.title.localeCompare(rightField.title);
    });
});

const groupedFields = computed(() => {
  return filteredFields.value.reduce((groups, field) => {
    const groupName =
      field.group_name || t('WHATSAPP_TEMPLATES.PARSER.FIELD_PICKER_DEFAULT');
    groups[groupName] ||= [];
    groups[groupName].push(field);
    return groups;
  }, {});
});

const onSelect = field => {
  emit('selectField', field);
};

onMounted(loadFields);
</script>

<template>
  <div class="max-h-64 overflow-y-auto">
    <div v-if="isLoading" class="px-1 py-3 text-xs text-center text-n-slate-11">
      {{ t('WHATSAPP_TEMPLATES.PARSER.FIELD_PICKER_LOADING') }}
    </div>

    <div
      v-else-if="!filteredFields.length"
      class="px-1 py-3 text-xs text-center text-n-slate-11"
    >
      {{ t('WHATSAPP_TEMPLATES.PARSER.FIELD_PICKER_EMPTY') }}
    </div>

    <div v-else class="flex flex-col gap-3">
      <div v-for="(groupFields, groupName) in groupedFields" :key="groupName">
        <p
          class="px-1 mb-1 text-[11px] font-semibold uppercase text-n-slate-10"
        >
          {{ groupName }}
        </p>
        <div class="flex flex-col gap-1">
          <button
            v-for="field in groupFields"
            :key="field.id"
            type="button"
            class="px-3 py-2 text-left rounded-lg transition-colors bg-transparent hover:bg-n-alpha-black2 focus:outline-none focus:bg-n-alpha-black2"
            @click="onSelect(field)"
          >
            <p class="text-sm text-n-slate-12">
              {{ field.title }}
            </p>
            <p class="text-xs text-n-slate-11 truncate">
              {{ field.description }}
            </p>
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
