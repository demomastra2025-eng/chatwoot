<script setup>
import { ref } from 'vue';
import { useDebounceFn } from '@vueuse/core';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';

const props = defineProps({
  compact: {
    type: Boolean,
    default: false,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  emptyState: {
    type: String,
    default: '',
  },
  hasError: {
    type: Boolean,
    default: false,
  },
  label: {
    type: String,
    default: '',
  },
  inlineDropdown: {
    type: Boolean,
    default: false,
  },
  message: {
    type: String,
    default: '',
  },
  modelValue: {
    type: [String, Number],
    default: '',
  },
  options: {
    type: Array,
    required: true,
  },
  placeholder: {
    type: String,
    default: '',
  },
  searchPlaceholder: {
    type: String,
    default: '',
  },
  searchInTrigger: {
    type: Boolean,
    default: false,
  },
  searchDebounceMs: {
    type: Number,
    default: 0,
  },
  useApiResults: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['open', 'search', 'update:modelValue']);
const comboBoxRef = ref(null);
const debouncedSearch = useDebounceFn(
  value => emit('search', value),
  props.searchDebounceMs
);
const handleSearch = value => {
  if (props.searchDebounceMs > 0) {
    debouncedSearch(value);
    return;
  }

  emit('search', value);
};

const open = () => comboBoxRef.value?.open();

defineExpose({ open });

defineOptions({
  inheritAttrs: false,
});
</script>

<template>
  <div
    class="grid gap-1"
    :class="{
      'md:grid-cols-[7.5rem_minmax(0,1fr)] md:items-center md:gap-3': compact,
    }"
  >
    <span
      v-if="label"
      class="mb-0.5 text-sm font-medium text-n-slate-12"
      :class="{ 'md:mb-0': compact }"
    >
      {{ label }}
    </span>
    <ComboBox
      ref="comboBoxRef"
      v-bind="$attrs"
      :model-value="modelValue"
      :options="options"
      :inline-dropdown="inlineDropdown"
      :placeholder="placeholder"
      :search-placeholder="searchPlaceholder"
      :search-in-trigger="searchInTrigger"
      :empty-state="emptyState"
      :message="message"
      :has-error="hasError"
      :disabled="disabled"
      :use-api-results="useApiResults"
      input-like
      @open="emit('open')"
      @search="handleSearch"
      @update:model-value="emit('update:modelValue', $event)"
    >
      <template v-if="$slots.append" #append>
        <slot name="append" />
      </template>
    </ComboBox>
  </div>
</template>
