<script setup>
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';

defineProps({
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
  useApiResults: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['open', 'search', 'update:modelValue']);

defineOptions({
  inheritAttrs: false,
});
</script>

<template>
  <div class="grid gap-1">
    <span v-if="label" class="mb-0.5 text-sm font-medium text-n-slate-12">
      {{ label }}
    </span>
    <ComboBox
      v-bind="$attrs"
      :model-value="modelValue"
      :options="options"
      :placeholder="placeholder"
      :search-placeholder="searchPlaceholder"
      :empty-state="emptyState"
      :message="message"
      :has-error="hasError"
      :disabled="disabled"
      :use-api-results="useApiResults"
      input-like
      @open="emit('open')"
      @search="emit('search', $event)"
      @update:model-value="emit('update:modelValue', $event)"
    >
      <template v-if="$slots.append" #append>
        <slot name="append" />
      </template>
    </ComboBox>
  </div>
</template>
