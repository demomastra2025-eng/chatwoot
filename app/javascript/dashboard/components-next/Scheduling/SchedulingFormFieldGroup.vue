<script setup>
defineProps({
  description: {
    type: String,
    default: '',
  },
  title: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <section class="flex flex-col gap-4">
    <div v-if="title || description" class="flex flex-col gap-1">
      <h3 v-if="title" class="mb-0 text-sm font-semibold text-n-slate-12">
        {{ title }}
      </h3>
      <p v-if="description" class="mb-0 text-xs text-n-slate-11">
        {{ description }}
      </p>
    </div>
    <div class="grid gap-4">
      <slot />
    </div>
  </section>
</template>
