<script setup>
import { computed } from 'vue';

import BaseBubble from './Base.vue';
import FormattedContent from './Text/FormattedContent.vue';
import { useMessageContext } from '../provider.js';

const { attachments, content } = useMessageContext();

const attachment = computed(() => attachments.value?.[0] || {});

const url = computed(() => {
  return attachment.value.dataUrl || attachment.value.data_url;
});

const title = computed(() => {
  return (
    attachment.value.fallbackTitle ||
    attachment.value.fallback_title ||
    url.value
  );
});
</script>

<template>
  <BaseBubble class="p-3" data-bubble-name="fallback">
    <FormattedContent v-if="content" :content="content" class="mb-2" />
    <a
      v-if="url"
      :href="url"
      target="_blank"
      rel="noopener noreferrer"
      class="block max-w-[320px] truncate text-sm text-n-brand underline"
    >
      {{ title }}
    </a>
    <span v-else class="text-sm text-n-slate-11">
      {{ title }}
    </span>
  </BaseBubble>
</template>
