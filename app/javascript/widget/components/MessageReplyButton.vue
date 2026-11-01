<script>
import FluentIcon from 'shared/components/FluentIcon/Index.vue';

export default {
  name: 'MessageReplyButton',
  components: { FluentIcon },
};
</script>

<template>
  <button
    type="button"
    :aria-label="$t('COMPONENTS.MESSAGE_BUBBLE.REPLY')"
    class="message-reply-button p-1 mb-1 rounded-full text-n-slate-11 bg-n-slate-3 hover:text-n-slate-12 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
  >
    <FluentIcon icon="arrow-reply" size="11" class="flex-shrink-0" />
  </button>
</template>

<style scoped>
@media (hover: hover) and (pointer: fine) {
  .message-reply-button {
    opacity: 0;
    transition: opacity 75ms;
  }

  .group:hover .message-reply-button,
  .group:focus-within .message-reply-button,
  .message-reply-button:focus-visible {
    opacity: 1;
  }
}
</style>
