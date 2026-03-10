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
  <header
    class="flex flex-col gap-4 px-6 py-5 border-b bg-n-solid-2 border-n-weak"
  >
    <div
      class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between"
    >
      <div class="flex flex-col gap-1">
        <h1 class="mb-0 text-2xl font-semibold text-n-slate-12">
          {{ title }}
        </h1>
        <p v-if="description" class="mb-0 text-sm text-n-slate-11">
          {{ description }}
        </p>
      </div>

      <div class="flex items-center gap-2">
        <slot name="actions" />
      </div>
    </div>
  </header>
</template>
