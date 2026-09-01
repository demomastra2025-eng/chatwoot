<script setup>
import { computed } from 'vue';
import { formatNumber } from '@chatwoot/utils';

const props = defineProps({
  conversationCount: { type: Number, default: 0 },
  isListLoading: { type: Boolean, default: false },
});

const formattedConversationCount = computed(() =>
  formatNumber(props.conversationCount || 0)
);
</script>

<template>
  <div
    data-testid="conversation-count-row"
    class="-mt-1 flex h-5 shrink-0 items-start justify-end px-3 pt-0.5 text-xxs leading-4 text-n-slate-9"
  >
    <span v-if="!isListLoading" data-testid="conversation-count">
      {{
        $t('CHAT_LIST.TOTAL_COUNT', {
          count: formattedConversationCount,
        })
      }}
    </span>
  </div>
</template>
