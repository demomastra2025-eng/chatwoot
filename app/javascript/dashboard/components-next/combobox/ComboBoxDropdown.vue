<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

const props = defineProps({
  dropdownStyle: {
    type: Object,
    default: () => ({}),
  },
  teleportTarget: {
    type: [String, Object],
    default: 'body',
  },
  open: {
    type: Boolean,
    required: true,
  },
  options: {
    type: Array,
    required: true,
  },
  searchPlaceholder: {
    type: String,
    default: '',
  },
  emptyState: {
    type: String,
    default: '',
  },
  multiple: {
    type: Boolean,
    default: false,
  },
  selectedValues: {
    type: [String, Number, Array],
    default: () => [],
  },
});

const emit = defineEmits(['select', 'search']);

const { t } = useI18n();

const searchValue = defineModel('searchValue', {
  type: String,
  default: '',
});

const searchInput = ref(null);

const isSelected = option => {
  if (Array.isArray(props.selectedValues)) {
    return props.selectedValues.includes(option.value);
  }
  return option.value === props.selectedValues;
};

const onInputSearch = event => {
  searchValue.value = event.target.value;
  emit('search', event.target.value);
};

defineExpose({
  focus: () => searchInput.value?.focus(),
});
</script>

<template>
  <Teleport :to="teleportTarget">
    <div
      v-show="open"
      data-modal-safe-interaction
      class="dashboard-combobox-dropdown fixed z-[170] flex flex-col overflow-hidden rounded-lg border border-n-weak bg-n-solid-2/95 p-2 shadow-xl outline outline-1 outline-n-container transition-opacity duration-150 backdrop-blur-[16px]"
      :style="props.dropdownStyle"
      @mousedown.stop
      @mouseup.stop
      @click.stop
    >
      <div class="border-b border-n-weak pb-2">
        <div class="relative flex items-center">
          <span
            class="pointer-events-none absolute inset-y-0 right-3 left-auto my-auto inline-flex size-4 items-center justify-center i-lucide-search text-n-slate-10 rtl:right-auto rtl:left-3"
          />
          <input
            ref="searchInput"
            :value="searchValue"
            type="text"
            :placeholder="searchPlaceholder || t('COMBOBOX.SEARCH_PLACEHOLDER')"
            class="reset-base h-10 w-full appearance-none rounded-lg border-none bg-n-alpha-black2 py-2 pl-5 pr-10 text-sm text-n-slate-12 outline outline-1 outline-n-weak focus:outline-n-brand rtl:pr-5 rtl:pl-10"
            @input="onInputSearch"
          />
        </div>
      </div>
      <ul
        class="mb-0 min-h-0 flex-1 overflow-auto pt-2"
        role="listbox"
        :aria-multiselectable="multiple"
      >
        <li
          v-for="option in options"
          :key="option.value"
          class="flex w-full cursor-pointer items-center justify-between gap-2 rounded-lg px-3 py-2 text-sm transition-colors duration-150 hover:bg-n-alpha-2"
          :class="{
            'bg-n-alpha-2': isSelected(option),
          }"
          role="option"
          :aria-selected="isSelected(option)"
          @click="emit('select', option)"
        >
          <span class="flex min-w-0 flex-1 items-center gap-2 text-left">
            <Avatar
              v-if="option.thumbnail"
              :name="option.thumbnail.name || option.label"
              :src="option.thumbnail.src"
              :size="20"
              rounded-full
            />
            <span
              v-else-if="option.stageColor"
              class="h-5 w-1 shrink-0 rounded-full"
              :style="{ backgroundColor: option.stageColor }"
              aria-hidden="true"
            />
            <span
              v-if="option.icon"
              class="size-4 flex-shrink-0"
              :class="[option.icon, option.iconClass || 'text-n-slate-11']"
              aria-hidden="true"
            />
            <span
              :class="[
                option.labelClass || 'text-n-slate-12',
                {
                  'font-medium': isSelected(option),
                  truncate: !option.wrapLabel,
                  'whitespace-normal break-words': option.wrapLabel,
                },
              ]"
              class="min-w-0 flex-1 text-left"
              :title="option.label"
            >
              {{ option.label }}
            </span>
          </span>
          <a
            v-if="option.href"
            class="inline-flex size-6 shrink-0 items-center justify-center rounded-md text-n-slate-10 transition-colors hover:bg-n-alpha-black2 hover:text-n-slate-12"
            :href="option.href"
            target="_blank"
            rel="noopener noreferrer"
            :aria-label="$t('COMBOBOX.OPEN_IN_NEW_TAB')"
            @click.stop
          >
            <span class="i-lucide-external-link size-3.5" aria-hidden="true" />
          </a>
          <span
            v-if="isSelected(option)"
            class="flex-shrink-0 i-lucide-check size-4 text-n-slate-11"
          />
        </li>
        <li
          v-if="options.length === 0"
          class="px-3 py-3 text-sm text-n-slate-11"
        >
          {{ emptyState || t('COMBOBOX.EMPTY_STATE') }}
        </li>
      </ul>
    </div>
  </Teleport>
</template>
