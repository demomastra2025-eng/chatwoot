<script setup>
import { computed } from 'vue';
import BaseBubble from './Base.vue';
import AudioChip from 'next/message/chips/Audio.vue';
import { useMessageContext } from '../provider.js';

const { attachments } = useMessageContext();

const attachment = computed(() => {
  return attachments.value[0];
});
</script>

<template>
  <BaseBubble class="audio-bubble" data-bubble-name="audio">
    <AudioChip
      :attachment="attachment"
      class="px-2 pt-2 pb-2 text-n-slate-12 skip-context-menu"
    />
  </BaseBubble>
</template>

<style scoped>
.audio-bubble :deep(.message-meta-root) {
  margin-top: 0 !important;
  padding-inline-start: 1rem;
  padding-inline-end: 0.5rem;
  padding-bottom: 0.5rem;
}
</style>
