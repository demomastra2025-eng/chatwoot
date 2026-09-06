<script setup>
import Button from 'dashboard/components-next/button/Button.vue';

defineEmits(['retry']);
</script>

<template>
  <div
    class="flex flex-col items-center gap-2 p-4 text-center text-n-slate-11"
    role="status"
  >
    <p>{{ $t('CHAT_LIST.LOAD_ERROR') }}</p>
    <Button
      :label="$t('CHAT_LIST.RETRY')"
      variant="outline"
      size="sm"
      @click="$emit('retry')"
    />
  </div>
</template>
