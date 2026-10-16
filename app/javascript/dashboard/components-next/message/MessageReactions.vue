<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import AppleEmoji from 'shared/components/emoji/AppleEmoji.vue';
import { useMessageContext } from './provider.js';
import { extractNormalizedReactions } from './helpers/messageReactions';
import { recordReactionUsage } from 'shared/helpers/emojiUsage';

const {
  id: messageId,
  conversationId,
  contentAttributes,
  currentUserId,
  canReact,
} = useMessageContext();
const { t } = useI18n();
const store = useStore();
const pendingEmoji = ref('');

const reactions = computed(() =>
  extractNormalizedReactions({
    contentAttributes: contentAttributes.value,
    currentUserId: currentUserId.value,
    t,
  })
);

const hasReactions = computed(() => reactions.value.length > 0);
const isChannelReactionAllowed = computed(() => Boolean(canReact?.value));

function isPillInteractive(item) {
  return Boolean(item.interactive && isChannelReactionAllowed.value);
}

function reactionTooltip(item) {
  if (item.label) {
    return `${item.label} (${item.count})`;
  }
  if (item.actors?.length) {
    return `${item.emoji} ${item.actors.join(', ')}`;
  }
  return `${item.emoji} ${item.count}`;
}

async function handleToggleReaction(item) {
  if (!isPillInteractive(item) || !item.emoji || pendingEmoji.value) return;

  pendingEmoji.value = item.emoji;
  try {
    if (!item.reactedByMe) {
      recordReactionUsage(item.emoji);
    }
    await store.dispatch('toggleMessageReaction', {
      conversationId: conversationId.value,
      messageId: messageId.value,
      emoji: item.emoji,
    });
  } catch {
    useAlert(t('CONVERSATION.REACTIONS.ERROR'));
  } finally {
    pendingEmoji.value = '';
  }
}
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <div
    v-if="hasReactions"
    class="flex flex-wrap items-center gap-1 mt-1.5 select-none skip-context-menu"
    data-testid="message-reactions"
    @click.stop
  >
    <button
      v-for="item in reactions"
      :key="item.key"
      type="button"
      :title="reactionTooltip(item)"
      :disabled="!isPillInteractive(item) || pendingEmoji === item.emoji"
      class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium transition-all duration-150 skip-context-menu border"
      :class="[
        item.reactedByMe
          ? 'bg-n-brand/15 text-n-brand border-n-brand/40 hover:bg-n-brand/25'
          : 'bg-n-alpha-black2 dark:bg-n-solid-3 text-n-slate-12 border-n-weak hover:bg-n-alpha-3',
        isPillInteractive(item)
          ? 'cursor-pointer active:scale-95'
          : 'cursor-default',
      ]"
      @click.stop="handleToggleReaction(item)"
    >
      <AppleEmoji :emoji="item.emoji" size-class="size-4" />
      <span v-if="item.label" class="text-[11px] skip-context-menu">
        {{ item.label }}
      </span>
      <span
        v-if="item.count > 1 || item.label"
        class="text-[11px] font-semibold leading-none skip-context-menu"
      >
        {{ item.count }}
      </span>
    </button>
  </div>
</template>
