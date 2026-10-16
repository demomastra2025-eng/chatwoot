<script setup>
import { computed } from 'vue';
import { useMessageContext } from '../../provider.js';

import MessageFormatter from 'shared/helpers/MessageFormatter.js';
import {
  isJumboEmojiText,
  replaceEmojisWithAppleImages,
} from 'shared/helpers/appleEmoji';
import { MESSAGE_VARIANTS } from '../../constants';

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

  const baseHtml = new MessageFormatter(props.content).formattedMessage;
  return replaceEmojisWithAppleImages(baseHtml, { jumbo: isJumbo.value });
});

function handleEmojiImageError(event) {
  const target = event?.target;
  if (
    target?.tagName === 'IMG' &&
    target.classList?.contains('apple-emoji') &&
    target.alt
  ) {
    target.replaceWith(document.createTextNode(target.alt));
  }
}
</script>

<template>
  <span
    v-dompurify-html="formattedContent"
    class="prose prose-bubble break-words [overflow-wrap:anywhere]"
    :class="{ 'apple-emoji-jumbo-container': isJumbo }"
    @error.capture="handleEmojiImageError"
  />
</template>

<style lang="scss">
.prose-bubble {
  img.apple-emoji--inline {
    display: inline-block !important;
    width: 1.25em !important;
    height: 1.25em !important;
    margin: 0 0.06em !important;
    vertical-align: -0.22em !important;
    object-fit: contain;
    user-select: text;
    border-radius: 0 !important;
  }

  img.apple-emoji--jumbo {
    display: inline-block !important;
    width: 2.35rem !important;
    height: 2.35rem !important;
    margin: 0.1rem 0.12rem !important;
    vertical-align: middle !important;
    object-fit: contain;
    border-radius: 0 !important;
  }
}
</style>
