<script setup>
import Button from 'dashboard/components-next/button/Button.vue';

defineProps({
  actionLabel: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  icon: {
    type: String,
    default: 'i-lucide-calendar-days',
  },
  title: {
    type: String,
    default: '',
  },
});

defineEmits(['action']);
</script>

<template>
  <div
    class="flex flex-col items-center justify-center gap-4 px-6 py-12 text-center rounded-2xl outline outline-1 outline-dashed outline-n-strong bg-n-alpha-black2"
  >
    <span
      class="grid rounded-2xl size-12 place-content-center bg-n-alpha-1 text-n-slate-11"
      :class="icon"
    />
    <div class="flex flex-col gap-1">
      <h3 v-if="title" class="mb-0 text-lg font-semibold text-n-slate-12">
        {{ title }}
      </h3>
      <p v-if="description" class="max-w-xl mb-0 text-sm text-n-slate-11">
        {{ description }}
      </p>
    </div>
    <Button
      v-if="actionLabel"
      size="sm"
      :label="actionLabel"
      @click="$emit('action')"
    />
  </div>
</template>
