<script setup>
import { computed } from 'vue';

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

const normalizedEmoji = computed(() => {
  const raw = String(props.emoji || '');
  if (!raw) return '';
  if (raw.length === 1) {
    const code = raw.codePointAt(0);
    if (code >= 0x2600 && code <= 0x27bf) {
      return `${raw}\uFE0F`;
    }
  }
  return raw;
});

const fontSizeClass = computed(() => {
  if (props.sizeClass.includes('size-7')) return 'text-[1.625rem]';
  if (props.sizeClass.includes('size-6')) return 'text-[1.375rem]';
  if (props.sizeClass.includes('size-4')) return 'text-base';
  return 'text-lg';
});
</script>

<template>
  <span
    :class="[sizeClass, fontSizeClass]"
    class="emoji-font inline-flex items-center justify-center leading-none select-none pointer-events-none shrink-0"
  >
    {{ normalizedEmoji }}
  </span>
</template>

<style scoped>
.emoji-font {
  font-family: 'Apple Color Emoji', 'Segoe UI Emoji', 'Noto Color Emoji',
    'Segoe UI Symbol', sans-serif;
  font-variant-emoji: emoji;
}
</style>
