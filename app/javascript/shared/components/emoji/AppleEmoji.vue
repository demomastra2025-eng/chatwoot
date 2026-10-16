<script setup>
import { computed, ref, watch } from 'vue';
import { getAppleEmojiUrl } from 'shared/helpers/appleEmoji';

const props = defineProps({
  emoji: {
    type: String,
    required: true,
  },
  sizeClass: {
    type: String,
    default: 'size-5',
  },
});

const hasError = ref(false);

watch(
  () => props.emoji,
  () => {
    hasError.value = false;
  }
);

const imageUrl = computed(() => getAppleEmojiUrl(props.emoji));
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
    @error="hasError = true"
  />
  <span v-else class="emoji-font leading-none select-none">{{ emoji }}</span>
</template>
