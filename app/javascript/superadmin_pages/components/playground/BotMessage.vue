<script setup>
defineProps({
  message: {
    type: String,
    required: true,
  },
});
</script>

<template>
  <div class="w-full mb-4 flex items-center justify-start">
    <div
      v-dompurify-html="message"
      class="px-4 py-3 bg-n-solid-2 max-w-4xl text-n-slate-12 leading-6 text-sm rounded-md inline-block border border-n-weak"
    />
  </div>
</template>
