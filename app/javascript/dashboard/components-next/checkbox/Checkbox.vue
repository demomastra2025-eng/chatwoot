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
    default: true,
  },
  indeterminate: {
    type: Boolean,
    default: false,
  },
  disabled: {
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
  type: [Boolean, Array],
  default: false,
});

const inputId = computed(() => props.id || `checkbox-${uid}`);
const inputAttrs = computed(() => {
  const { class: _class, style: _style, ...rest } = attrs;
  return rest;
});
const isArrayModel = computed(() => Array.isArray(modelValue.value));
const isChecked = computed(() => {
  if (isArrayModel.value) {
    return modelValue.value.includes(props.value);
  }

  return Boolean(modelValue.value);
});

const handleChange = event => {
  if (isArrayModel.value) {
    const nextValues = [...modelValue.value];
    const valueIndex = nextValues.findIndex(item => item === props.value);

    if (event.target.checked && valueIndex === -1) {
      nextValues.push(props.value);
    }

    if (!event.target.checked && valueIndex !== -1) {
      nextValues.splice(valueIndex, 1);
    }

    modelValue.value = nextValues;
  } else {
    modelValue.value = event.target.checked;
  }

  emit('change', event);
};
</script>

<template>
  <div :class="attrs.class" :style="attrs.style" class="relative w-4 h-4">
    <input
      v-bind="inputAttrs"
      :id="inputId"
      :checked="isChecked"
      :indeterminate="indeterminate"
      type="checkbox"
      :value="value"
      :name="name || undefined"
      :disabled="disabled"
      class="peer absolute inset-0 z-10 h-4 w-4 appearance-none rounded border border-n-strong bg-transparent ring-transparent transition-all duration-200 hover:enabled:border-n-slate-7 dark:hover:enabled:border-n-slate-8 hover:enabled:bg-n-slate-4 dark:hover:enabled:bg-n-slate-6 checked:border-n-brand-solid checked:bg-n-brand-solid indeterminate:border-n-brand-solid indeterminate:bg-n-brand-solid disabled:opacity-50 cursor-pointer"
      @change="handleChange"
    />
    <!-- Checkmark SVG -->
    <svg
      viewBox="0 0 14 14"
      fill="none"
      class="pointer-events-none absolute w-3.5 h-3.5 z-20 stroke-n-brand-contrast opacity-0 peer-checked:opacity-100 transition-opacity duration-200 left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2"
    >
      <path
        d="M3 8L6 11L11 3.5"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    <!-- Minus/Indeterminate SVG -->
    <svg
      viewBox="0 0 14 14"
      fill="none"
      class="pointer-events-none absolute w-3.5 h-3.5 z-20 stroke-n-brand-contrast opacity-0 peer-indeterminate:opacity-100 transition-opacity duration-200 left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2"
    >
      <path
        d="M3 7L11 7"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  </div>
</template>
