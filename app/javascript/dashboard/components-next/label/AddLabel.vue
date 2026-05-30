<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  labelMenuItems: {
    type: Array,
    default: () => [],
  },
  allowManagement: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['updateLabel', 'createLabel', 'editLabel']);

const { t } = useI18n();

const showDropdown = ref(false);
const searchQuery = ref('');

const filteredLabelMenuItems = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return props.labelMenuItems;

  return props.labelMenuItems.filter(item =>
    item.label.toLowerCase().includes(query)
  );
});

const closeDropdown = () => {
  showDropdown.value = false;
  searchQuery.value = '';
};

const handleLabelSelect = item => {
  emit('updateLabel', item);
  closeDropdown();
};

const handleEditLabel = item => {
  emit('editLabel', item);
  closeDropdown();
};

const handleCreateLabel = () => {
  emit('createLabel');
  closeDropdown();
};
</script>

<template>
  <div class="relative">
    <button
      class="flex items-center gap-1 px-2 py-1 rounded-md outline-dashed h-6 outline-1 outline-n-slate-6 hover:bg-n-alpha-2"
      :class="{ 'bg-n-alpha-2': showDropdown }"
      @click="showDropdown = !showDropdown"
    >
      <span class="i-lucide-plus" />
      <span class="text-sm text-n-slate-11">
        {{ t('LABEL.TAG_BUTTON') }}
      </span>
    </button>
    <div
      v-if="showDropdown"
      v-on-clickaway="closeDropdown"
      class="absolute z-[100] w-60 mt-2 overflow-hidden ltr:left-0 rtl:right-0 top-full rounded-xl bg-n-alpha-3 backdrop-blur-[100px] outline outline-1 outline-n-container shadow-lg"
    >
      <div class="sticky top-0 z-20 p-2 bg-n-alpha-3 backdrop-blur-sm">
        <div class="relative">
          <span
            class="absolute i-lucide-search size-3.5 top-2 ltr:right-3 rtl:left-3 text-n-slate-10"
          />
          <input
            v-model="searchQuery"
            type="search"
            :placeholder="t('LABEL_MGMT.SEARCH_PLACEHOLDER')"
            class="reset-base w-full h-8 border-none rounded-lg bg-n-alpha-black2 dark:bg-n-solid-1 py-2 text-sm text-n-slate-12 focus:outline-none [appearance:textfield] [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none [&::-webkit-search-results-button]:appearance-none [&::-webkit-search-results-decoration]:appearance-none ltr:pl-3.5 rtl:pr-3.5 ltr:pr-10 rtl:pl-10"
          />
        </div>
      </div>

      <div class="max-h-52 overflow-y-auto no-scrollbar px-2 pb-2">
        <div
          v-for="item in filteredLabelMenuItems"
          :key="item.value"
          class="group flex items-center gap-1 rounded-lg transition-colors duration-150 hover:bg-n-alpha-1 dark:hover:bg-n-alpha-2"
          :class="{ 'bg-n-alpha-1 dark:bg-n-solid-active': item.isSelected }"
        >
          <button
            type="button"
            class="flex h-8 min-w-0 flex-1 items-center gap-2 px-2 py-1.5 text-start text-n-slate-12"
            @click="handleLabelSelect(item)"
          >
            <span
              class="rounded-sm size-2 flex-shrink-0"
              :style="{ backgroundColor: item.thumbnail.color }"
            />
            <span class="min-w-0 flex-1 truncate text-sm">
              {{ item.label }}
            </span>
            <span
              v-if="item.isSelected"
              class="i-lucide-check size-3.5 flex-shrink-0 text-n-brand"
            />
          </button>
          <button
            v-if="allowManagement"
            type="button"
            class="inline-flex size-8 flex-shrink-0 items-center justify-center rounded-lg text-n-slate-11 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-n-brand"
            :title="t('LABEL_MGMT.FORM.EDIT')"
            :aria-label="t('LABEL_MGMT.FORM.EDIT')"
            @click.stop="handleEditLabel(item)"
          >
            <span class="i-ph-pencil-simple size-5" />
          </button>
        </div>
        <div
          v-if="!filteredLabelMenuItems.length"
          class="px-2 py-2 text-sm text-n-slate-11"
        >
          {{ t('CONTACT_PANEL.LABELS.LABEL_SELECT.NO_RESULT') }}
        </div>
      </div>

      <div v-if="allowManagement" class="border-t border-n-weak p-2">
        <button
          type="button"
          class="flex h-8 w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm font-medium text-n-brand transition-colors hover:bg-n-alpha-2"
          @click="handleCreateLabel"
        >
          <span class="i-lucide-plus size-4" />
          <span>{{ t('CONTACT_PANEL.LABELS.LABEL_SELECT.CREATE_LABEL') }}</span>
        </button>
      </div>
    </div>
  </div>
</template>
