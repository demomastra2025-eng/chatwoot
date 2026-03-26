<script setup>
import { computed, useAttrs } from 'vue';

import Input from 'dashboard/components-next/input/Input.vue';

const props = defineProps({
  autofocus: {
    type: Boolean,
    default: false,
  },
  customInputClass: {
    type: [String, Array, Object],
    default: '',
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  label: {
    type: String,
    default: '',
  },
  max: {
    type: [String, Number],
    default: 100,
  },
  message: {
    type: String,
    default: '',
  },
  messageType: {
    type: String,
    default: 'info',
  },
  min: {
    type: [String, Number],
    default: 0,
  },
  placeholder: {
    type: String,
    default: '',
  },
  size: {
    type: String,
    default: 'md',
  },
  step: {
    type: [String, Number],
    default: '0.1',
  },
  symbol: {
    type: String,
    default: '%',
  },
});

const modelValue = defineModel({
  type: [String, Number],
  default: '',
});

defineOptions({
  inheritAttrs: false,
});

const attrs = useAttrs();

const mergedInputClass = computed(() => [
  'tabular-nums !pr-10',
  props.customInputClass,
]);
</script>

<template>
  <Input
    v-bind="attrs"
    v-model="modelValue"
    type="number"
    inputmode="decimal"
    :step="props.step"
    :min="String(props.min)"
    :max="String(props.max)"
    :disabled="props.disabled"
    :label="props.label"
    :placeholder="props.placeholder"
    :size="props.size"
    :message="props.message"
    :message-type="props.messageType"
    :autofocus="props.autofocus"
    :custom-input-class="mergedInputClass"
  >
    <template #suffix>
      <span
        class="pointer-events-none absolute bottom-0 right-3 inline-flex h-10 items-center text-sm text-n-slate-10"
      >
        {{ props.symbol }}
      </span>
    </template>
  </Input>
</template>
