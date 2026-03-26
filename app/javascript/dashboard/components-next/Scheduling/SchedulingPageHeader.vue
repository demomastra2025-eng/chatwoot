<script setup>
defineProps({
  description: {
    type: String,
    default: '',
  },
  title: {
    type: String,
    required: true,
  },
});
</script>

<template>
  <header class="bg-n-surface-1 px-5 pb-2 pt-4">
    <div
      class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between"
    >
      <div class="flex flex-col gap-1">
        <h1 class="mb-0 text-lg font-semibold text-n-slate-12">
          {{ title }}
        </h1>
        <p v-if="description" class="mb-0 text-xs text-n-slate-11">
          {{ description }}
        </p>
      </div>

      <div class="flex items-center gap-2 self-start md:self-auto">
        <slot name="actions" />
      </div>
    </div>
  </header>
</template>
