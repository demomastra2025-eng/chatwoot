<script setup>
import { computed } from 'vue';
import MessageFormatter from 'shared/helpers/MessageFormatter.js';
import { MESSAGE_VARIANTS } from 'dashboard/components-next/message/constants';
import { useMessageContext } from 'dashboard/components-next/message/provider.js';
import { isJumboEmojiText } from 'shared/helpers/appleEmoji';

const props = defineProps({
  content: {
    type: String,
    required: true,
  },
});

const { variant } = useMessageContext();

const isJumbo = computed(() => {
  if (variant.value === MESSAGE_VARIANTS.ACTIVITY) return false;
  return isJumboEmojiText(props.content);
});

const formattedContent = computed(() => {
  if (variant.value === MESSAGE_VARIANTS.ACTIVITY) {
    return props.content;
  }

  return new MessageFormatter(props.content).formattedMessage;
});
</script>

<template>
  <span
    v-dompurify-html="formattedContent"
    class="prose prose-bubble break-words [overflow-wrap:anywhere]"
    :class="{ 'apple-emoji-jumbo-container': isJumbo }"
  />
</template>

<style lang="scss">
.prose-bubble.apple-emoji-jumbo-container {
  font-size: 2.25rem !important;
  line-height: 1.25 !important;

  p {
    font-size: inherit !important;
    line-height: inherit !important;
    margin: 0 !important;
  }
}
</style>
