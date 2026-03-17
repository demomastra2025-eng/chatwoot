<script setup>
import { computed, getCurrentInstance, useAttrs } from 'vue';

const props = defineProps({
  id: {
    type: String,
    default: '',
  },
  disabled: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['change', 'blur', 'focus']);

defineOptions({
  inheritAttrs: false,
});

const { uid } = getCurrentInstance();
const attrs = useAttrs();

const modelValue = defineModel('modelValue', {
  type: [String, Number, Boolean, Array, Object],
  default: '',
});

const inputId = computed(() => props.id || `select-${uid}`);
const selectAttrs = computed(() => {
  const { class: _class, style: _style, ...rest } = attrs;
  return rest;
});
const selectClasses = computed(() => [
  'outline outline-1 outline-offset-[-1px] outline-n-weak dark:outline-n-slate-6 hover:outline-n-slate-6 dark:hover:outline-n-slate-7 focus:outline-n-brand dark:focus:outline-n-brand disabled:cursor-not-allowed disabled:opacity-50 rounded-lg bg-n-alpha-black2 dark:bg-n-solid-1 text-n-slate-12',
  attrs.class,
]);
</script>

<template>
  <select
    :id="inputId"
    v-model="modelValue"
    v-bind="selectAttrs"
    :disabled="disabled"
    :class="selectClasses"
    :style="attrs.style"
    @change="emit('change', $event)"
    @blur="emit('blur', $event)"
    @focus="emit('focus', $event)"
  >
    <slot />
  </select>
</template>
