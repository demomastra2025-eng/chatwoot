<script setup>
import { computed, ref, watch } from 'vue';
import { getAppleEmojiUrl } from 'shared/helpers/appleEmoji';

const props = defineProps({
  emoji: {
    type: String,
    default: '',
  },
  sizeClass: {
    type: String,
    default: 'size-5',
  },
});

const failedUrls = new Set();

const imageUrl = computed(() => getAppleEmojiUrl(props.emoji));
const hasError = ref(false);

watch(
  imageUrl,
  url => {
    hasError.value = Boolean(url && failedUrls.has(url));
  },
  { immediate: true }
);

function handleError() {
  if (imageUrl.value) {
    failedUrls.add(imageUrl.value);
  }
  hasError.value = true;
}
</script>

<template>
  <img
    v-if="imageUrl && !hasError"
    :src="imageUrl"
    :alt="emoji"
    :class="sizeClass"
    class="apple-emoji inline-block object-contain select-none pointer-events-none shrink-0"
    draggable="false"
    loading="lazy"
    decoding="async"
    @error="handleError"
  />
  <span v-else class="emoji-font leading-none select-none">{{ emoji }}</span>
</template>
