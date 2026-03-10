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
    class="flex flex-col overflow-hidden rounded-2xl outline outline-1 outline-n-container bg-n-solid-2"
  >
    <header
      v-if="title || description || $slots.headerActions"
      class="flex flex-col gap-3 px-5 py-4 border-b md:flex-row md:items-start md:justify-between border-n-weak"
    >
      <div class="flex flex-col gap-1">
        <h2 v-if="title" class="mb-0 text-base font-semibold text-n-slate-12">
          {{ title }}
        </h2>
        <p v-if="description" class="mb-0 text-sm text-n-slate-11">
          {{ description }}
        </p>
      </div>
      <div class="flex items-center gap-2">
        <slot name="headerActions" />
      </div>
    </header>
    <div class="p-5">
      <slot />
    </div>
  </section>
</template>
