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
  <section
    class="flex flex-col overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container shadow-sm"
  >
    <header
      v-if="title || description || $slots.headerActions"
      class="flex flex-col gap-3 border-b border-n-weak px-5 py-4 md:flex-row md:items-start md:justify-between"
    >
      <div class="flex flex-col gap-1">
        <h2 v-if="title" class="mb-0 text-base font-semibold text-n-slate-12">
          {{ title }}
        </h2>
        <p v-if="description" class="mb-0 text-xs text-n-slate-11">
          {{ description }}
        </p>
      </div>
      <div class="flex items-center gap-2 self-start md:self-auto">
        <slot name="headerActions" />
      </div>
    </header>
    <div class="px-5 py-4">
      <slot />
    </div>
  </section>
</template>
