<script setup>
import { computed } from 'vue';
import Icon from 'next/icon/Icon.vue';

const props = defineProps({
  label: {
    type: String,
    default: '',
  },
  icon: {
    type: String,
    default: '',
  },
  to: {
    type: [Object, String],
    default: '',
  },
  active: {
    type: Boolean,
    default: false,
  },
  actionLabel: {
    type: String,
    default: '',
  },
});

const componentType = computed(() => (props.to ? 'router-link' : 'div'));
</script>

<template>
  <component
    :is="componentType"
    :to="to || undefined"
    class="flex items-center gap-2 px-2 py-1.5 rounded-lg h-8 select-none min-w-0"
    :class="{
      'text-n-slate-10 pointer-events-none': !to && !active,
      'text-n-slate-11 hover:bg-n-alpha-2 cursor-pointer': to && !active,
      'text-n-slate-11 cursor-pointer': active,
      'bg-n-alpha-2': active && !actionLabel,
    }"
  >
    <Icon v-if="icon" :icon="icon" class="size-4" />
    <span
      class="text-sm leading-5 flex-grow min-w-0 truncate"
      :class="{
        'font-medium text-n-slate-12': active && !actionLabel,
      }"
    >
      {{ label }}
    </span>
    <span
      v-if="actionLabel"
      class="text-xs font-medium shrink-0 rounded-md px-2 py-0.5"
      :class="{
        'text-n-slate-10': !active,
        'text-n-slate-12 bg-n-alpha-2': active,
      }"
    >
      {{ actionLabel }}
    </span>
  </component>
</template>
