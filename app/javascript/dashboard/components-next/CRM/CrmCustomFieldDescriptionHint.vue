<script setup>
defineProps({
  description: {
    type: String,
    required: true,
  },
  label: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <button
    v-tooltip.top="description"
    type="button"
    class="inline-flex size-3.5 shrink-0 cursor-help items-center justify-center border-0 bg-transparent p-0 text-n-slate-9 opacity-50 transition-opacity hover:opacity-80 focus-visible:opacity-80 focus-visible:outline-none"
    :aria-label="label ? `${label}: ${description}` : description"
  >
    <span class="i-lucide-circle-question-mark size-3.5" aria-hidden="true" />
  </button>
</template>
