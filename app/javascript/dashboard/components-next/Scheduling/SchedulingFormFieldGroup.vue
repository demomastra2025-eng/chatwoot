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
    class="overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container shadow-sm"
  >
    <div
      v-if="title || description || $slots.headerActions"
      class="flex flex-col gap-3 border-b border-n-weak px-5 py-4 md:flex-row md:items-start md:justify-between"
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
    <div class="grid gap-4 px-5 py-4">
      <slot />
    </div>
  </section>
</template>
