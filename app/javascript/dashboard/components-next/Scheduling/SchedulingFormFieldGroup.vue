<script setup>
import { computed } from 'vue';

const props = defineProps({
  description: {
    type: String,
    default: '',
  },
  framed: {
    type: Boolean,
    default: true,
  },
  title: {
    type: String,
    default: '',
  },
});

const sectionClass = computed(() =>
  props.framed
    ? 'overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container shadow-sm'
    : 'overflow-visible'
);

const headerClass = computed(() =>
  props.framed
    ? 'flex flex-col gap-3 px-5 py-4 md:flex-row md:items-start md:justify-between'
    : 'flex flex-col gap-1 md:flex-row md:items-start md:justify-between'
);

const bodyClass = computed(() =>
  props.framed ? 'grid gap-4 px-5 py-4' : 'grid gap-4 pt-1'
);
</script>

<template>
  <section :class="sectionClass">
    <div
      v-if="title || description || $slots.headerActions"
      :class="headerClass"
    >
      <div v-if="title || description" class="flex min-w-0 flex-col gap-1">
        <h3 v-if="title" class="mb-0 text-sm font-semibold text-n-slate-12">
          {{ title }}
        </h3>
        <p v-if="description" class="mb-0 text-xs text-n-slate-11">
          {{ description }}
        </p>
      </div>
      <div
        v-if="$slots.headerActions"
        class="flex shrink-0 items-center gap-2 self-start md:self-auto"
      >
        <slot name="headerActions" />
      </div>
    </div>
    <div :class="bodyClass">
      <slot />
    </div>
  </section>
</template>
