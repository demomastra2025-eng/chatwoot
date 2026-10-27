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
  createOptionLabel: {
    type: String,
    default: '',
  },
  showCreateAlways: { type: Boolean, default: false },
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
  remoteOptions: { type: Array, default: () => [] },
  remoteTitle: { type: String, default: '' },
  remoteLoading: { type: Boolean, default: false },
  remoteError: { type: Boolean, default: false },
  remoteTruncated: { type: Boolean, default: false },
  remoteLoadingLabel: { type: String, default: '' },
  remoteErrorLabel: { type: String, default: '' },
  remoteTruncatedLabel: { type: String, default: '' },
  remotePhoneLabel: { type: String, default: '' },
  remoteHint: { type: String, default: '' },
  remoteBusyToken: { type: String, default: '' },
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
  wrapLabel: {
    type: Boolean,
    default: false,
  },
  clampSelectedLabel: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'create',
  'open',
  'close',
  'search',
  'selectRemote',
  'update:modelValue',
]);
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
const close = () => comboBoxRef.value?.close();

defineExpose({ open, close });

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
      :remote-options="remoteOptions"
      :remote-title="remoteTitle"
      :remote-loading="remoteLoading"
      :remote-error="remoteError"
      :remote-truncated="remoteTruncated"
      :remote-loading-label="remoteLoadingLabel"
      :remote-error-label="remoteErrorLabel"
      :remote-truncated-label="remoteTruncatedLabel"
      :remote-phone-label="remotePhoneLabel"
      :remote-hint="remoteHint"
      :remote-busy-token="remoteBusyToken"
      :inline-dropdown="inlineDropdown"
      :placeholder="placeholder"
      :search-placeholder="searchPlaceholder"
      :search-in-trigger="searchInTrigger"
      :empty-state="emptyState"
      :create-option-label="createOptionLabel"
      :show-create-always="showCreateAlways"
      :message="message"
      :has-error="hasError"
      :disabled="disabled"
      :use-api-results="useApiResults"
      :wrap-label="wrapLabel"
      :clamp-selected-label="clampSelectedLabel"
      input-like
      @create="emit('create', $event)"
      @open="emit('open')"
      @close="emit('close')"
      @search="handleSearch"
      @select-remote="emit('selectRemote', $event)"
      @update:model-value="emit('update:modelValue', $event)"
    >
      <template v-if="$slots.append" #append>
        <slot name="append" />
      </template>
    </ComboBox>
  </div>
</template>
