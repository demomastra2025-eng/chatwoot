<script setup>
import { computed, getCurrentInstance, useAttrs } from 'vue';

const props = defineProps({
  id: {
    type: String,
    default: '',
  },
  name: {
    type: String,
    default: '',
  },
  value: {
    type: [String, Number, Boolean],
    required: true,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  srOnly: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['change']);

defineOptions({
  inheritAttrs: false,
});

const { uid } = getCurrentInstance();
const attrs = useAttrs();

const modelValue = defineModel('modelValue', {
  type: [String, Number, Boolean],
  default: null,
});

const inputId = computed(() => props.id || `radio-${uid}`);
const inputAttrs = computed(() => {
  const { class: _class, style: _style, ...rest } = attrs;
  return rest;
});
const isChecked = computed(() => modelValue.value === props.value);

const handleChange = event => {
  modelValue.value = props.value;
  emit('change', event);
};
</script>

<template>
  <div
    :class="[
      attrs.class,
      props.srOnly
        ? 'sr-only h-0 w-0 overflow-hidden'
        : 'relative h-4 w-4 shrink-0',
    ]"
    :style="attrs.style"
  >
    <input
      v-bind="inputAttrs"
      :id="inputId"
      :checked="isChecked"
      :value="value"
      :name="name || undefined"
      type="radio"
      :disabled="disabled"
      class="peer absolute inset-0 z-10 h-4 w-4 cursor-pointer appearance-none rounded-full border border-n-slate-6 ring-transparent transition-all duration-200 checked:border-n-brand-solid checked:bg-n-brand-solid hover:enabled:border-n-brand-solid disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-600 dark:checked:border-n-brand-solid"
      @change="handleChange"
    />
    <span
      v-if="!props.srOnly"
      class="pointer-events-none absolute left-1/2 top-1/2 z-20 h-1.5 w-1.5 -translate-x-1/2 -translate-y-1/2 rounded-full bg-n-brand-contrast opacity-0 transition-opacity duration-200 peer-checked:opacity-100"
    />
  </div>
</template>
