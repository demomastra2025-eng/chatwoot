<script setup>
import Button from 'dashboard/components-next/button/Button.vue';

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

defineEmits(['retry']);
</script>

<template>
  <div
    class="flex flex-col items-center justify-center gap-4 px-6 py-12 text-center rounded-2xl outline outline-1 outline-n-ruby-7 bg-n-ruby-3/60"
  >
    <span
      class="grid rounded-2xl size-12 place-content-center bg-n-ruby-4 text-n-ruby-11 i-lucide-alert-triangle"
    />
    <div class="flex flex-col gap-1">
      <h3 class="mb-0 text-lg font-semibold text-n-slate-12">{{ title }}</h3>
      <p v-if="description" class="max-w-xl mb-0 text-sm text-n-slate-11">
        {{ description }}
      </p>
    </div>
    <Button
      size="sm"
      color="ruby"
      variant="faded"
      :label="$t('SCHEDULING.GENERAL.RETRY')"
      @click="$emit('retry')"
    />
  </div>
</template>
