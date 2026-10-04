<script setup>
import { computed, useSlots } from 'vue';

const props = defineProps({
  title: { type: String, default: '' },
  subtitle: { type: String, default: '' },
  // false: the body spans the card edge to edge (tables, stat groups)
  padded: { type: Boolean, default: true },
  as: { type: String, default: 'section' },
});

const slots = useSlots();
const hasHeader = computed(
  () => !!(props.title || slots.header || slots.actions)
);
</script>

<template>
  <component
    :is="as"
    class="min-w-0 rounded-ds-card border border-solid border-n-weak bg-n-solid-2 text-n-slate-12"
  >
    <header
      v-if="hasHeader"
      class="flex flex-wrap items-baseline gap-x-2.5 gap-y-1 px-5 pt-[18px]"
      :class="padded ? 'pb-2' : 'pb-3'"
    >
      <slot name="header">
        <h3 class="m-0 text-sm font-semibold leading-5 text-n-slate-12">
          {{ title }}
        </h3>
        <span v-if="subtitle" class="text-ds-caption text-n-slate-11">
          {{ subtitle }}
        </span>
      </slot>
      <div v-if="slots.actions" class="flex items-center gap-3 ms-auto">
        <slot name="actions" />
      </div>
    </header>
    <div
      :class="{
        'px-5 pb-[18px]': padded,
        'pt-[18px]': padded && !hasHeader,
      }"
    >
      <slot />
    </div>
  </component>
</template>
